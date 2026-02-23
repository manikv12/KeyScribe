import Foundation

actor MemoryRewriteRetrievalService {
    static let shared = MemoryRewriteRetrievalService()

    private var store: MemorySQLiteStore?

    func retrieveSuggestion(for cleanedTranscript: String) throws -> PromptRewriteSuggestion? {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(cleanedTranscript)
        guard !normalized.isEmpty else { return nil }

        let store = try resolvedStore()
        let suggestions = try store.fetchRewriteSuggestions(
            query: normalized,
            provider: nil,
            limit: 1
        )
        guard let first = suggestions.first else { return nil }

        let suggestedText = first.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestedText.isEmpty else { return nil }

        let memoryContext = "\(first.provider.displayName) memory (\(String(format: "%.2f", first.confidence))): \(first.rationale)"
        return PromptRewriteSuggestion(
            suggestedText: suggestedText,
            memoryContext: memoryContext
        )
    }

    private func resolvedStore() throws -> MemorySQLiteStore {
        if let store {
            return store
        }
        let created = try MemorySQLiteStore()
        store = created
        return created
    }
}
