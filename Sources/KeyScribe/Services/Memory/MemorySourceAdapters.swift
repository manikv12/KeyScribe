import Foundation

protocol MemorySourceAdapter {
    var provider: MemoryProviderKind { get }
    var maxFileSizeBytes: Int64 { get }
    var allowedFileExtensions: Set<String> { get }

    func discoverFiles(
        in rootURL: URL,
        fileManager: FileManager,
        maxFiles: Int
    ) -> [URL]

    func parse(
        fileURL: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> [MemoryEventDraft]
}

enum MemorySourceAdapterError: LocalizedError {
    case unreadableData(path: String)
    case unsupportedFormat(path: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableData(path):
            return "Unreadable source data at path: \(path)"
        case let .unsupportedFormat(path):
            return "Unsupported source format at path: \(path)"
        }
    }
}

struct MemorySourceAdapterRegistry {
    let adaptersByProvider: [MemoryProviderKind: any MemorySourceAdapter]

    init(adapters: [any MemorySourceAdapter] = MemorySourceAdapterRegistry.defaultAdapters()) {
        var dictionary: [MemoryProviderKind: any MemorySourceAdapter] = [:]
        dictionary.reserveCapacity(adapters.count)
        for adapter in adapters {
            dictionary[adapter.provider] = adapter
        }
        adaptersByProvider = dictionary
    }

    func adapter(for provider: MemoryProviderKind) -> (any MemorySourceAdapter)? {
        adaptersByProvider[provider]
    }

    static func defaultAdapters() -> [any MemorySourceAdapter] {
        [
            CodexMemorySourceAdapter(),
            OpenCodeMemorySourceAdapter(),
            ClaudeMemorySourceAdapter(),
            CopilotMemorySourceAdapter(),
            CursorMemorySourceAdapter(),
            KimiMemorySourceAdapter(),
            GeminiMemorySourceAdapter(),
            WindsurfMemorySourceAdapter(),
            CodeiumMemorySourceAdapter()
        ]
    }
}

private enum MemoryAdapterFileDiscovery {
    private static let parseableFilenameNeedles: [String] = [
        "conversation", "conversations", "chat", "history", "session", "prompt",
        "rewrite", "transcript", "memory", "messages"
    ]

    static func discoverFiles(
        in rootURL: URL,
        fileManager: FileManager,
        allowedFileExtensions: Set<String>,
        maxFileSizeBytes: Int64,
        maxFiles: Int
    ) -> [URL] {
        guard maxFiles > 0 else { return [] }
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
            .nameKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var files: [URL] = []
        files.reserveCapacity(min(maxFiles, 256))

        for case let fileURL as URL in enumerator {
            if files.count >= maxFiles {
                break
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }

            if values.isDirectory == true {
                let directoryName = (values.name ?? fileURL.lastPathComponent).lowercased()
                if shouldSkipDirectory(named: directoryName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }

            let ext = fileURL.pathExtension.lowercased()
            let fileName = (values.name ?? fileURL.lastPathComponent).lowercased()
            if !shouldIncludeFile(
                named: fileName,
                extension: ext,
                allowedFileExtensions: allowedFileExtensions
            ) {
                continue
            }

            if let size = values.fileSize, Int64(size) > maxFileSizeBytes {
                continue
            }

            files.append(fileURL.standardizedFileURL)
        }

        return files.sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private static func shouldSkipDirectory(named directoryName: String) -> Bool {
        switch directoryName {
        case ".git", "node_modules", "cache", "caches", "tmp", "temp", "gpucache", "code cache", "blob_storage":
            return true
        default:
            return false
        }
    }

    private static func shouldIncludeFile(
        named fileName: String,
        extension fileExtension: String,
        allowedFileExtensions: Set<String>
    ) -> Bool {
        guard !allowedFileExtensions.isEmpty else { return true }

        if !fileExtension.isEmpty {
            return allowedFileExtensions.contains(fileExtension)
        }

        return parseableFilenameNeedles.contains { needle in
            fileName.contains(needle)
        }
    }
}

private enum MemoryAdapterEventParser {
    private static let fractionalISO8601Parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601Parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseFile(
        provider: MemoryProviderKind,
        fileURL: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> [MemoryEventDraft] {
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            throw MemorySourceAdapterError.unreadableData(path: fileURL.path)
        }
        if data.isEmpty { return [] }

        let ext = fileURL.pathExtension.lowercased()
        if ext == "json" {
            return parseJSONData(
                provider: provider,
                data: data,
                relativePath: relativePath,
                fallbackRawPayload: String(data: data, encoding: .utf8)
            )
        }

        if ext == "jsonl" || ext == "ndjson" || fileURL.lastPathComponent.lowercased().contains("jsonl") {
            return parseJSONLinesData(provider: provider, data: data, relativePath: relativePath)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw MemorySourceAdapterError.unreadableData(path: fileURL.path)
        }
        return parseText(provider: provider, text: text, relativePath: relativePath)
    }

    private static func parseJSONData(
        provider: MemoryProviderKind,
        data: Data,
        relativePath: String,
        fallbackRawPayload: String?
    ) -> [MemoryEventDraft] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            if let fallbackRawPayload {
                return parseText(provider: provider, text: fallbackRawPayload, relativePath: relativePath)
            }
            return []
        }

        if let array = object as? [Any] {
            var drafts: [MemoryEventDraft] = []
            drafts.reserveCapacity(array.count)
            for entry in array {
                drafts.append(contentsOf: parseJSONNode(provider: provider, node: entry, relativePath: relativePath))
            }
            return drafts
        }

        return parseJSONNode(provider: provider, node: object, relativePath: relativePath)
    }

    private static func parseJSONLinesData(
        provider: MemoryProviderKind,
        data: Data,
        relativePath: String
    ) -> [MemoryEventDraft] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)

        var drafts: [MemoryEventDraft] = []
        drafts.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed]) else {
                continue
            }
            drafts.append(contentsOf: parseJSONNode(provider: provider, node: object, relativePath: relativePath))
        }

        return drafts
    }

    private static func parseJSONNode(
        provider: MemoryProviderKind,
        node: Any,
        relativePath: String
    ) -> [MemoryEventDraft] {
        if let array = node as? [Any] {
            return array.flatMap { parseJSONNode(provider: provider, node: $0, relativePath: relativePath) }
        }

        guard let dictionary = node as? [String: Any] else {
            let body = MemoryTextNormalizer.normalizedBody("\(node)")
            guard !body.isEmpty else { return [] }
            return [makeDraft(
                provider: provider,
                relativePath: relativePath,
                title: "\(provider.displayName) Event",
                body: body,
                kind: inferKind(from: relativePath, valueHint: nil),
                timestamp: Date(),
                nativeSummary: nil,
                metadata: [:],
                rawPayload: body
            )]
        }

        if let messages = dictionary["messages"] as? [Any], !messages.isEmpty {
            return messages.enumerated().compactMap { index, messageNode in
                guard let message = messageNode as? [String: Any] else { return nil }
                let role = readString(from: message, keys: ["role", "author", "speaker"])
                let body = readString(from: message, keys: ["content", "text", "message", "body", "value"])
                guard let body else { return nil }
                let titlePrefix = role?.capitalized ?? "Message"
                let title = "\(titlePrefix) \(index + 1)"
                let timestamp = readDate(from: message, keys: ["timestamp", "created_at", "createdAt", "time", "date"]) ?? Date()
                let kind = inferKind(from: relativePath, valueHint: role)

                return makeDraft(
                    provider: provider,
                    relativePath: relativePath,
                    title: title,
                    body: body,
                    kind: kind,
                    timestamp: timestamp,
                    nativeSummary: readString(from: message, keys: ["summary", "native_summary"]),
                    metadata: flattenMetadata(from: message),
                    rawPayload: serializeJSON(dictionary: message)
                )
            }
        }

        let title = readString(from: dictionary, keys: ["title", "subject", "name", "label"])
            ?? MemoryTextNormalizer.normalizedTitle(fileStem(from: relativePath))
        let body = readString(from: dictionary, keys: ["content", "text", "message", "body", "prompt", "response", "completion", "output"])
            ?? serializeJSON(dictionary: dictionary)
        let timestamp = readDate(from: dictionary, keys: ["timestamp", "created_at", "createdAt", "time", "date"]) ?? Date()
        let kindHint = readString(from: dictionary, keys: ["kind", "type", "event", "category", "role"])
        let kind = inferKind(from: relativePath, valueHint: kindHint)
        let summary = readString(from: dictionary, keys: ["summary", "native_summary", "abstract"])

        return [makeDraft(
            provider: provider,
            relativePath: relativePath,
            title: title,
            body: body,
            kind: kind,
            timestamp: timestamp,
            nativeSummary: summary,
            metadata: flattenMetadata(from: dictionary),
            rawPayload: serializeJSON(dictionary: dictionary)
        )]
    }

    private static func parseText(
        provider: MemoryProviderKind,
        text: String,
        relativePath: String
    ) -> [MemoryEventDraft] {
        let normalized = MemoryTextNormalizer.normalizedBody(text)
        guard !normalized.isEmpty else { return [] }

        if relativePath.lowercased().hasSuffix(".md") || relativePath.lowercased().hasSuffix(".markdown") {
            let sections = markdownSections(from: normalized)
            if !sections.isEmpty {
                return sections.map { section in
                    let kind = inferKind(from: relativePath, valueHint: section.title)
                    return makeDraft(
                        provider: provider,
                        relativePath: relativePath,
                        title: section.title,
                        body: section.body,
                        kind: kind,
                        timestamp: Date(),
                        nativeSummary: nil,
                        metadata: [:],
                        rawPayload: nil
                    )
                }
            }
        }

        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { MemoryTextNormalizer.normalizedBody($0) }
            .filter { !$0.isEmpty }

        if !paragraphs.isEmpty && paragraphs.count <= 32 {
            return paragraphs.map { paragraph in
                let title = MemoryTextNormalizer.normalizedTitle(String(paragraph.prefix(72)))
                let kind = inferKind(from: relativePath, valueHint: title)
                return makeDraft(
                    provider: provider,
                    relativePath: relativePath,
                    title: title,
                    body: paragraph,
                    kind: kind,
                    timestamp: Date(),
                    nativeSummary: nil,
                    metadata: [:],
                    rawPayload: nil
                )
            }
        }

        let title = MemoryTextNormalizer.normalizedTitle(fileStem(from: relativePath))
        let kind = inferKind(from: relativePath, valueHint: title)
        return [makeDraft(
            provider: provider,
            relativePath: relativePath,
            title: title,
            body: normalized,
            kind: kind,
            timestamp: Date(),
            nativeSummary: nil,
            metadata: [:],
            rawPayload: nil
        )]
    }

    private static func makeDraft(
        provider: MemoryProviderKind,
        relativePath: String,
        title: String,
        body: String,
        kind: MemoryEventKind,
        timestamp: Date,
        nativeSummary: String?,
        metadata: [String: String],
        rawPayload: String?
    ) -> MemoryEventDraft {
        let normalizedTitle = MemoryTextNormalizer.normalizedTitle(title)
        let normalizedBody = MemoryTextNormalizer.normalizedBody(body)
        let allKeywords = MemoryTextNormalizer.normalizedKeywords(
            MemoryTextNormalizer.keywords(from: normalizedTitle + " " + normalizedBody, limit: 20)
        )

        let summary = nativeSummary.map { MemoryTextNormalizer.normalizedSummary($0) }
        let inferredPlan = MemoryTextNormalizer.inferPlanContent(path: relativePath, kind: kind, body: normalizedBody)

        return MemoryEventDraft(
            kind: kind,
            title: normalizedTitle,
            body: normalizedBody,
            timestamp: timestamp,
            nativeSummary: summary,
            keywords: allKeywords,
            isPlanContent: inferredPlan,
            metadata: metadata,
            rawPayload: rawPayload
        )
    }

    private static func readString(from dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else { continue }

            if let stringValue = value as? String {
                let normalized = MemoryTextNormalizer.normalizedBody(stringValue)
                if !normalized.isEmpty {
                    return normalized
                }
            }
            if let numberValue = value as? NSNumber {
                return numberValue.stringValue
            }
        }
        return nil
    }

    private static func readDate(from dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = dictionary[key] else { continue }

            if let timestamp = value as? TimeInterval {
                return parseTimestamp(timestamp)
            }

            if let intValue = value as? Int {
                return parseTimestamp(TimeInterval(intValue))
            }

            if let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let numeric = TimeInterval(trimmed) {
                    return parseTimestamp(numeric)
                }
                if let parsed = fractionalISO8601Parser.date(from: trimmed)
                    ?? plainISO8601Parser.date(from: trimmed) {
                    return parsed
                }
                let fallbackFormats = [
                    "yyyy-MM-dd HH:mm:ss",
                    "yyyy-MM-dd'T'HH:mm:ss",
                    "yyyy-MM-dd"
                ]
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                for format in fallbackFormats {
                    formatter.dateFormat = format
                    if let parsed = formatter.date(from: trimmed) {
                        return parsed
                    }
                }
            }
        }
        return nil
    }

    private static func parseTimestamp(_ timestamp: TimeInterval) -> Date {
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: timestamp / 1_000)
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func inferKind(from relativePath: String, valueHint: String?) -> MemoryEventKind {
        let path = relativePath.lowercased()
        let hint = (valueHint ?? "").lowercased()
        let joined = path + " " + hint

        if joined.contains("rewrite") || joined.contains("rephrase") {
            return .rewrite
        }
        if joined.contains("summary") {
            return .summary
        }
        if joined.contains("plan") || joined.contains("roadmap") || joined.contains("todo") || joined.contains("backlog") {
            return .plan
        }
        if joined.contains("command") || joined.contains("shell") || joined.contains("terminal") {
            return .command
        }
        if joined.contains("edit") || joined.contains("patch") || joined.contains("diff") {
            return .fileEdit
        }
        if joined.contains("chat") || joined.contains("conversation") || joined.contains("message") {
            return .conversation
        }
        if joined.contains("note") || joined.contains("memo") {
            return .note
        }
        return .unknown
    }

    private static func flattenMetadata(from dictionary: [String: Any]) -> [String: String] {
        var flattened: [String: String] = [:]
        flattened.reserveCapacity(min(dictionary.count, 16))

        for (key, value) in dictionary {
            switch value {
            case let string as String:
                let normalized = MemoryTextNormalizer.normalizedBody(string)
                if !normalized.isEmpty && normalized.count <= 400 {
                    flattened[key] = normalized
                }
            case let number as NSNumber:
                flattened[key] = number.stringValue
            case let bool as Bool:
                flattened[key] = bool ? "true" : "false"
            default:
                continue
            }
        }
        return flattened
    }

    private static func serializeJSON(dictionary: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private static func fileStem(from relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
    }

    private static func markdownSections(from text: String) -> [(title: String, body: String)] {
        var sections: [(title: String, body: String)] = []
        var currentTitle = "Section"
        var currentBodyLines: [String] = []

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                if !currentBodyLines.joined().isEmpty {
                    let body = MemoryTextNormalizer.normalizedBody(currentBodyLines.joined(separator: "\n"))
                    if !body.isEmpty {
                        sections.append((currentTitle, body))
                    }
                }
                currentTitle = MemoryTextNormalizer.normalizedTitle(
                    trimmed.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces),
                    fallback: "Section"
                )
                currentBodyLines = []
            } else {
                currentBodyLines.append(line)
            }
        }

        let trailingBody = MemoryTextNormalizer.normalizedBody(currentBodyLines.joined(separator: "\n"))
        if !trailingBody.isEmpty {
            sections.append((currentTitle, trailingBody))
        }
        return sections
    }
}

private struct GenericMemorySourceAdapter: MemorySourceAdapter {
    let provider: MemoryProviderKind
    let maxFileSizeBytes: Int64
    let allowedFileExtensions: Set<String>

    init(
        provider: MemoryProviderKind,
        maxFileSizeBytes: Int64 = 2_500_000,
        allowedFileExtensions: Set<String> = ["json", "jsonl", "ndjson", "md", "markdown", "txt", "log", "yaml", "yml"]
    ) {
        self.provider = provider
        self.maxFileSizeBytes = maxFileSizeBytes
        self.allowedFileExtensions = allowedFileExtensions
    }

    func discoverFiles(
        in rootURL: URL,
        fileManager: FileManager,
        maxFiles: Int
    ) -> [URL] {
        MemoryAdapterFileDiscovery.discoverFiles(
            in: rootURL,
            fileManager: fileManager,
            allowedFileExtensions: allowedFileExtensions,
            maxFileSizeBytes: maxFileSizeBytes,
            maxFiles: maxFiles
        )
    }

    func parse(
        fileURL: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> [MemoryEventDraft] {
        try MemoryAdapterEventParser.parseFile(
            provider: provider,
            fileURL: fileURL,
            relativePath: relativePath,
            fileManager: fileManager
        )
    }
}

struct CodexMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .codex)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct OpenCodeMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .opencode)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct ClaudeMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .claude)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct CopilotMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .copilot)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct CursorMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .cursor)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct KimiMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .kimi)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct GeminiMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .gemini)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct WindsurfMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .windsurf)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}

struct CodeiumMemorySourceAdapter: MemorySourceAdapter {
    private let base = GenericMemorySourceAdapter(provider: .codeium)
    var provider: MemoryProviderKind { base.provider }
    var maxFileSizeBytes: Int64 { base.maxFileSizeBytes }
    var allowedFileExtensions: Set<String> { base.allowedFileExtensions }
    func discoverFiles(in rootURL: URL, fileManager: FileManager, maxFiles: Int) -> [URL] {
        base.discoverFiles(in: rootURL, fileManager: fileManager, maxFiles: maxFiles)
    }
    func parse(fileURL: URL, relativePath: String, fileManager: FileManager) throws -> [MemoryEventDraft] {
        try base.parse(fileURL: fileURL, relativePath: relativePath, fileManager: fileManager)
    }
}
