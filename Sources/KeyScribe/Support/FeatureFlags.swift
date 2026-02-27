import Foundation

enum FeatureFlags {
    private static let aiMemoryEnvironmentKey = "KEYSCRIBE_FEATURE_AI_MEMORY"
    private static let conversationLongTermMemoryEnvironmentKey = "KEYSCRIBE_FEATURE_CONVERSATION_LONG_TERM_MEMORY"
    private static let conversationAutoPromotionEnvironmentKey = "KEYSCRIBE_FEATURE_CONVERSATION_AUTO_PROMOTION"
    private static let strictProjectIsolationEnvironmentKey = "KEYSCRIBE_FEATURE_STRICT_PROJECT_ISOLATION"
    private static let conversationTupleSQLiteEnvironmentKey = "KEYSCRIBE_FEATURE_CONVERSATION_TUPLE_SQLITE"
    private static let crossIDEConversationSharingEnvironmentKey = "KEYSCRIBE_FEATURE_CROSS_IDE_CONVERSATION_SHARING"

    static var aiMemoryEnabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment[aiMemoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(raw)
    }

    static var conversationLongTermMemoryEnabled: Bool {
        boolFlag(
            environmentKey: conversationLongTermMemoryEnvironmentKey,
            defaultValue: true
        )
    }

    static var conversationAutoPromotionEnabled: Bool {
        boolFlag(
            environmentKey: conversationAutoPromotionEnvironmentKey,
            defaultValue: true
        )
    }

    static var strictProjectIsolationEnabled: Bool {
        boolFlag(
            environmentKey: strictProjectIsolationEnvironmentKey,
            defaultValue: true
        )
    }

    static var conversationTupleSQLiteEnabled: Bool {
        boolFlag(
            environmentKey: conversationTupleSQLiteEnvironmentKey,
            defaultValue: true
        )
    }

    static var crossIDEConversationSharingEnabled: Bool {
        boolFlag(
            environmentKey: crossIDEConversationSharingEnvironmentKey,
            defaultValue: false
        )
    }

    private static func boolFlag(environmentKey: String, defaultValue: Bool) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else {
            return defaultValue
        }
        if ["1", "true", "yes", "on"].contains(raw) {
            return true
        }
        if ["0", "false", "no", "off"].contains(raw) {
            return false
        }
        return defaultValue
    }
}
