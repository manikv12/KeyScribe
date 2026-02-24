import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MemorySQLiteStoreError: LocalizedError {
    case failedToCreateDirectory(path: String)
    case failedToOpenDatabase(path: String, code: Int32, message: String)
    case failedToPrepareStatement(sql: String, code: Int32, message: String)
    case failedToExecuteStatement(sql: String, code: Int32, message: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidDatabaseState

    var errorDescription: String? {
        switch self {
        case let .failedToCreateDirectory(path):
            return "Unable to create memory database directory: \(path)"
        case let .failedToOpenDatabase(path, code, message):
            return "Unable to open memory database at \(path) (code: \(code)): \(message)"
        case let .failedToPrepareStatement(sql, code, message):
            return "Unable to prepare SQL statement (code: \(code)): \(message)\nSQL: \(sql)"
        case let .failedToExecuteStatement(sql, code, message):
            return "Unable to execute SQL statement (code: \(code)): \(message)\nSQL: \(sql)"
        case let .unsupportedSchemaVersion(found, supported):
            return "Memory database schema version \(found) is newer than this app supports (\(supported))."
        case .invalidDatabaseState:
            return "Memory database is not available."
        }
    }
}

final class MemorySQLiteStore {
    private static let schemaVersion = 2

    let databaseURL: URL
    private var database: OpaquePointer?
    private let lock = NSLock()

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            self.databaseURL = try Self.defaultDatabaseURL(fileManager: fileManager)
        }

        try Self.ensureParentDirectory(for: self.databaseURL, fileManager: fileManager)
        try open()
        try ensureSchema()
    }

    deinit {
        close()
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MemorySQLiteStoreError.failedToCreateDirectory(path: "\(NSHomeDirectory())/Library/Application Support")
        }

        return appSupport
            .appendingPathComponent("KeyScribe", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite3")
    }

    func ensureSchema() throws {
        try execute(sql: "PRAGMA journal_mode=WAL;")
        try execute(sql: "PRAGMA foreign_keys=ON;")

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_schema_meta (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            schema_version INTEGER NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        if let existingSchemaVersion = try fetchSchemaVersion(),
           existingSchemaVersion > Self.schemaVersion {
            throw MemorySQLiteStoreError.unsupportedSchemaVersion(
                found: existingSchemaVersion,
                supported: Self.schemaVersion
            )
        }

        try execute(sql: """
        INSERT INTO memory_schema_meta (id, schema_version, updated_at)
        VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            schema_version = excluded.schema_version,
            updated_at = excluded.updated_at;
        """, bind: { statement in
            self.bind(Int64(Self.schemaVersion), at: 1, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 2, in: statement)
        })

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_sources (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            root_path TEXT NOT NULL,
            display_name TEXT NOT NULL,
            discovered_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_sources_provider_root
            ON memory_sources(provider, root_path);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_files (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            absolute_path TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            file_hash TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL DEFAULT 0,
            modified_at REAL NOT NULL,
            indexed_at REAL NOT NULL,
            parse_error TEXT,
            UNIQUE(source_id, relative_path)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_files_source
            ON memory_files(source_id, modified_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_events (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            source_file_id TEXT NOT NULL REFERENCES memory_files(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            event_timestamp REAL NOT NULL,
            native_summary TEXT,
            keywords_json TEXT NOT NULL DEFAULT '[]',
            is_plan_content INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            raw_payload TEXT,
            updated_at REAL NOT NULL
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_events_source_file
            ON memory_events(source_file_id, event_timestamp DESC);
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_events_plan
            ON memory_events(is_plan_content, event_timestamp DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_cards (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            source_file_id TEXT NOT NULL REFERENCES memory_files(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL REFERENCES memory_events(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            detail TEXT NOT NULL,
            keywords_json TEXT NOT NULL DEFAULT '[]',
            score REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            is_plan_content INTEGER NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_cards_rewrite
            ON memory_cards(provider, is_plan_content, score DESC, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_lessons (
            id TEXT PRIMARY KEY NOT NULL,
            source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE CASCADE,
            source_file_id TEXT NOT NULL REFERENCES memory_files(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL REFERENCES memory_events(id) ON DELETE CASCADE,
            card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            mistake_pattern TEXT NOT NULL,
            improved_prompt TEXT NOT NULL,
            rationale TEXT NOT NULL,
            validation_confidence REAL NOT NULL DEFAULT 0,
            source_metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(card_id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_lessons_lookup
            ON memory_lessons(provider, validation_confidence DESC, updated_at DESC);
        """)

        try execute(sql: """
        CREATE TABLE IF NOT EXISTS rewrite_suggestions (
            id TEXT PRIMARY KEY NOT NULL,
            card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            original_text TEXT NOT NULL,
            suggested_text TEXT NOT NULL,
            rationale TEXT NOT NULL,
            confidence REAL NOT NULL,
            created_at REAL NOT NULL
        );
        """)
    }

    func hasTable(named tableName: String) throws -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1;"
        let results: [String] = try self.query(sql: sql, bind: { statement in
            self.bind(tableName, at: 1, in: statement)
        }, mapRow: { statement in
            self.readString(at: 0, in: statement) ?? ""
        })
        return !results.isEmpty
    }

    func upsertSource(_ source: MemorySource) throws {
        let sql = """
        INSERT INTO memory_sources (
            id, provider, root_path, display_name, discovered_at, updated_at, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            provider = excluded.provider,
            root_path = excluded.root_path,
            display_name = excluded.display_name,
            updated_at = excluded.updated_at,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(source.id.uuidString, at: 1, in: statement)
            self.bind(source.provider.rawValue, at: 2, in: statement)
            self.bind(source.rootPath, at: 3, in: statement)
            self.bind(source.displayName, at: 4, in: statement)
            self.bind(source.discoveredAt.timeIntervalSince1970, at: 5, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 6, in: statement)
            self.bind(self.encodeJSON(source.metadata, fallback: "{}"), at: 7, in: statement)
        })
    }

    func upsertSourceFile(_ sourceFile: MemorySourceFile) throws {
        let sql = """
        INSERT INTO memory_files (
            id, source_id, absolute_path, relative_path, file_hash, file_size_bytes, modified_at, indexed_at, parse_error
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            absolute_path = excluded.absolute_path,
            relative_path = excluded.relative_path,
            file_hash = excluded.file_hash,
            file_size_bytes = excluded.file_size_bytes,
            modified_at = excluded.modified_at,
            indexed_at = excluded.indexed_at,
            parse_error = excluded.parse_error;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(sourceFile.id.uuidString, at: 1, in: statement)
            self.bind(sourceFile.sourceID.uuidString, at: 2, in: statement)
            self.bind(sourceFile.absolutePath, at: 3, in: statement)
            self.bind(sourceFile.relativePath, at: 4, in: statement)
            self.bind(sourceFile.fileHash, at: 5, in: statement)
            self.bind(sourceFile.fileSizeBytes, at: 6, in: statement)
            self.bind(sourceFile.modifiedAt.timeIntervalSince1970, at: 7, in: statement)
            self.bind(sourceFile.indexedAt.timeIntervalSince1970, at: 8, in: statement)
            self.bind(sourceFile.parseError, at: 9, in: statement)
        })
    }

    func upsertEvent(_ event: MemoryEvent) throws {
        let sql = """
        INSERT INTO memory_events (
            id, source_id, source_file_id, provider, kind, title, body, event_timestamp, native_summary,
            keywords_json, is_plan_content, metadata_json, raw_payload, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            source_file_id = excluded.source_file_id,
            provider = excluded.provider,
            kind = excluded.kind,
            title = excluded.title,
            body = excluded.body,
            event_timestamp = excluded.event_timestamp,
            native_summary = excluded.native_summary,
            keywords_json = excluded.keywords_json,
            is_plan_content = excluded.is_plan_content,
            metadata_json = excluded.metadata_json,
            raw_payload = excluded.raw_payload,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(event.id.uuidString, at: 1, in: statement)
            self.bind(event.sourceID.uuidString, at: 2, in: statement)
            self.bind(event.sourceFileID.uuidString, at: 3, in: statement)
            self.bind(event.provider.rawValue, at: 4, in: statement)
            self.bind(event.kind.rawValue, at: 5, in: statement)
            self.bind(event.title, at: 6, in: statement)
            self.bind(event.body, at: 7, in: statement)
            self.bind(event.timestamp.timeIntervalSince1970, at: 8, in: statement)
            self.bind(event.nativeSummary, at: 9, in: statement)
            self.bind(self.encodeJSON(event.keywords, fallback: "[]"), at: 10, in: statement)
            self.bind(event.isPlanContent ? 1 : 0, at: 11, in: statement)
            self.bind(self.encodeJSON(event.metadata, fallback: "{}"), at: 12, in: statement)
            self.bind(event.rawPayload, at: 13, in: statement)
            self.bind(Date().timeIntervalSince1970, at: 14, in: statement)
        })
    }

    func upsertCard(_ card: MemoryCard) throws {
        let sql = """
        INSERT INTO memory_cards (
            id, source_id, source_file_id, event_id, provider, title, summary, detail, keywords_json, score,
            created_at, updated_at, is_plan_content, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source_id = excluded.source_id,
            source_file_id = excluded.source_file_id,
            event_id = excluded.event_id,
            provider = excluded.provider,
            title = excluded.title,
            summary = excluded.summary,
            detail = excluded.detail,
            keywords_json = excluded.keywords_json,
            score = excluded.score,
            updated_at = excluded.updated_at,
            is_plan_content = excluded.is_plan_content,
            metadata_json = excluded.metadata_json;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(card.id.uuidString, at: 1, in: statement)
            self.bind(card.sourceID.uuidString, at: 2, in: statement)
            self.bind(card.sourceFileID.uuidString, at: 3, in: statement)
            self.bind(card.eventID.uuidString, at: 4, in: statement)
            self.bind(card.provider.rawValue, at: 5, in: statement)
            self.bind(card.title, at: 6, in: statement)
            self.bind(card.summary, at: 7, in: statement)
            self.bind(card.detail, at: 8, in: statement)
            self.bind(self.encodeJSON(card.keywords, fallback: "[]"), at: 9, in: statement)
            self.bind(card.score, at: 10, in: statement)
            self.bind(card.createdAt.timeIntervalSince1970, at: 11, in: statement)
            self.bind(card.updatedAt.timeIntervalSince1970, at: 12, in: statement)
            self.bind(card.isPlanContent ? 1 : 0, at: 13, in: statement)
            self.bind(self.encodeJSON(card.metadata, fallback: "{}"), at: 14, in: statement)
        })
    }

    func upsertLesson(_ lesson: MemoryLesson) throws {
        let sql = """
        INSERT INTO memory_lessons (
            id, source_id, source_file_id, event_id, card_id, provider, mistake_pattern, improved_prompt,
            rationale, validation_confidence, source_metadata_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(card_id) DO UPDATE SET
            id = excluded.id,
            source_id = excluded.source_id,
            source_file_id = excluded.source_file_id,
            event_id = excluded.event_id,
            provider = excluded.provider,
            mistake_pattern = excluded.mistake_pattern,
            improved_prompt = excluded.improved_prompt,
            rationale = excluded.rationale,
            validation_confidence = excluded.validation_confidence,
            source_metadata_json = excluded.source_metadata_json,
            updated_at = excluded.updated_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(lesson.id.uuidString, at: 1, in: statement)
            self.bind(lesson.sourceID.uuidString, at: 2, in: statement)
            self.bind(lesson.sourceFileID.uuidString, at: 3, in: statement)
            self.bind(lesson.eventID.uuidString, at: 4, in: statement)
            self.bind(lesson.cardID.uuidString, at: 5, in: statement)
            self.bind(lesson.provider.rawValue, at: 6, in: statement)
            self.bind(lesson.mistakePattern, at: 7, in: statement)
            self.bind(lesson.improvedPrompt, at: 8, in: statement)
            self.bind(lesson.rationale, at: 9, in: statement)
            self.bind(lesson.validationConfidence, at: 10, in: statement)
            self.bind(self.encodeJSON(lesson.sourceMetadata, fallback: "{}"), at: 11, in: statement)
            self.bind(lesson.createdAt.timeIntervalSince1970, at: 12, in: statement)
            self.bind(lesson.updatedAt.timeIntervalSince1970, at: 13, in: statement)
        })
    }

    func insertRewriteSuggestion(_ suggestion: RewriteSuggestion) throws {
        let sql = """
        INSERT INTO rewrite_suggestions (
            id, card_id, provider, original_text, suggested_text, rationale, confidence, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            card_id = excluded.card_id,
            provider = excluded.provider,
            original_text = excluded.original_text,
            suggested_text = excluded.suggested_text,
            rationale = excluded.rationale,
            confidence = excluded.confidence,
            created_at = excluded.created_at;
        """

        try execute(sql: sql, bind: { statement in
            self.bind(suggestion.id.uuidString, at: 1, in: statement)
            self.bind(suggestion.cardID.uuidString, at: 2, in: statement)
            self.bind(suggestion.provider.rawValue, at: 3, in: statement)
            self.bind(suggestion.originalText, at: 4, in: statement)
            self.bind(suggestion.suggestedText, at: 5, in: statement)
            self.bind(suggestion.rationale, at: 6, in: statement)
            self.bind(suggestion.confidence, at: 7, in: statement)
            self.bind(suggestion.createdAt.timeIntervalSince1970, at: 8, in: statement)
        })
    }

    func upsertFeedbackRewriteMemory(
        originalText: String,
        rewrittenText: String,
        rationale: String,
        confidence: Double,
        timestamp: Date = Date()
    ) throws {
        let normalizedOriginal = MemoryTextNormalizer.collapsedWhitespace(originalText)
        let normalizedRewritten = MemoryTextNormalizer.collapsedWhitespace(rewrittenText)
        guard !normalizedOriginal.isEmpty, !normalizedRewritten.isEmpty else {
            return
        }

        let sourceID = MemoryIdentifier.stableUUID(for: "source|feedback-rewrites")
        let sourceFileID = MemoryIdentifier.stableUUID(for: "file|\(sourceID.uuidString)|feedback-rewrites")
        let eventID = MemoryIdentifier.stableUUID(
            for: "event|\(sourceFileID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
        )
        let cardID = MemoryIdentifier.stableUUID(
            for: "card|\(eventID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
        )
        let suggestionID = MemoryIdentifier.stableUUID(
            for: "rewrite|\(cardID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
        )

        let source = MemorySource(
            id: sourceID,
            provider: .unknown,
            rootPath: "internal://prompt-rewrite-feedback",
            displayName: "KeyScribe Learned Rewrites",
            discoveredAt: timestamp,
            metadata: [
                "origin": "user-feedback"
            ]
        )
        try upsertSource(source)

        let pseudoPath = "feedback/rewrite-feedback.jsonl"
        let sourceFile = MemorySourceFile(
            id: sourceFileID,
            sourceID: sourceID,
            absolutePath: pseudoPath,
            relativePath: pseudoPath,
            fileHash: MemoryIdentifier.stableHexDigest(for: "\(normalizedOriginal)|\(normalizedRewritten)"),
            fileSizeBytes: Int64((normalizedOriginal + normalizedRewritten).utf8.count),
            modifiedAt: timestamp,
            indexedAt: timestamp,
            parseError: nil
        )
        try upsertSourceFile(sourceFile)

        let summary = MemoryTextNormalizer.normalizedSummary("User-confirmed prompt fix: \(normalizedOriginal) -> \(normalizedRewritten)")
        let event = MemoryEvent(
            id: eventID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            provider: .unknown,
            kind: .rewrite,
            title: "User Confirmed Prompt Fix",
            body: "\(normalizedOriginal) -> \(normalizedRewritten)",
            timestamp: timestamp,
            nativeSummary: summary,
            keywords: MemoryTextNormalizer.keywords(from: "\(normalizedOriginal) \(normalizedRewritten)", limit: 16),
            isPlanContent: false,
            metadata: [
                "original_text": normalizedOriginal,
                "suggested_text": normalizedRewritten,
                "rationale": rationale,
                "origin": "prompt-rewrite-feedback"
            ],
            rawPayload: nil
        )
        try upsertEvent(event)

        let card = MemoryCard(
            id: cardID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            provider: .unknown,
            title: MemoryTextNormalizer.normalizedTitle(normalizedOriginal, fallback: "Prompt rewrite"),
            summary: summary,
            detail: "\(normalizedOriginal)\n->\n\(normalizedRewritten)",
            keywords: MemoryTextNormalizer.keywords(from: "\(normalizedOriginal) \(normalizedRewritten)", limit: 16),
            score: 0.96,
            createdAt: timestamp,
            updatedAt: timestamp,
            isPlanContent: false,
            metadata: [
                "origin": "prompt-rewrite-feedback",
                "rationale": rationale
            ]
        )
        try upsertCard(card)

        let normalizedConfidence = min(1.0, max(0.05, confidence))
        let suggestion = RewriteSuggestion(
            id: suggestionID,
            cardID: cardID,
            provider: .unknown,
            originalText: normalizedOriginal,
            suggestedText: normalizedRewritten,
            rationale: rationale,
            confidence: normalizedConfidence,
            createdAt: timestamp
        )
        try insertRewriteSuggestion(suggestion)

        let lesson = MemoryLesson(
            id: MemoryIdentifier.stableUUID(
                for: "lesson|\(cardID.uuidString)|\(normalizedOriginal)|\(normalizedRewritten)"
            ),
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            cardID: cardID,
            provider: .unknown,
            mistakePattern: normalizedOriginal,
            improvedPrompt: normalizedRewritten,
            rationale: rationale,
            validationConfidence: max(0.95, normalizedConfidence),
            sourceMetadata: [
                "origin": "prompt-rewrite-feedback",
                "validation_state": "user-confirmed",
                "extraction_method": "user-feedback"
            ],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try upsertLesson(lesson)
        try supersedeCompetingLessons(
            with: lesson,
            reason: "Superseded by a newer user-confirmed correction.",
            timestamp: timestamp
        )
    }

    func fetchRewriteSuggestions(
        query searchQuery: String,
        provider: MemoryProviderKind? = nil,
        limit: Int = 10
    ) throws -> [RewriteSuggestion] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = provider?.rawValue
        let normalizedLimit = max(1, min(limit, 200))

        let sql = """
        SELECT
            id, card_id, provider, original_text, suggested_text, rationale, confidence, created_at
        FROM rewrite_suggestions
        WHERE (? IS NULL OR provider = ?)
            AND (? = 0 OR original_text LIKE ? ESCAPE '\\')
        ORDER BY confidence DESC, created_at DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 3, in: statement)
            self.bind(likeValue, at: 4, in: statement)
            self.bind(Int64(normalizedLimit), at: 5, in: statement)
        }, mapRow: { statement in
            RewriteSuggestion(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                cardID: UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID(),
                provider: MemoryProviderKind(rawValue: self.readString(at: 2, in: statement) ?? "") ?? .unknown,
                originalText: self.readString(at: 3, in: statement) ?? "",
                suggestedText: self.readString(at: 4, in: statement) ?? "",
                rationale: self.readString(at: 5, in: statement) ?? "",
                confidence: sqlite3_column_double(statement, 6),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            )
        })
    }

    func fetchLessonsForRewrite(
        query searchQuery: String,
        provider: MemoryProviderKind? = nil,
        limit: Int = 20
    ) throws -> [MemoryLesson] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = provider?.rawValue
        let normalizedLimit = max(1, min(limit, 300))

        let sql = """
        SELECT
            id, source_id, source_file_id, event_id, card_id, provider, mistake_pattern, improved_prompt,
            rationale, validation_confidence, source_metadata_json, created_at, updated_at
        FROM memory_lessons
        WHERE (? IS NULL OR provider = ?)
            AND (
                ? = 0
                OR mistake_pattern LIKE ? ESCAPE '\\'
                OR improved_prompt LIKE ? ESCAPE '\\'
                OR rationale LIKE ? ESCAPE '\\'
            )
        ORDER BY validation_confidence DESC, updated_at DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 3, in: statement)
            self.bind(likeValue, at: 4, in: statement)
            self.bind(likeValue, at: 5, in: statement)
            self.bind(likeValue, at: 6, in: statement)
            self.bind(Int64(normalizedLimit), at: 7, in: statement)
        }, mapRow: { statement in
            MemoryLesson(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                sourceID: UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID(),
                sourceFileID: UUID(uuidString: self.readString(at: 2, in: statement) ?? "") ?? UUID(),
                eventID: UUID(uuidString: self.readString(at: 3, in: statement) ?? "") ?? UUID(),
                cardID: UUID(uuidString: self.readString(at: 4, in: statement) ?? "") ?? UUID(),
                provider: MemoryProviderKind(rawValue: self.readString(at: 5, in: statement) ?? "") ?? .unknown,
                mistakePattern: self.readString(at: 6, in: statement) ?? "",
                improvedPrompt: self.readString(at: 7, in: statement) ?? "",
                rationale: self.readString(at: 8, in: statement) ?? "",
                validationConfidence: sqlite3_column_double(statement, 9),
                sourceMetadata: self.decodeStringDictionary(from: self.readString(at: 10, in: statement) ?? "{}"),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            )
        })
    }

    func supersedeCompetingLessons(
        with betterLesson: MemoryLesson,
        reason: String,
        timestamp: Date = Date()
    ) throws {
        let normalizedMistake = MemoryTextNormalizer.collapsedWhitespace(betterLesson.mistakePattern)
        let normalizedCorrection = MemoryTextNormalizer.collapsedWhitespace(betterLesson.improvedPrompt)
        guard !normalizedMistake.isEmpty, !normalizedCorrection.isEmpty else { return }

        let candidates = try fetchLessonsForRewrite(
            query: "",
            provider: nil,
            limit: 1200
        )

        for lesson in candidates {
            if lesson.id == betterLesson.id {
                continue
            }
            let lessonMistake = MemoryTextNormalizer.collapsedWhitespace(lesson.mistakePattern)
            let lessonCorrection = MemoryTextNormalizer.collapsedWhitespace(lesson.improvedPrompt)
            guard isSameScenario(lessonMistake, normalizedMistake) else { continue }
            guard !isEquivalentCorrection(lessonCorrection, normalizedCorrection) else { continue }

            if lessonValidationState(from: lesson) == .invalidated {
                continue
            }

            guard shouldInvalidateExistingLesson(lesson, replacement: betterLesson) else { continue }
            let betterScore = lessonSelectionScore(for: betterLesson)
            let existingScore = lessonSelectionScore(for: lesson)

            var updated = lesson
            updated.validationConfidence = min(updated.validationConfidence, 0.05)
            updated.updatedAt = timestamp

            var metadata = updated.sourceMetadata
            metadata["validation_state"] = MemoryRewriteLessonValidationState.invalidated.rawValue
            metadata["invalidated_by_lesson_id"] = betterLesson.id.uuidString
            metadata["invalidated_at"] = iso8601Timestamp(timestamp)
            metadata["invalidation_reason"] = MemoryTextNormalizer.normalizedSummary(reason, limit: 240)
            metadata["invalidation_existing_score"] = String(format: "%.3f", existingScore)
            metadata["invalidation_replacement_score"] = String(format: "%.3f", betterScore)
            updated.sourceMetadata = metadata

            try upsertLesson(updated)
        }
    }

    func fetchCardsForRewrite(
        query: String,
        options: MemoryRewriteLookupOptions = MemoryRewriteLookupOptions()
    ) throws -> [MemoryCard] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(query)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = options.provider?.rawValue
        let sql = """
        SELECT
            id, source_id, source_file_id, event_id, provider, title, summary, detail, keywords_json,
            score, created_at, updated_at, is_plan_content, metadata_json
        FROM memory_cards
        WHERE (? IS NULL OR provider = ?)
            AND (? = 1 OR is_plan_content = 0)
            AND (? = 0 OR title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR detail LIKE ? ESCAPE '\\')
        ORDER BY score DESC, updated_at DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(options.includePlanContent ? 1 : 0, at: 3, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 4, in: statement)
            self.bind(likeValue, at: 5, in: statement)
            self.bind(likeValue, at: 6, in: statement)
            self.bind(likeValue, at: 7, in: statement)
            self.bind(Int64(options.limit), at: 8, in: statement)
        }, mapRow: { statement in
            let id = UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID()
            let sourceID = UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? UUID()
            let sourceFileID = UUID(uuidString: self.readString(at: 2, in: statement) ?? "") ?? UUID()
            let eventID = UUID(uuidString: self.readString(at: 3, in: statement) ?? "") ?? UUID()
            let provider = MemoryProviderKind(rawValue: self.readString(at: 4, in: statement) ?? "") ?? .unknown
            let title = self.readString(at: 5, in: statement) ?? ""
            let summary = self.readString(at: 6, in: statement) ?? ""
            let detail = self.readString(at: 7, in: statement) ?? ""
            let keywordsJSON = self.readString(at: 8, in: statement) ?? "[]"
            let score = sqlite3_column_double(statement, 9)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            let isPlanContent = sqlite3_column_int(statement, 12) == 1
            let metadataJSON = self.readString(at: 13, in: statement) ?? "{}"

            return MemoryCard(
                id: id,
                sourceID: sourceID,
                sourceFileID: sourceFileID,
                eventID: eventID,
                provider: provider,
                title: title,
                summary: summary,
                detail: detail,
                keywords: self.decodeStringArray(from: keywordsJSON),
                score: score,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isPlanContent: isPlanContent,
                metadata: self.decodeStringDictionary(from: metadataJSON)
            )
        })
    }

    func fetchIndexedEntries(
        query searchQuery: String,
        provider: MemoryProviderKind? = nil,
        sourceRootPath: String? = nil,
        includePlanContent: Bool = false,
        limit: Int = 80
    ) throws -> [MemoryIndexedEntry] {
        let normalizedQuery = MemoryTextNormalizer.collapsedWhitespace(searchQuery)
        let hasSearchTerm = !normalizedQuery.isEmpty
        let likeValue = "%\(escapedLike(normalizedQuery))%"
        let providerRawValue = provider?.rawValue
        let normalizedSourceRootPath = sourceRootPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLimit = max(1, min(limit, 400))

        let sql = """
        SELECT
            c.id,
            c.provider,
            s.root_path,
            c.title,
            c.summary,
            c.detail,
            c.updated_at,
            c.is_plan_content
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        WHERE (? IS NULL OR c.provider = ?)
            AND (? = 1 OR c.is_plan_content = 0)
            AND (? IS NULL OR s.root_path = ?)
            AND (? = 0 OR c.title LIKE ? ESCAPE '\\' OR c.summary LIKE ? ESCAPE '\\' OR c.detail LIKE ? ESCAPE '\\')
        ORDER BY c.updated_at DESC, c.score DESC
        LIMIT ?;
        """

        return try self.query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(includePlanContent ? 1 : 0, at: 3, in: statement)
            self.bind(normalizedSourceRootPath, at: 4, in: statement)
            self.bind(normalizedSourceRootPath, at: 5, in: statement)
            self.bind(hasSearchTerm ? 1 : 0, at: 6, in: statement)
            self.bind(likeValue, at: 7, in: statement)
            self.bind(likeValue, at: 8, in: statement)
            self.bind(likeValue, at: 9, in: statement)
            self.bind(Int64(normalizedLimit), at: 10, in: statement)
        }, mapRow: { statement in
            MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown,
                sourceRootPath: self.readString(at: 2, in: statement) ?? "",
                title: self.readString(at: 3, in: statement) ?? "",
                summary: self.readString(at: 4, in: statement) ?? "",
                detail: self.readString(at: 5, in: statement) ?? "",
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                isPlanContent: sqlite3_column_int(statement, 7) == 1
            )
        })
    }

    func fetchSourceFile(
        sourceID: UUID,
        relativePath: String
    ) throws -> MemorySourceFile? {
        let sql = """
        SELECT
            id, source_id, absolute_path, relative_path, file_hash, file_size_bytes,
            modified_at, indexed_at, parse_error
        FROM memory_files
        WHERE source_id = ? AND relative_path = ?
        LIMIT 1;
        """

        let rows: [MemorySourceFile] = try query(sql: sql, bind: { statement in
            self.bind(sourceID.uuidString, at: 1, in: statement)
            self.bind(relativePath, at: 2, in: statement)
        }, mapRow: { statement in
            MemorySourceFile(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                sourceID: UUID(uuidString: self.readString(at: 1, in: statement) ?? "") ?? sourceID,
                absolutePath: self.readString(at: 2, in: statement) ?? "",
                relativePath: self.readString(at: 3, in: statement) ?? "",
                fileHash: self.readString(at: 4, in: statement) ?? "",
                fileSizeBytes: sqlite3_column_int64(statement, 5),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                parseError: self.readString(at: 8, in: statement)
            )
        })

        return rows.first
    }

    func hasIndexedEvents(forSourceFileID sourceFileID: UUID) throws -> Bool {
        let sql = """
        SELECT 1
        FROM memory_events
        WHERE source_file_id = ?
        LIMIT 1;
        """

        let rows: [Int64] = try query(sql: sql, bind: { statement in
            self.bind(sourceFileID.uuidString, at: 1, in: statement)
        }, mapRow: { statement in
            sqlite3_column_int64(statement, 0)
        })

        return !rows.isEmpty
    }

    func clearIndexedMemories() throws {
        try execute(sql: """
        DELETE FROM rewrite_suggestions
        WHERE card_id IN (
            SELECT id FROM memory_cards WHERE is_plan_content = 0
        );
        """)
        try execute(sql: "DELETE FROM memory_cards WHERE is_plan_content = 0;")
        try execute(sql: "DELETE FROM memory_events WHERE is_plan_content = 0;")
    }

    func clearIndexedContent(forSourceFileID sourceFileID: UUID) throws {
        try execute(sql: "DELETE FROM memory_events WHERE source_file_id = ?;", bind: { statement in
            self.bind(sourceFileID.uuidString, at: 1, in: statement)
        })
    }

    func clearAllIndexedData() throws {
        try execute(sql: "DELETE FROM rewrite_suggestions;")
        try execute(sql: "DELETE FROM memory_lessons;")
        try execute(sql: "DELETE FROM memory_cards;")
        try execute(sql: "DELETE FROM memory_events;")
        try execute(sql: "DELETE FROM memory_files;")
        try execute(sql: "DELETE FROM memory_sources;")
    }

    private static func ensureParentDirectory(for databaseURL: URL, fileManager: FileManager) throws {
        let parentDirectory = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw MemorySQLiteStoreError.failedToCreateDirectory(path: parentDirectory.path)
        }
    }

    private func fetchSchemaVersion() throws -> Int? {
        let sql = """
        SELECT schema_version
        FROM memory_schema_meta
        WHERE id = 1
        LIMIT 1;
        """

        let rows: [Int64] = try query(sql: sql, mapRow: { statement in
            sqlite3_column_int64(statement, 0)
        })

        guard let first = rows.first else { return nil }
        return Int(first)
    }

    private func lessonValidationState(from lesson: MemoryLesson) -> MemoryRewriteLessonValidationState {
        let metadata = lesson.sourceMetadata
        if let rawState = metadata["validation_state"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch rawState {
            case "invalidated":
                return .invalidated
            case "user-confirmed":
                return .userConfirmed
            case "indexed-validated":
                return .indexedValidated
            case "unvalidated":
                return .unvalidated
            default:
                break
            }
        }

        let origin = metadata["origin"]?.lowercased() ?? ""
        if origin.contains("prompt-rewrite-feedback") || origin.contains("user-feedback") {
            return .userConfirmed
        }
        if lesson.validationConfidence >= 0.80 {
            return .indexedValidated
        }
        return .unvalidated
    }

    private func lessonSelectionScore(for lesson: MemoryLesson) -> Double {
        let state = lessonValidationState(from: lesson)
        let stateBoost: Double
        switch state {
        case .userConfirmed:
            stateBoost = 0.50
        case .indexedValidated:
            stateBoost = 0.28
        case .unvalidated:
            stateBoost = 0.0
        case .invalidated:
            stateBoost = -1.0
        }
        return lesson.validationConfidence + stateBoost
    }

    private func shouldInvalidateExistingLesson(_ existingLesson: MemoryLesson, replacement: MemoryLesson) -> Bool {
        let replacementState = lessonValidationState(from: replacement)
        guard replacementState != .invalidated else { return false }

        let replacementScore = lessonSelectionScore(for: replacement)
        let existingScore = lessonSelectionScore(for: existingLesson)

        switch replacementState {
        case .userConfirmed:
            if replacementScore + 0.02 < existingScore {
                return false
            }
            if replacementScore > existingScore + 0.04 {
                return true
            }
            return replacement.updatedAt >= existingLesson.updatedAt
        case .indexedValidated:
            return replacementScore > existingScore + 0.05
        case .unvalidated:
            return replacementScore > existingScore + 0.08
        case .invalidated:
            return false
        }
    }

    private func isSameScenario(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }

        let lhsLower = lhs.lowercased()
        let rhsLower = rhs.lowercased()
        let shorterLength = min(lhsLower.count, rhsLower.count)
        if shorterLength >= 20,
           lhsLower.contains(rhsLower) || rhsLower.contains(lhsLower) {
            return true
        }

        let lhsTokens = tokenSet(for: lhsLower)
        let rhsTokens = tokenSet(for: rhsLower)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }

        let shared = lhsTokens.intersection(rhsTokens).count
        guard shared >= 3 else { return false }
        let minCount = min(lhsTokens.count, rhsTokens.count)
        let containment = Double(shared) / Double(max(1, minCount))
        return containment >= 0.68
    }

    private func isEquivalentCorrection(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }

        let lhsTokens = tokenSet(for: lhs)
        let rhsTokens = tokenSet(for: rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }

        let shared = lhsTokens.intersection(rhsTokens).count
        let minCount = min(lhsTokens.count, rhsTokens.count)
        if minCount <= 3 {
            return shared == minCount
        }

        let containment = Double(shared) / Double(max(1, minCount))
        return shared >= 3 && containment >= 0.84
    }

    private func tokenSet(for value: String, minTokenLength: Int = 3, limit: Int = 24) -> Set<String> {
        let tokens = MemoryTextNormalizer.keywords(from: value, limit: limit)
            .filter { $0.count >= minTokenLength }
            .map { $0.lowercased() }
        return Set(tokens)
    }

    private func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func open() throws {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(databaseURL.path, &db, openFlags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite error"
            sqlite3_close(db)
            throw MemorySQLiteStoreError.failedToOpenDatabase(path: databaseURL.path, code: code, message: message)
        }
        database = db
    }

    private func close() {
        lock.lock()
        defer { lock.unlock() }

        guard let database else { return }
        sqlite3_close(database)
        self.database = nil
    }

    private func execute(sql: String, bind: ((OpaquePointer) throws -> Void)? = nil) throws {
        try withDatabase { database in
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareCode == SQLITE_OK, let statement else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToPrepareStatement(sql: sql, code: prepareCode, message: message)
            }
            defer { sqlite3_finalize(statement) }

            try bind?(statement)

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToExecuteStatement(sql: sql, code: stepCode, message: message)
            }
        }
    }

    private func query<T>(
        sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil,
        mapRow: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try withDatabase { database in
            var statement: OpaquePointer?
            let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareCode == SQLITE_OK, let statement else {
                let message = String(cString: sqlite3_errmsg(database))
                throw MemorySQLiteStoreError.failedToPrepareStatement(sql: sql, code: prepareCode, message: message)
            }
            defer { sqlite3_finalize(statement) }

            try bind?(statement)

            var rows: [T] = []
            while true {
                let stepCode = sqlite3_step(statement)
                if stepCode == SQLITE_DONE {
                    break
                }
                if stepCode != SQLITE_ROW {
                    let message = String(cString: sqlite3_errmsg(database))
                    throw MemorySQLiteStoreError.failedToExecuteStatement(sql: sql, code: stepCode, message: message)
                }
                rows.append(try mapRow(statement))
            }
            return rows
        }
    }

    private func withDatabase<T>(_ block: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        guard let database else {
            throw MemorySQLiteStoreError.invalidDatabaseState
        }
        return try block(database)
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Int, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    private func readString(at index: Int32, in statement: OpaquePointer) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func encodeJSON<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return json
    }

    private func decodeStringArray(from json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    private func decodeStringDictionary(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    private func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
