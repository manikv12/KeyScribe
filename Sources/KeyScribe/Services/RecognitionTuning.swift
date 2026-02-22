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
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var ordered: [String] = []

        for phrase in defaults + custom {
            let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                ordered.append(normalized)
                if ordered.count == limit {
                    break
                }
            }
        }

        return ordered
    }
}
