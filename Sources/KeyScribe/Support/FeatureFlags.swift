import Foundation

enum FeatureFlags {
    private static let aiMemoryEnvironmentKey = "KEYSCRIBE_FEATURE_AI_MEMORY"

    static var aiMemoryEnabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment[aiMemoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(raw)
    }
}
