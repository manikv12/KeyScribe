import Foundation

enum RecognitionTuning {
    static func clampedFinalizeDelay(_ value: TimeInterval) -> TimeInterval {
        min(1.2, max(0.15, value))
    }

    static func parseCustomPhrases(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func scoreTranscript(_ text: String) -> Int {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return words * 100 + text.count
    }

    static func chooseBetterTranscript(primary: String, fallback: String) -> String {
        let a = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return scoreTranscript(a) >= scoreTranscript(b) ? a : b
    }

    static func contextualHints(defaults: [String], custom: [String], limit: Int = 80) -> [String] {
        Array(Set(defaults + custom)).prefix(limit).map { $0 }
    }
}
