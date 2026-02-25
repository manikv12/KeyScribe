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
    private static let schemaVersion = 3
    private static let cleanupUnknownIssueKey = "issue-unassigned"
    private static let cleanupNoiseIssueKey = "issue-noise"

    struct MetadataCleanupReport: Hashable {
        let scannedCards: Int
        let metadataUpdatedCards: Int
        let lowValueInvalidatedCards: Int
        let removableMarkedCards: Int
        let removedCards: Int
    }

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
        CREATE TABLE IF NOT EXISTS memory_links (
            id TEXT PRIMARY KEY NOT NULL,
            from_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            to_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            link_type TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(from_card_id, to_card_id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_links_from_confidence
            ON memory_links(from_card_id, confidence DESC, updated_at DESC);
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

        try refreshMemoryLinks(for: card)
    }

    func refreshMemoryLinks(for card: MemoryCard, topLimit: Int = 12) throws {
        try ensureLinkSchema()
        let normalizedLimit = max(1, min(topLimit, 24))
        try execute(sql: "DELETE FROM memory_links WHERE from_card_id = ?;", bind: { statement in
            self.bind(card.id.uuidString, at: 1, in: statement)
        })

        let candidatesSQL = """
        SELECT
            id, source_id, source_file_id, event_id, provider, title, summary, detail, keywords_json,
            score, created_at, updated_at, is_plan_content, metadata_json
        FROM memory_cards
        WHERE id != ?
            AND provider = ?
            AND is_plan_content = 0
        ORDER BY updated_at DESC
        LIMIT 240;
        """

        let candidates: [MemoryCard] = try query(sql: candidatesSQL, bind: { statement in
            self.bind(card.id.uuidString, at: 1, in: statement)
            self.bind(card.provider.rawValue, at: 2, in: statement)
        }, mapRow: { statement in
            self.memoryCard(from: statement)
        })

        if candidates.isEmpty { return }

        let sorted = candidates.compactMap { candidate -> (MemoryCard, String, Double, [String: String])? in
            let scored = self.scoreLink(from: card, to: candidate)
            guard scored.confidence >= 0.35 else { return nil }
            return (candidate, scored.linkType, scored.confidence, scored.metadata)
        }.sorted { lhs, rhs in
            if lhs.2 == rhs.2 {
                return lhs.0.updatedAt > rhs.0.updatedAt
            }
            return lhs.2 > rhs.2
        }

        if sorted.isEmpty { return }
        let now = Date().timeIntervalSince1970
        for (candidate, linkType, confidence, metadata) in sorted.prefix(normalizedLimit) {
            let linkID = MemoryIdentifier.stableUUID(
                for: "link|\(card.id.uuidString)|\(candidate.id.uuidString)|\(linkType)"
            )
            let insertSQL = """
            INSERT INTO memory_links (
                id, from_card_id, to_card_id, link_type, confidence, metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(from_card_id, to_card_id) DO UPDATE SET
                link_type = excluded.link_type,
                confidence = excluded.confidence,
                metadata_json = excluded.metadata_json,
                updated_at = excluded.updated_at;
            """
            try execute(sql: insertSQL, bind: { statement in
                self.bind(linkID.uuidString, at: 1, in: statement)
                self.bind(card.id.uuidString, at: 2, in: statement)
                self.bind(candidate.id.uuidString, at: 3, in: statement)
                self.bind(linkType, at: 4, in: statement)
                self.bind(confidence, at: 5, in: statement)
                self.bind(self.encodeJSON(metadata, fallback: "{}"), at: 6, in: statement)
                self.bind(now, at: 7, in: statement)
                self.bind(now, at: 8, in: statement)
            })
        }
    }

    func fetchRelatedCards(
        forCardID cardID: UUID,
        minConfidence: Double = 0.35,
        limit: Int = 8
    ) throws -> [MemoryCard] {
        try ensureLinkSchema()
        let normalizedLimit = max(1, min(limit, 24))
        let sql = """
        SELECT
            c.id, c.source_id, c.source_file_id, c.event_id, c.provider, c.title, c.summary, c.detail,
            c.keywords_json, c.score, c.created_at, c.updated_at, c.is_plan_content, c.metadata_json
        FROM memory_links l
        JOIN memory_cards c ON c.id = l.to_card_id
        WHERE l.from_card_id = ?
            AND l.confidence >= ?
        ORDER BY l.confidence DESC, c.updated_at DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(cardID.uuidString, at: 1, in: statement)
            self.bind(minConfidence, at: 2, in: statement)
            self.bind(Int64(normalizedLimit), at: 3, in: statement)
        }, mapRow: { statement in
            self.memoryCard(from: statement)
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
            f.relative_path,
            c.metadata_json,
            e.metadata_json,
            c.title,
            c.summary,
            c.detail,
            e.event_timestamp,
            c.updated_at,
            c.is_plan_content
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE (? IS NULL OR c.provider = ?)
            AND (? = 1 OR c.is_plan_content = 0)
            AND (? IS NULL OR s.root_path = ?)
            AND (? = 0 OR c.title LIKE ? ESCAPE '\\' OR c.summary LIKE ? ESCAPE '\\' OR c.detail LIKE ? ESCAPE '\\')
        ORDER BY e.event_timestamp DESC, c.updated_at DESC, c.score DESC
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
            let provider = MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown
            let sourceRootPath = self.readString(at: 2, in: statement) ?? ""
            let sourceFileRelativePath = self.readString(at: 3, in: statement) ?? ""
            let cardMetadata = self.readString(at: 4, in: statement) ?? "{}"
            let eventMetadata = self.readString(at: 5, in: statement) ?? "{}"
            let title = self.readString(at: 6, in: statement) ?? ""
            let summary = self.readString(at: 7, in: statement) ?? ""
            let detail = self.readString(at: 8, in: statement) ?? ""
            let cardMetadataDictionary = self.decodeStringDictionary(from: cardMetadata)
            let eventMetadataDictionary = self.decodeStringDictionary(from: eventMetadata)
            let projectContext = self.inferProjectContext(
                provider: provider,
                cardMetadataJSON: cardMetadata,
                eventMetadataJSON: eventMetadata,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                title: title,
                summary: summary,
                detail: detail
            )

            return MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: provider,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                projectName: projectContext.projectName,
                repositoryName: projectContext.repositoryName,
                title: title,
                summary: summary,
                detail: detail,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isPlanContent: sqlite3_column_int(statement, 11) == 1,
                issueKey: cardMetadataDictionary["issue_key"] ?? eventMetadataDictionary["issue_key"],
                attemptNumber: self.parseInt(
                    cardMetadataDictionary["attempt_number"] ?? eventMetadataDictionary["attempt_number"]
                ),
                attemptCount: self.parseInt(
                    cardMetadataDictionary["attempt_count"] ?? eventMetadataDictionary["attempt_count"]
                ),
                outcomeStatus: cardMetadataDictionary["outcome_status"] ?? eventMetadataDictionary["outcome_status"],
                outcomeEvidence: cardMetadataDictionary["outcome_evidence"] ?? eventMetadataDictionary["outcome_evidence"],
                fixSummary: cardMetadataDictionary["fix_summary"] ?? eventMetadataDictionary["fix_summary"],
                validationState: cardMetadataDictionary["validation_state"] ?? eventMetadataDictionary["validation_state"],
                invalidatedByAttempt: self.parseInt(
                    cardMetadataDictionary["invalidated_by_attempt"] ?? eventMetadataDictionary["invalidated_by_attempt"]
                ),
                relationConfidence: nil,
                relationType: nil
            )
        })
    }

    func fetchRelatedIndexedEntries(
        forCardID cardID: UUID,
        includePlanContent: Bool = false,
        limit: Int = 8
    ) throws -> [MemoryIndexedEntry] {
        try ensureLinkSchema()
        let normalizedLimit = max(1, min(limit, 24))
        let sql = """
        SELECT
            c.id,
            c.provider,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json,
            c.title,
            c.summary,
            c.detail,
            e.event_timestamp,
            c.updated_at,
            c.is_plan_content,
            l.confidence,
            l.link_type
        FROM memory_links l
        JOIN memory_cards c ON c.id = l.to_card_id
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE l.from_card_id = ?
            AND (? = 1 OR c.is_plan_content = 0)
        ORDER BY l.confidence DESC, e.event_timestamp DESC
        LIMIT ?;
        """

        return try query(sql: sql, bind: { statement in
            self.bind(cardID.uuidString, at: 1, in: statement)
            self.bind(includePlanContent ? 1 : 0, at: 2, in: statement)
            self.bind(Int64(normalizedLimit), at: 3, in: statement)
        }, mapRow: { statement in
            let provider = MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown
            let sourceRootPath = self.readString(at: 2, in: statement) ?? ""
            let sourceFileRelativePath = self.readString(at: 3, in: statement) ?? ""
            let cardMetadata = self.readString(at: 4, in: statement) ?? "{}"
            let eventMetadata = self.readString(at: 5, in: statement) ?? "{}"
            let cardMetadataDictionary = self.decodeStringDictionary(from: cardMetadata)
            let eventMetadataDictionary = self.decodeStringDictionary(from: eventMetadata)
            let title = self.readString(at: 6, in: statement) ?? ""
            let summary = self.readString(at: 7, in: statement) ?? ""
            let detail = self.readString(at: 8, in: statement) ?? ""
            let projectContext = self.inferProjectContext(
                provider: provider,
                cardMetadataJSON: cardMetadata,
                eventMetadataJSON: eventMetadata,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                title: title,
                summary: summary,
                detail: detail
            )

            return MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: provider,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                projectName: projectContext.projectName,
                repositoryName: projectContext.repositoryName,
                title: title,
                summary: summary,
                detail: detail,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isPlanContent: sqlite3_column_int(statement, 11) == 1,
                issueKey: cardMetadataDictionary["issue_key"] ?? eventMetadataDictionary["issue_key"],
                attemptNumber: self.parseInt(
                    cardMetadataDictionary["attempt_number"] ?? eventMetadataDictionary["attempt_number"]
                ),
                attemptCount: self.parseInt(
                    cardMetadataDictionary["attempt_count"] ?? eventMetadataDictionary["attempt_count"]
                ),
                outcomeStatus: cardMetadataDictionary["outcome_status"] ?? eventMetadataDictionary["outcome_status"],
                outcomeEvidence: cardMetadataDictionary["outcome_evidence"] ?? eventMetadataDictionary["outcome_evidence"],
                fixSummary: cardMetadataDictionary["fix_summary"] ?? eventMetadataDictionary["fix_summary"],
                validationState: cardMetadataDictionary["validation_state"] ?? eventMetadataDictionary["validation_state"],
                invalidatedByAttempt: self.parseInt(
                    cardMetadataDictionary["invalidated_by_attempt"] ?? eventMetadataDictionary["invalidated_by_attempt"]
                ),
                relationConfidence: sqlite3_column_double(statement, 12),
                relationType: self.readString(at: 13, in: statement)
            )
        })
    }

    func fetchIssueTimelineEntries(
        issueKey: String,
        provider: MemoryProviderKind? = nil,
        includePlanContent: Bool = false,
        limit: Int = 40
    ) throws -> [MemoryIndexedEntry] {
        let normalizedIssueKey = issueKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedIssueKey.isEmpty else { return [] }
        let providerRawValue = provider?.rawValue
        let normalizedLimit = max(1, min(limit, 400))

        let sql = """
        SELECT
            c.id,
            c.provider,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json,
            c.title,
            c.summary,
            c.detail,
            e.event_timestamp,
            c.updated_at,
            c.is_plan_content
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE (? IS NULL OR c.provider = ?)
            AND (? = 1 OR c.is_plan_content = 0)
        ORDER BY e.event_timestamp DESC
        LIMIT ?;
        """

        let entries: [MemoryIndexedEntry] = try query(sql: sql, bind: { statement in
            self.bind(providerRawValue, at: 1, in: statement)
            self.bind(providerRawValue, at: 2, in: statement)
            self.bind(includePlanContent ? 1 : 0, at: 3, in: statement)
            self.bind(Int64(normalizedLimit), at: 4, in: statement)
        }, mapRow: { statement in
            let provider = MemoryProviderKind(rawValue: self.readString(at: 1, in: statement) ?? "") ?? .unknown
            let sourceRootPath = self.readString(at: 2, in: statement) ?? ""
            let sourceFileRelativePath = self.readString(at: 3, in: statement) ?? ""
            let cardMetadata = self.readString(at: 4, in: statement) ?? "{}"
            let eventMetadata = self.readString(at: 5, in: statement) ?? "{}"
            let cardMetadataDictionary = self.decodeStringDictionary(from: cardMetadata)
            let eventMetadataDictionary = self.decodeStringDictionary(from: eventMetadata)
            let title = self.readString(at: 6, in: statement) ?? ""
            let summary = self.readString(at: 7, in: statement) ?? ""
            let detail = self.readString(at: 8, in: statement) ?? ""
            let projectContext = self.inferProjectContext(
                provider: provider,
                cardMetadataJSON: cardMetadata,
                eventMetadataJSON: eventMetadata,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                title: title,
                summary: summary,
                detail: detail
            )

            return MemoryIndexedEntry(
                id: UUID(uuidString: self.readString(at: 0, in: statement) ?? "") ?? UUID(),
                provider: provider,
                sourceRootPath: sourceRootPath,
                sourceFileRelativePath: sourceFileRelativePath,
                projectName: projectContext.projectName,
                repositoryName: projectContext.repositoryName,
                title: title,
                summary: summary,
                detail: detail,
                eventTimestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                isPlanContent: sqlite3_column_int(statement, 11) == 1,
                issueKey: cardMetadataDictionary["issue_key"] ?? eventMetadataDictionary["issue_key"],
                attemptNumber: self.parseInt(
                    cardMetadataDictionary["attempt_number"] ?? eventMetadataDictionary["attempt_number"]
                ),
                attemptCount: self.parseInt(
                    cardMetadataDictionary["attempt_count"] ?? eventMetadataDictionary["attempt_count"]
                ),
                outcomeStatus: cardMetadataDictionary["outcome_status"] ?? eventMetadataDictionary["outcome_status"],
                outcomeEvidence: cardMetadataDictionary["outcome_evidence"] ?? eventMetadataDictionary["outcome_evidence"],
                fixSummary: cardMetadataDictionary["fix_summary"] ?? eventMetadataDictionary["fix_summary"],
                validationState: cardMetadataDictionary["validation_state"] ?? eventMetadataDictionary["validation_state"],
                invalidatedByAttempt: self.parseInt(
                    cardMetadataDictionary["invalidated_by_attempt"] ?? eventMetadataDictionary["invalidated_by_attempt"]
                ),
                relationConfidence: nil,
                relationType: nil
            )
        })

        let filtered = entries.filter { entry in
            (entry.issueKey?.lowercased() ?? "") == normalizedIssueKey
        }
        return filtered.sorted { lhs, rhs in
            let leftAttempt = lhs.attemptNumber ?? Int.max
            let rightAttempt = rhs.attemptNumber ?? Int.max
            if leftAttempt == rightAttempt {
                return lhs.eventTimestamp < rhs.eventTimestamp
            }
            return leftAttempt < rightAttempt
        }
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
        try execute(sql: "DELETE FROM memory_links;")
        try execute(sql: "DELETE FROM memory_cards;")
        try execute(sql: "DELETE FROM memory_events;")
        try execute(sql: "DELETE FROM memory_files;")
        try execute(sql: "DELETE FROM memory_sources;")
    }

    func backfillAndCleanupMetadata(
        removeMarkedLowValueCards: Bool = false,
        limit: Int = 5000
    ) throws -> MetadataCleanupReport {
        let normalizedLimit = max(1, min(limit, 25_000))
        let now = Date()
        let nowEpoch = now.timeIntervalSince1970
        let markedAt = iso8601Timestamp(now)
        let issuePattern = #"[A-Za-z][A-Za-z0-9]{1,14}-[0-9]{1,8}"#

        struct CleanupRow {
            let cardID: String
            let title: String
            let summary: String
            let detail: String
            let score: Double
            let sourceRootPath: String
            let sourceFileRelativePath: String
            let cardMetadataJSON: String
            let eventMetadataJSON: String
        }

        let sql = """
        SELECT
            c.id,
            c.provider,
            c.title,
            c.summary,
            c.detail,
            c.score,
            s.root_path,
            f.relative_path,
            c.metadata_json,
            e.metadata_json
        FROM memory_cards c
        JOIN memory_sources s ON s.id = c.source_id
        JOIN memory_files f ON f.id = c.source_file_id
        JOIN memory_events e ON e.id = c.event_id
        WHERE c.is_plan_content = 0
        ORDER BY c.updated_at DESC
        LIMIT ?;
        """

        let rows: [CleanupRow] = try query(sql: sql, bind: { statement in
            self.bind(Int64(normalizedLimit), at: 1, in: statement)
        }, mapRow: { statement in
            CleanupRow(
                cardID: self.readString(at: 0, in: statement) ?? "",
                title: self.readString(at: 2, in: statement) ?? "",
                summary: self.readString(at: 3, in: statement) ?? "",
                detail: self.readString(at: 4, in: statement) ?? "",
                score: sqlite3_column_double(statement, 5),
                sourceRootPath: self.readString(at: 6, in: statement) ?? "",
                sourceFileRelativePath: self.readString(at: 7, in: statement) ?? "",
                cardMetadataJSON: self.readString(at: 8, in: statement) ?? "{}",
                eventMetadataJSON: self.readString(at: 9, in: statement) ?? "{}"
            )
        })

        var metadataUpdatedCards = 0
        var lowValueInvalidatedCards = 0
        var removableMarkedCards = 0
        var removedCards = 0

        for row in rows {
            var cardMetadata = normalizedMetadataKeys(decodeStringDictionary(from: row.cardMetadataJSON))
            let originalCardMetadata = cardMetadata
            let eventMetadata = normalizedMetadataKeys(decodeStringDictionary(from: row.eventMetadataJSON))

            var mergedMetadata = eventMetadata
            for (key, value) in cardMetadata {
                mergedMetadata[key] = value
            }

            let isLowValue = isLowValueMemoryCard(
                title: row.title,
                summary: row.summary,
                detail: row.detail,
                score: row.score,
                metadata: mergedMetadata
            )

            let issueKey = normalizedIssueKey(
                from: cardMetadata["issue_key"]
                    ?? eventMetadata["issue_key"]
                    ?? firstIssueKeyMatch(
                        in: [
                            row.title,
                            row.summary,
                            row.detail,
                            row.sourceFileRelativePath,
                            row.sourceRootPath
                        ],
                        pattern: issuePattern
                    )
            )

            var validationState = canonicalValidationState(
                cardMetadata["validation_state"] ?? eventMetadata["validation_state"]
            )
            var outcomeStatus = canonicalOutcomeStatus(
                cardMetadata["outcome_status"] ?? eventMetadata["outcome_status"]
            )

            let protectedHighSignal = isHighSignalMemoryCard(
                title: row.title,
                summary: row.summary,
                detail: row.detail,
                score: row.score,
                issueKey: issueKey,
                outcomeStatus: outcomeStatus,
                validationState: validationState
            )

            if issueKey == nil {
                cardMetadata["issue_key"] = (isLowValue && !protectedHighSignal)
                    ? Self.cleanupNoiseIssueKey
                    : Self.cleanupUnknownIssueKey
            } else if let issueKey {
                cardMetadata["issue_key"] = issueKey
            }

            if validationState == nil {
                if isLowValue && !protectedHighSignal {
                    validationState = MemoryRewriteLessonValidationState.invalidated.rawValue
                } else if outcomeStatus == "fixed" {
                    validationState = MemoryRewriteLessonValidationState.indexedValidated.rawValue
                } else {
                    validationState = MemoryRewriteLessonValidationState.unvalidated.rawValue
                }
            }

            if outcomeStatus == nil {
                switch validationState {
                case MemoryRewriteLessonValidationState.userConfirmed.rawValue,
                    MemoryRewriteLessonValidationState.indexedValidated.rawValue:
                    outcomeStatus = "fixed"
                case MemoryRewriteLessonValidationState.invalidated.rawValue:
                    outcomeStatus = "invalidated"
                default:
                    outcomeStatus = "attempted"
                }
            }

            if let validationState {
                cardMetadata["validation_state"] = validationState
            }
            if let outcomeStatus {
                cardMetadata["outcome_status"] = outcomeStatus
            }

            if isLowValue && !protectedHighSignal {
                if cardMetadata["validation_state"] != MemoryRewriteLessonValidationState.invalidated.rawValue {
                    cardMetadata["validation_state"] = MemoryRewriteLessonValidationState.invalidated.rawValue
                    lowValueInvalidatedCards += 1
                }
                cardMetadata["outcome_status"] = "invalidated"
                if cardMetadata["issue_key"] == Self.cleanupUnknownIssueKey {
                    cardMetadata["issue_key"] = Self.cleanupNoiseIssueKey
                }
                if cardMetadata["cleanup_candidate"] != "removable" {
                    cardMetadata["cleanup_candidate"] = "removable"
                    removableMarkedCards += 1
                }
                if cardMetadata["cleanup_marked_at"] == nil {
                    cardMetadata["cleanup_marked_at"] = markedAt
                }

                if removeMarkedLowValueCards,
                   cardMetadata["validation_state"] == MemoryRewriteLessonValidationState.invalidated.rawValue {
                    try execute(sql: "DELETE FROM memory_cards WHERE id = ?;", bind: { statement in
                        self.bind(row.cardID, at: 1, in: statement)
                    })
                    removedCards += 1
                    continue
                }
            }

            if cardMetadata != originalCardMetadata {
                try execute(sql: """
                UPDATE memory_cards
                SET metadata_json = ?, updated_at = ?
                WHERE id = ?;
                """, bind: { statement in
                    self.bind(self.encodeJSON(cardMetadata, fallback: "{}"), at: 1, in: statement)
                    self.bind(nowEpoch, at: 2, in: statement)
                    self.bind(row.cardID, at: 3, in: statement)
                })
                metadataUpdatedCards += 1
            }
        }

        return MetadataCleanupReport(
            scannedCards: rows.count,
            metadataUpdatedCards: metadataUpdatedCards,
            lowValueInvalidatedCards: lowValueInvalidatedCards,
            removableMarkedCards: removableMarkedCards,
            removedCards: removedCards
        )
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

    private func memoryCard(from statement: OpaquePointer) -> MemoryCard {
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
    }

    private func scoreLink(from source: MemoryCard, to candidate: MemoryCard) -> (
        linkType: String,
        confidence: Double,
        metadata: [String: String]
    ) {
        let sourceIssue = source.metadata["issue_key"]?.lowercased()
        let candidateIssue = candidate.metadata["issue_key"]?.lowercased()
        let sameIssue = sourceIssue != nil && sourceIssue == candidateIssue

        let sourceKeywords = Set(source.keywords.map { $0.lowercased() })
        let candidateKeywords = Set(candidate.keywords.map { $0.lowercased() })
        let shared = sourceKeywords.intersection(candidateKeywords)
        let keywordUnionCount = max(1, sourceKeywords.union(candidateKeywords).count)
        let keywordJaccard = Double(shared.count) / Double(keywordUnionCount)

        let projectA = contextLabel(from: source.metadata, keys: ["project", "workspace", "repository"])
        let projectB = contextLabel(from: candidate.metadata, keys: ["project", "workspace", "repository"])
        let sameProject = !projectA.isEmpty && !projectB.isEmpty && projectA.caseInsensitiveCompare(projectB) == .orderedSame

        var confidence = 0.0
        var linkType = "similar_topic"
        if sameIssue {
            confidence += 0.55
            linkType = "same_issue"
        }
        confidence += keywordJaccard * 0.35
        if sameProject {
            confidence += 0.1
        }
        confidence += min(candidate.score, source.score) * 0.05

        let validationState = (candidate.metadata["validation_state"] ?? "").lowercased()
        switch validationState {
        case "indexed-validated", "user-confirmed":
            confidence += 0.08
        case "invalidated":
            confidence -= 0.18
        default:
            confidence += 0.02
        }

        if sameIssue,
           let sourceAttempt = parseInt(source.metadata["attempt_number"]),
           let candidateAttempt = parseInt(candidate.metadata["attempt_number"]),
           sourceAttempt > candidateAttempt {
            linkType = "follow_up"
        }

        let bounded = min(1.0, max(0.0, confidence))
        let metadata: [String: String] = [
            "shared_keywords": "\(shared.count)",
            "keyword_jaccard": String(format: "%.3f", keywordJaccard),
            "same_project": sameProject ? "true" : "false",
            "same_issue": sameIssue ? "true" : "false",
            "validation_state": validationState
        ]
        return (linkType, bounded, metadata)
    }

    private func contextLabel(from metadata: [String: String], keys: [String]) -> String {
        for key in keys {
            if let value = metadata[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        return ""
    }

    private func ensureLinkSchema() throws {
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_links (
            id TEXT PRIMARY KEY NOT NULL,
            from_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            to_card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
            link_type TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0,
            metadata_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(from_card_id, to_card_id)
        );
        """)

        try execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_memory_links_from_confidence
            ON memory_links(from_card_id, confidence DESC, updated_at DESC);
        """)
    }

    private func parseInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func inferProjectContext(
        provider: MemoryProviderKind,
        cardMetadataJSON: String,
        eventMetadataJSON: String,
        sourceRootPath: String,
        sourceFileRelativePath: String,
        title: String,
        summary: String,
        detail: String
    ) -> (projectName: String?, repositoryName: String?) {
        let cardMetadata = normalizedMetadataKeys(decodeStringDictionary(from: cardMetadataJSON))
        let eventMetadata = normalizedMetadataKeys(decodeStringDictionary(from: eventMetadataJSON))

        let repositoryKeys = [
            "repository", "repository_name", "repo", "repo_name",
            "git_repository", "git_repo", "repositorypath"
        ]
        let baseProjectKeys = [
            "project", "project_name", "workspace", "workspace_name",
            "folder", "cwd", "working_directory", "workdir", "path", "uri"
        ]
        let projectKeys = providerSpecificProjectKeys(for: provider) + baseProjectKeys

        let repositoryValue = firstContextValue(
            keys: repositoryKeys,
            primary: cardMetadata,
            secondary: eventMetadata
        )
        let projectValue = firstContextValue(
            keys: projectKeys,
            primary: cardMetadata,
            secondary: eventMetadata
        )

        var repositoryName = normalizeContextLabel(repositoryValue)
        var projectName = normalizeContextLabel(projectValue)

        let textPathCandidate = extractPathLikeValue(
            from: [detail, summary, title]
        )

        if repositoryName == nil {
            repositoryName = derivePathLabel(from: textPathCandidate ?? sourceFileRelativePath)
        }
        if projectName == nil {
            projectName = derivePathLabel(from: textPathCandidate ?? sourceFileRelativePath)
                ?? derivePathLabel(from: sourceRootPath)
        }

        if projectName == nil {
            projectName = repositoryName
        }

        if let projectName,
           let repositoryName,
           projectName.caseInsensitiveCompare(repositoryName) == .orderedSame {
            return (projectName, nil)
        }

        return (projectName, repositoryName)
    }

    private func providerSpecificProjectKeys(for provider: MemoryProviderKind) -> [String] {
        switch provider {
        case .codex:
            return ["cwd"]
        case .opencode:
            return ["workspace", "cwd", "path"]
        case .claude:
            return ["project", "cwd"]
        case .cursor, .windsurf:
            return ["folder", "workspace", "path", "uri"]
        case .copilot:
            return ["workspace", "folder", "path"]
        case .kimi, .gemini, .codeium:
            return ["path", "cwd", "workspace", "project", "folder"]
        case .unknown:
            return []
        }
    }

    private func normalizedMetadataKeys(_ metadata: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            normalized[key.lowercased()] = value
        }
        return normalized
    }

    private func firstContextValue(
        keys: [String],
        primary: [String: String],
        secondary: [String: String]
    ) -> String? {
        for key in keys {
            let normalizedKey = key.lowercased()
            if let value = primary[normalizedKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            if let value = secondary[normalizedKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeContextLabel(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        value = value.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("file://"),
           let url = URL(string: value) {
            value = url.path
        }
        if let decoded = value.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = decoded
        }

        if value.contains("/") {
            return derivePathLabel(from: value)
        }

        let collapsed = MemoryTextNormalizer.collapsedWhitespace(value)
        guard !collapsed.isEmpty else { return nil }
        let lowered = collapsed.lowercased()
        let genericValues: Set<String> = [
            "workspace", "project", "repository", "repo", "unknown", "state", "storage", "clipboard"
        ]
        guard !genericValues.contains(lowered) else { return nil }
        guard !looksLikeOpaqueIdentifier(collapsed) else { return nil }
        guard !isNumericOrDatePathComponent(collapsed) else { return nil }
        return collapsed
    }

    private func extractPathLikeValue(from texts: [String]) -> String? {
        let patterns = [
            #"file://[^\s"'<>\]\[)\(,;]+"#,
            #"/(?:Users|Volumes|private)/[^\s"'<>\]\[)\(,;]{3,}"#,
            #"[A-Za-z]:\\[^\s"'<>\]\[)\(,;]{3,}"#
        ]

        for text in texts {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                    continue
                }
                let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                guard let match = regex.firstMatch(in: normalized, options: [], range: range),
                      let tokenRange = Range(match.range(at: 0), in: normalized) else {
                    continue
                }
                let token = String(normalized[tokenRange])
                let cleaned = cleanedExtractedPathToken(token)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return nil
    }

    private func cleanedExtractedPathToken(_ rawToken: String) -> String {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>,;")
        token = token.trimmingCharacters(in: trimCharacters)
        token = token.replacingOccurrences(of: "\\", with: "/")
        if let decoded = token.removingPercentEncoding,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            token = decoded
        }
        return token
    }

    private func derivePathLabel(from rawPath: String) -> String? {
        let normalized = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty else { return nil }

        let rawComponents = normalized
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawComponents.isEmpty else { return nil }

        for component in rawComponents.reversed() {
            var candidate = component.removingPercentEncoding ?? component
            candidate = stripTrackerHashSuffix(from: candidate)
            let lowered = candidate.lowercased()
            if isLikelyFilenameComponent(candidate) {
                continue
            }
            guard !isGenericPathComponent(lowered) else { continue }
            guard !looksLikeOpaqueIdentifier(candidate) else { continue }
            guard !isNumericOrDatePathComponent(candidate) else { continue }
            if candidate.count > 96 { continue }
            return candidate
        }

        return nil
    }

    private func isGenericPathComponent(_ value: String) -> Bool {
        let genericComponents: Set<String> = [
            "users", "user", "library", "application support", "workspace", "workspacestorage",
            "globalstorage", "storage", "state", "session", "sessions", "chat", "history",
            "archives", "archived_sessions", "projects", "repos", "repositories", "repo",
            "memory", "index", "unknown", "tmp", "temp", "active", "default", "clipboard",
            "worktree", "worktrees",
            ".codex", ".claude", ".opencode",
            "codex", "claude", "opencode", "cursor", "copilot", "windsurf", "codeium", "gemini", "kimi"
        ]
        return genericComponents.contains(value)
    }

    private func looksLikeOpaqueIdentifier(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 12 else { return false }

        if normalized.range(of: "^[0-9a-f]{12,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-f-]{20,}$", options: .regularExpression) != nil {
            return true
        }
        if normalized.range(of: "^[0-9a-z_-]{24,}$", options: .regularExpression) != nil,
           normalized.rangeOfCharacter(from: CharacterSet.letters) == nil {
            return true
        }
        return false
    }

    private func isNumericOrDatePathComponent(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return true
        }
        let datePatterns = [
            #"^[0-9]{4}[-_.][0-9]{1,2}([\-_.][0-9]{1,2})?$"#,
            #"^[0-9]{8}$"#,
            #"^[0-9]{6}$"#,
            #"^[0-9]{1,2}[-_.][0-9]{1,2}([\-_.][0-9]{2,4})?$"#
        ]
        return datePatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    private func stripTrackerHashSuffix(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.lowercased() == "no_repo" {
            return ""
        }

        let parts = trimmed.split(separator: "_")
        guard parts.count >= 2, let last = parts.last else {
            return trimmed
        }

        let lastPart = String(last)
        if lastPart.range(of: "^[0-9a-f]{8,}$", options: .regularExpression) != nil {
            return parts.dropLast().map(String.init).joined(separator: "_")
        }
        return trimmed
    }

    private func isLikelyFilenameComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix(".") {
            return false
        }
        return trimmed.range(of: "\\.[A-Za-z]{1,8}$", options: .regularExpression) != nil
    }

    private func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func canonicalValidationState(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else { return nil }

        if rawValue == MemoryRewriteLessonValidationState.invalidated.rawValue || rawValue.contains("invalid") {
            return MemoryRewriteLessonValidationState.invalidated.rawValue
        }
        if rawValue == MemoryRewriteLessonValidationState.userConfirmed.rawValue || rawValue.contains("user") {
            return MemoryRewriteLessonValidationState.userConfirmed.rawValue
        }
        if rawValue == MemoryRewriteLessonValidationState.indexedValidated.rawValue || rawValue.contains("validated") {
            return MemoryRewriteLessonValidationState.indexedValidated.rawValue
        }
        if rawValue == MemoryRewriteLessonValidationState.unvalidated.rawValue || rawValue.contains("pending") {
            return MemoryRewriteLessonValidationState.unvalidated.rawValue
        }
        return nil
    }

    private func canonicalOutcomeStatus(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else { return nil }

        switch rawValue {
        case "fixed", "resolved", "success", "successful", "pass", "passed":
            return "fixed"
        case "invalidated", "invalid", "noise", "ignored", "discarded":
            return "invalidated"
        case "failed", "failure", "regressed", "error", "broken":
            return "failed"
        case "attempted", "responded", "in_progress", "in-progress", "started", "open":
            return "attempted"
        default:
            return nil
        }
    }

    private func normalizedIssueKey(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        let upper = rawValue.uppercased()
        if upper.range(of: "^[A-Z][A-Z0-9]{1,14}-[0-9]{1,8}$", options: .regularExpression) != nil {
            return upper
        }
        return nil
    }

    private func firstIssueKeyMatch(in texts: [String], pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        for text in texts {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let matchedRange = Range(match.range, in: text) else {
                continue
            }
            return String(text[matchedRange]).uppercased()
        }
        return nil
    }

    private func isLowValueMemoryCard(
        title: String,
        summary: String,
        detail: String,
        score: Double,
        metadata: [String: String]
    ) -> Bool {
        let lowerTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(lowerTitle) \(lowerSummary) \(lowerDetail)"

        let rewriteIndicators = ["->", "=>", "→", "rewrite", "suggested", "correction"]
        if rewriteIndicators.contains(where: { combined.contains($0) }) {
            return false
        }

        let genericTitles: Set<String> = [
            "chat", "message", "conversation", "session", "history", "note", "section", "event",
            "workspace", "storage", "state"
        ]
        if genericTitles.contains(lowerTitle) || genericTitles.contains(lowerSummary) {
            return true
        }
        if lowerTitle == "q&a: hi" || lowerTitle == "q&a: hello" || lowerTitle == "q&a: hey" {
            return true
        }
        let outcomeStatus = (metadata["outcome_status"] ?? "").lowercased()
        let validationState = (metadata["validation_state"] ?? "").lowercased()
        if (outcomeStatus == "responded" || outcomeStatus == "attempted" || outcomeStatus.isEmpty),
           (validationState == "unvalidated" || validationState.isEmpty),
           (lowerSummary.hasPrefix("q: hi")
                || lowerSummary.hasPrefix("q: hello")
                || lowerSummary.hasPrefix("q: hey")
                || lowerDetail.contains("how can i help")
                || lowerDetail.contains("how can i assist")) {
            return true
        }

        let alphaWords = combined.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains(where: \.isLetter)
        }
        if alphaWords.count < 5 {
            return true
        }

        return score < 0.35
    }

    private func isHighSignalMemoryCard(
        title: String,
        summary: String,
        detail: String,
        score: Double,
        issueKey: String?,
        outcomeStatus: String?,
        validationState: String?
    ) -> Bool {
        let lowerTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(lowerTitle) \(lowerSummary) \(lowerDetail)"

        if let validationState,
           validationState == MemoryRewriteLessonValidationState.userConfirmed.rawValue
            || validationState == MemoryRewriteLessonValidationState.indexedValidated.rawValue {
            return true
        }
        if let outcomeStatus, outcomeStatus == "fixed" {
            return true
        }
        if let issueKey,
           issueKey != Self.cleanupUnknownIssueKey,
           issueKey != Self.cleanupNoiseIssueKey {
            return true
        }
        if combined.contains("->") || combined.contains("rewrite") || combined.contains("correction") {
            return score >= 0.50
        }
        return score >= 0.85
    }
}
