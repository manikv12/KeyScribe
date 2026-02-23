import CryptoKit
import Foundation

enum MemoryProviderKind: String, CaseIterable, Codable, Hashable {
    case codex
    case opencode
    case claude
    case copilot
    case cursor
    case kimi
    case gemini
    case windsurf
    case codeium
    case unknown

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .opencode:
            return "OpenCode"
        case .claude:
            return "Claude"
        case .copilot:
            return "Copilot"
        case .cursor:
            return "Cursor"
        case .kimi:
            return "Kimi"
        case .gemini:
            return "Gemini"
        case .windsurf:
            return "Windsurf"
        case .codeium:
            return "Codeium"
        case .unknown:
            return "Unknown"
        }
    }
}

enum MemoryEventKind: String, Codable, Hashable {
    case conversation
    case rewrite
    case summary
    case command
    case fileEdit
    case note
    case plan
    case unknown
}

struct MemorySource: Codable, Hashable, Identifiable {
    let id: UUID
    let provider: MemoryProviderKind
    let rootPath: String
    let displayName: String
    var discoveredAt: Date
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        provider: MemoryProviderKind,
        rootPath: String,
        displayName: String? = nil,
        discoveredAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.rootPath = rootPath
        self.displayName = displayName ?? provider.displayName
        self.discoveredAt = discoveredAt
        self.metadata = metadata
    }
}

struct MemorySourceFile: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let absolutePath: String
    let relativePath: String
    var fileHash: String
    var fileSizeBytes: Int64
    var modifiedAt: Date
    var indexedAt: Date
    var parseError: String?
}

struct MemoryEventDraft: Codable, Hashable {
    var kind: MemoryEventKind
    var title: String
    var body: String
    var timestamp: Date
    var nativeSummary: String?
    var keywords: [String]
    var isPlanContent: Bool
    var metadata: [String: String]
    var rawPayload: String?

    init(
        kind: MemoryEventKind,
        title: String,
        body: String,
        timestamp: Date = Date(),
        nativeSummary: String? = nil,
        keywords: [String] = [],
        isPlanContent: Bool = false,
        metadata: [String: String] = [:],
        rawPayload: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.timestamp = timestamp
        self.nativeSummary = nativeSummary
        self.keywords = keywords
        self.isPlanContent = isPlanContent
        self.metadata = metadata
        self.rawPayload = rawPayload
    }
}

struct MemoryEvent: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let sourceFileID: UUID
    let provider: MemoryProviderKind
    let kind: MemoryEventKind
    var title: String
    var body: String
    var timestamp: Date
    var nativeSummary: String?
    var keywords: [String]
    var isPlanContent: Bool
    var metadata: [String: String]
    var rawPayload: String?
}

struct MemoryCard: Codable, Hashable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let sourceFileID: UUID
    let eventID: UUID
    let provider: MemoryProviderKind
    var title: String
    var summary: String
    var detail: String
    var keywords: [String]
    var score: Double
    var createdAt: Date
    var updatedAt: Date
    var isPlanContent: Bool
    var metadata: [String: String]
}

struct RewriteSuggestion: Codable, Hashable, Identifiable {
    let id: UUID
    let cardID: UUID
    let provider: MemoryProviderKind
    let originalText: String
    let suggestedText: String
    let rationale: String
    let confidence: Double
    let createdAt: Date
}

struct MemoryRewriteLookupOptions: Hashable {
    var provider: MemoryProviderKind?
    var includePlanContent: Bool
    var limit: Int

    init(provider: MemoryProviderKind? = nil, includePlanContent: Bool = false, limit: Int = 20) {
        self.provider = provider
        self.includePlanContent = includePlanContent
        self.limit = max(1, min(limit, 200))
    }
}

enum MemoryTextNormalizer {
    private static let tokenRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9]+(?:[._'/-][A-Za-z0-9]+)*",
        options: []
    )

    static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizedTitle(_ value: String, fallback: String = "Untitled Memory") -> String {
        let trimmed = collapsedWhitespace(value)
        if trimmed.isEmpty {
            return fallback
        }
        if trimmed.count <= 120 {
            return trimmed
        }
        return String(trimmed.prefix(117)) + "..."
    }

    static func normalizedBody(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return trimmed
        }
        return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func normalizedSummary(_ value: String, limit: Int = 240) -> String {
        let clean = collapsedWhitespace(value)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(max(0, limit - 3))) + "..."
    }

    static func normalizedKeywords(_ values: [String], limit: Int = 16) -> [String] {
        guard !values.isEmpty else { return [] }
        var seen = Set<String>()
        var keywords: [String] = []
        keywords.reserveCapacity(min(limit, values.count))

        for raw in values {
            let token = collapsedWhitespace(raw).lowercased()
            guard token.count >= 2 else { continue }
            guard seen.insert(token).inserted else { continue }
            keywords.append(token)
            if keywords.count >= limit {
                break
            }
        }

        return keywords
    }

    static func keywords(from text: String, limit: Int = 16) -> [String] {
        guard limit > 0 else { return [] }
        guard let tokenRegex else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = tokenRegex.matches(in: text, options: [], range: range)

        var seen = Set<String>()
        var tokens: [String] = []
        tokens.reserveCapacity(min(limit, matches.count))

        for match in matches {
            guard let tokenRange = Range(match.range, in: text) else { continue }
            let token = text[tokenRange].lowercased()
            guard token.count >= 2 else { continue }
            guard seen.insert(token).inserted else { continue }
            tokens.append(token)
            if tokens.count == limit {
                break
            }
        }
        return tokens
    }

    static func inferPlanContent(path: String, kind: MemoryEventKind, body: String) -> Bool {
        if kind == .plan {
            return true
        }

        let normalizedPath = path.lowercased()
        if normalizedPath.contains("/plan") || normalizedPath.contains("roadmap") || normalizedPath.contains("todo") {
            return true
        }

        let text = body.lowercased()
        return text.contains("acceptance criteria:")
            || text.contains("implementation plan:")
            || text.contains("milestone")
            || text.contains("backlog")
    }
}

enum MemoryIdentifier {
    static func stableUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        let bytes = Array(digest.prefix(16))
        let uuidBytes: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidBytes)
    }

    static func stableHexDigest(for value: String) -> String {
        stableHexDigest(data: Data(value.utf8))
    }

    static func stableHexDigest(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
