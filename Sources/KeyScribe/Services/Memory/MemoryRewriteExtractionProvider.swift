import Foundation

protocol MemoryRewriteExtractionProviding {
    func summary(
        for draft: MemoryEventDraft,
        provider: MemoryProviderKind
    ) async -> String?

    func rewriteSuggestion(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> RewriteSuggestion?
}

final class StubMemoryRewriteExtractionProvider: MemoryRewriteExtractionProviding {
    static let shared = StubMemoryRewriteExtractionProvider()

    func summary(
        for draft: MemoryEventDraft,
        provider: MemoryProviderKind
    ) async -> String? {
        if let nativeSummary = draft.nativeSummary {
            let normalized = MemoryTextNormalizer.normalizedSummary(nativeSummary)
            if !normalized.isEmpty {
                return normalized
            }
        }

        let body = MemoryTextNormalizer.normalizedBody(draft.body)
        guard !body.isEmpty else { return nil }

        if let sentence = firstSentence(in: body), !sentence.isEmpty {
            return MemoryTextNormalizer.normalizedSummary(sentence)
        }
        return MemoryTextNormalizer.normalizedSummary(body)
    }

    func rewriteSuggestion(
        for draft: MemoryEventDraft,
        card: MemoryCard,
        provider: MemoryProviderKind
    ) async -> RewriteSuggestion? {
        guard !draft.isPlanContent else { return nil }

        let extraction = extractRewritePayload(from: draft)
        guard let extraction else { return nil }
        guard extraction.original != extraction.suggested else { return nil }

        return RewriteSuggestion(
            id: MemoryIdentifier.stableUUID(
                for: "\(card.id.uuidString)|rewrite|\(extraction.original)|\(extraction.suggested)"
            ),
            cardID: card.id,
            provider: provider,
            originalText: extraction.original,
            suggestedText: extraction.suggested,
            rationale: extraction.rationale,
            confidence: extraction.confidence,
            createdAt: Date()
        )
    }

    private func extractRewritePayload(from draft: MemoryEventDraft) -> (original: String, suggested: String, rationale: String, confidence: Double)? {
        let metadata = draft.metadata
        let original = firstNonEmpty(
            metadata["original_text"],
            metadata["original"],
            metadata["input"],
            metadata["prompt"],
            metadata["source"]
        )
        let suggested = firstNonEmpty(
            metadata["suggested_text"],
            metadata["suggested"],
            metadata["rewrite"],
            metadata["response"],
            metadata["completion"],
            metadata["output"]
        )

        if let original, let suggested {
            return (
                original: MemoryTextNormalizer.normalizedBody(original),
                suggested: MemoryTextNormalizer.normalizedBody(suggested),
                rationale: "\(draft.title) (\(draft.kind.rawValue))",
                confidence: draft.kind == .rewrite ? 0.88 : 0.74
            )
        }

        let body = MemoryTextNormalizer.normalizedBody(draft.body)
        if let arrowSplit = splitArrowRewrite(body) {
            return (
                original: arrowSplit.original,
                suggested: arrowSplit.suggested,
                rationale: "\(draft.title) (parsed rewrite pair)",
                confidence: draft.kind == .rewrite ? 0.82 : 0.66
            )
        }

        if draft.kind == .rewrite {
            let normalized = MemoryTextNormalizer.normalizedBody(draft.body)
            let trimmedTitle = MemoryTextNormalizer.normalizedTitle(draft.title, fallback: "Rewrite")
            let suggested = firstSentence(in: normalized) ?? normalized
            return (
                original: trimmedTitle,
                suggested: suggested,
                rationale: "Generated from rewrite event fallback",
                confidence: 0.55
            )
        }

        return nil
    }

    private func splitArrowRewrite(_ body: String) -> (original: String, suggested: String)? {
        let markers = ["->", "=>", "→"]
        for marker in markers {
            let parts = body.components(separatedBy: marker)
            guard parts.count == 2 else { continue }
            let lhs = MemoryTextNormalizer.normalizedBody(parts[0])
            let rhs = MemoryTextNormalizer.normalizedBody(parts[1])
            guard !lhs.isEmpty, !rhs.isEmpty else { continue }
            return (lhs, rhs)
        }
        return nil
    }

    private func firstSentence(in text: String) -> String? {
        let separators: Set<Character> = [".", "!", "?", "\n"]
        var sentence = ""
        for character in text {
            sentence.append(character)
            if separators.contains(character) {
                break
            }
        }
        let trimmed = MemoryTextNormalizer.normalizedBody(sentence)
        if trimmed.isEmpty {
            return nil
        }
        return trimmed
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let normalized = MemoryTextNormalizer.normalizedBody(value)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }
}
