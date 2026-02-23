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
    private static let schemaVersion = 1

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
