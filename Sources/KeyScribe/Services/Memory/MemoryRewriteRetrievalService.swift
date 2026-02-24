import Foundation

actor MemoryRewriteRetrievalService {
    static let shared = MemoryRewriteRetrievalService()
    private let minimumWordsForRewrite = 3
    private let rewriteSuggestionFetchLimit = 200

    private var store: MemorySQLiteStore?

    func retrieveSuggestion(for cleanedTranscript: String) throws -> PromptRewriteSuggestion? {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(cleanedTranscript)
        guard !normalized.isEmpty else { return nil }
        guard shouldAttemptRewrite(for: normalized) else { return nil }

        let store = try resolvedStore()

        let directStoredLessons = try prioritizedStoredLessons(
            from: store.fetchLessonsForRewrite(
                query: normalized,
                provider: nil,
                limit: 24
            ),
            transcript: normalized,
            limit: 1,
            includeLowRelevance: false
        )
        guard let directLesson = directStoredLessons.first else { return nil }
        return PromptRewriteSuggestion(
            suggestedText: directLesson.correctionText,
            memoryContext: lessonContextLine(for: directLesson, includeRationale: true)
        )
    }

    func fetchPromptRewriteContext(
        for cleanedTranscript: String,
        lessonLimit: Int = 8,
        cardLimit: Int = 10
    ) throws -> MemoryRewritePromptContext {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(cleanedTranscript)
        let store = try resolvedStore()
        let lessons = try fetchLessons(
            for: normalized,
            store: store,
            limit: max(1, min(lessonLimit, 16))
        )
        let cards = try fetchSupportingCards(
            for: normalized,
            store: store,
            lessons: lessons,
            limit: max(1, min(cardLimit, 24))
        )
        return MemoryRewritePromptContext(
            lessons: lessons,
            supportingCards: cards
        )
    }

    func fetchCandidateCards(
        for cleanedTranscript: String,
        limit: Int = 12
    ) throws -> [MemoryCard] {
        let normalizedLimit = max(1, min(limit, 24))
        let context = try fetchPromptRewriteContext(
            for: cleanedTranscript,
            lessonLimit: min(8, normalizedLimit),
            cardLimit: normalizedLimit
        )

        var output = context.lessons
            .prefix(normalizedLimit)
            .map(synthesizedLessonCard(from:))
        if output.count < normalizedLimit {
            output.append(contentsOf: context.supportingCards.prefix(normalizedLimit - output.count))
        }

        return output
    }

    func persistFeedbackRewrite(
        originalText: String,
        rewrittenText: String,
        rationale: String,
        confidence: Double,
        timestamp: Date = Date()
    ) throws {
        let normalizedOriginal = MemoryTextNormalizer.collapsedWhitespace(originalText)
        let normalizedRewritten = MemoryTextNormalizer.collapsedWhitespace(rewrittenText)
        guard !normalizedOriginal.isEmpty, !normalizedRewritten.isEmpty else { return }
        guard normalizedOriginal.caseInsensitiveCompare(normalizedRewritten) != .orderedSame else { return }

        let store = try resolvedStore()
        try store.upsertFeedbackRewriteMemory(
            originalText: normalizedOriginal,
            rewrittenText: normalizedRewritten,
            rationale: rationale,
            confidence: confidence,
            timestamp: timestamp
        )
    }

    func invalidateLessonPair(
        originalText: String,
        suggestedText: String,
        reason: String,
        timestamp: Date = Date()
    ) throws {
        let normalizedOriginal = MemoryTextNormalizer.collapsedWhitespace(originalText)
        let normalizedSuggested = MemoryTextNormalizer.collapsedWhitespace(suggestedText)
        guard !normalizedOriginal.isEmpty, !normalizedSuggested.isEmpty else { return }
        guard normalizedOriginal.caseInsensitiveCompare(normalizedSuggested) != .orderedSame else { return }

        let store = try resolvedStore()
        let candidateLessons = try store.fetchLessonsForRewrite(
            query: normalizedOriginal,
            provider: nil,
            limit: rewriteSuggestionFetchLimit
        )

        for lesson in candidateLessons {
            guard let pair = normalizedPair(for: lesson) else { continue }
            guard pair.original.caseInsensitiveCompare(normalizedOriginal) == .orderedSame else { continue }
            guard pair.correction.caseInsensitiveCompare(normalizedSuggested) == .orderedSame else { continue }

            var updated = lesson
            updated.validationConfidence = min(updated.validationConfidence, 0.05)
            updated.updatedAt = timestamp

            var metadata = updated.sourceMetadata
            metadata["validation_state"] = MemoryRewriteLessonValidationState.invalidated.rawValue
            metadata["invalidated_at"] = iso8601Timestamp(timestamp)
            metadata["invalidation_reason"] = MemoryTextNormalizer.normalizedSummary(reason, limit: 240)
            updated.sourceMetadata = metadata

            try store.upsertLesson(updated)
        }
    }

    private func resolvedStore() throws -> MemorySQLiteStore {
        if let store {
            return store
        }
        let created = try MemorySQLiteStore()
        store = created
        return created
    }

    private func fetchLessons(
        for normalizedTranscript: String,
        store: MemorySQLiteStore,
        limit: Int
    ) throws -> [MemoryRewriteLesson] {
        let matchedStoredLessons = try store.fetchLessonsForRewrite(
            query: normalizedTranscript,
            provider: nil,
            limit: 80
        )
        let globalStoredLessons = try store.fetchLessonsForRewrite(
            query: "",
            provider: nil,
            limit: rewriteSuggestionFetchLimit
        )

        let prioritized = prioritizedStoredLessons(
            from: matchedStoredLessons + globalStoredLessons,
            transcript: normalizedTranscript,
            limit: limit,
            includeLowRelevance: true
        )
        return prioritized
    }

    private func fetchSupportingCards(
        for normalizedTranscript: String,
        store: MemorySQLiteStore,
        lessons: [MemoryRewriteLesson],
        limit: Int
    ) throws -> [MemoryCard] {
        let queries = cardSearchQueries(for: normalizedTranscript)
        var candidates: [MemoryCard] = []
        for query in queries {
            let cards = try store.fetchCardsForRewrite(
                query: query,
                options: MemoryRewriteLookupOptions(
                    provider: nil,
                    includePlanContent: false,
                    limit: max(20, limit * 4)
                )
            )
            candidates.append(contentsOf: cards)
        }

        var seen = Set<String>()
        var filtered: [MemoryCard] = []
        filtered.reserveCapacity(limit)

        for card in candidates {
            guard isHighSignalCard(card) else { continue }
            if !lessons.isEmpty && isWeakGenericCard(card) {
                continue
            }
            if lessons.contains(where: { lesson in cardLikelyRepresentsLesson(card, lesson: lesson) }) {
                continue
            }

            let dedupeKey = "\(card.title.lowercased())|\(card.summary.lowercased())|\(card.detail.prefix(120).lowercased())"
            if !seen.insert(dedupeKey).inserted {
                continue
            }
            filtered.append(card)
            if filtered.count >= limit {
                break
            }
        }

        return filtered
    }

    private func cardSearchQueries(for transcript: String) -> [String] {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(transcript)
        guard !normalized.isEmpty else { return [""] }

        var queries: [String] = [normalized]
        let keywords = MemoryTextNormalizer.keywords(from: normalized, limit: 8)
        if !keywords.isEmpty {
            queries.append(keywords.joined(separator: " "))
            queries.append(contentsOf: keywords)
        }

        var seen = Set<String>()
        var unique: [String] = []
        for value in queries {
            let collapsed = MemoryTextNormalizer.collapsedWhitespace(value)
            guard !collapsed.isEmpty else { continue }
            if seen.insert(collapsed).inserted {
                unique.append(collapsed)
            }
        }
        return unique.isEmpty ? [normalized] : unique
    }

    private func shouldAttemptRewrite(for transcript: String) -> Bool {
        let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
        if wordCount >= minimumWordsForRewrite {
            return true
        }
        return transcript.contains { character in
            character == "." || character == "!" || character == "?"
        }
    }

    private func applySentenceLevelRewrites(
        to transcript: String,
        suggestions: [RewriteSuggestion]
    ) -> (rewrittenText: String, appliedSuggestions: [RewriteSuggestion], didChange: Bool) {
        let normalizedSuggestions = suggestions.compactMap { suggestion -> RewriteSuggestion? in
            guard normalizedPair(for: suggestion) != nil else { return nil }
            if validationState(for: suggestion) == .invalidated {
                return nil
            }
            return suggestion
        }
        guard !normalizedSuggestions.isEmpty else {
            return (transcript, [], false)
        }

        let orderedSuggestions = normalizedSuggestions.sorted { lhs, rhs in
            let lhsValidation = validationPriority(for: lhs)
            let rhsValidation = validationPriority(for: rhs)
            if lhsValidation != rhsValidation {
                return lhsValidation > rhsValidation
            }
            if lhs.originalText.count == rhs.originalText.count {
                return lhs.confidence > rhs.confidence
            }
            return lhs.originalText.count > rhs.originalText.count
        }

        let segments = sentenceSegments(from: transcript)
        var rewrittenSegments: [String] = []
        rewrittenSegments.reserveCapacity(segments.count)

        var appliedSuggestionByKey: [UUID: RewriteSuggestion] = [:]
        var didChange = false

        for segment in segments {
            var rewrittenSegment = segment
            for suggestion in orderedSuggestions {
                let replacementResult = replace(
                    suggestion: suggestion,
                    in: rewrittenSegment
                )
                if replacementResult.didReplace {
                    rewrittenSegment = replacementResult.updatedText
                    appliedSuggestionByKey[suggestion.id] = suggestion
                    didChange = true
                }
            }
            rewrittenSegments.append(rewrittenSegment)
        }

        let rewrittenText = rewrittenSegments.joined()
        let appliedSuggestions = appliedSuggestionByKey
            .values
            .sorted { lhs, rhs in
                let lhsValidation = validationPriority(for: lhs)
                let rhsValidation = validationPriority(for: rhs)
                if lhsValidation != rhsValidation {
                    return lhsValidation > rhsValidation
                }
                if lhs.confidence == rhs.confidence {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.confidence > rhs.confidence
            }

        return (rewrittenText, appliedSuggestions, didChange && rewrittenText != transcript)
    }

    private func sentenceSegments(from text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        current.reserveCapacity(text.count)

        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                segments.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        if !current.isEmpty {
            segments.append(current)
        }

        if segments.isEmpty {
            return [text]
        }
        return segments
    }

    private func replace(
        suggestion: RewriteSuggestion,
        in segment: String
    ) -> (updatedText: String, didReplace: Bool) {
        let original = suggestion.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = suggestion.suggestedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !replacement.isEmpty else {
            return (segment, false)
        }

        let updated: String
        if original.contains(where: \.isWhitespace) {
            updated = segment.replacingOccurrences(
                of: original,
                with: replacement,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil
            )
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: original)
            let pattern = "(?i)\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return (segment, false)
            }
            let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
            updated = regex.stringByReplacingMatches(
                in: segment,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }

        return (updated, updated != segment)
    }

    private func memoryContext(for appliedSuggestions: [RewriteSuggestion]) -> String {
        guard !appliedSuggestions.isEmpty else { return "" }

        let lessons = appliedSuggestions.compactMap { suggestion -> MemoryRewriteLesson? in
            guard let pair = normalizedPair(for: suggestion) else { return nil }
            return makeLesson(from: suggestion, pair: pair)
        }
        guard !lessons.isEmpty else { return "" }

        let validatedCount = lessons.filter { $0.validationState.isValidated }.count
        let preview = lessons
            .prefix(3)
            .map { lesson in
                "[\(lesson.validationState.displayName)] \(snippet(lesson.mistakeText, limit: 32)) -> \(snippet(lesson.correctionText, limit: 40)) (\(lesson.provenance))"
            }
            .joined(separator: "; ")
        return "Applied \(lessons.count) memory lesson(s), \(validatedCount) validated: \(preview)"
    }

    private func prioritizedStoredLessons(
        from storedLessons: [MemoryLesson],
        transcript: String,
        limit: Int,
        includeLowRelevance: Bool
    ) -> [MemoryRewriteLesson] {
        guard !storedLessons.isEmpty else { return [] }

        let normalizedTranscript = MemoryTextNormalizer.collapsedWhitespace(transcript).lowercased()
        var bestByPair: [String: (lesson: MemoryRewriteLesson, relevance: Int)] = [:]

        for storedLesson in storedLessons {
            guard isEligibleStoredLesson(storedLesson) else { continue }
            guard let pair = normalizedPair(for: storedLesson) else { continue }
            let lesson = makeLesson(from: storedLesson, pair: pair)
            if lesson.validationState == .invalidated {
                continue
            }
            let relevance = relevanceScore(
                originalText: pair.original,
                normalizedTranscript: normalizedTranscript
            )
            if !includeLowRelevance && relevance == 0 {
                continue
            }

            let dedupeKey = "\(pair.original.lowercased())|\(pair.correction.lowercased())"
            if let existing = bestByPair[dedupeKey] {
                if shouldReplace(existing: existing, with: lesson, relevance: relevance) {
                    bestByPair[dedupeKey] = (lesson, relevance)
                }
            } else {
                bestByPair[dedupeKey] = (lesson, relevance)
            }
        }

        return bestByPair
            .values
            .sorted { lhs, rhs in
                if lhs.relevance != rhs.relevance {
                    return lhs.relevance > rhs.relevance
                }
                let lhsValidation = validationPriority(for: lhs.lesson.validationState)
                let rhsValidation = validationPriority(for: rhs.lesson.validationState)
                if lhsValidation != rhsValidation {
                    return lhsValidation > rhsValidation
                }
                if lhs.lesson.confidence != rhs.lesson.confidence {
                    return lhs.lesson.confidence > rhs.lesson.confidence
                }
                return lhs.lesson.createdAt > rhs.lesson.createdAt
            }
            .prefix(limit)
            .map(\.lesson)
    }

    private func prioritizedLessons(
        from suggestions: [RewriteSuggestion],
        transcript: String,
        limit: Int,
        includeLowRelevance: Bool
    ) -> [MemoryRewriteLesson] {
        guard !suggestions.isEmpty else { return [] }

        let normalizedTranscript = MemoryTextNormalizer.collapsedWhitespace(transcript).lowercased()
        var bestByPair: [String: (lesson: MemoryRewriteLesson, relevance: Int)] = [:]

        for suggestion in suggestions {
            guard let pair = normalizedPair(for: suggestion) else { continue }
            let lesson = makeLesson(from: suggestion, pair: pair)
            if lesson.validationState == .invalidated {
                continue
            }
            let relevance = relevanceScore(
                originalText: pair.original,
                normalizedTranscript: normalizedTranscript
            )
            if !includeLowRelevance && relevance == 0 {
                continue
            }

            let dedupeKey = "\(pair.original.lowercased())|\(pair.correction.lowercased())"
            if let existing = bestByPair[dedupeKey] {
                if shouldReplace(existing: existing, with: lesson, relevance: relevance) {
                    bestByPair[dedupeKey] = (lesson, relevance)
                }
            } else {
                bestByPair[dedupeKey] = (lesson, relevance)
            }
        }

        return bestByPair
            .values
            .sorted { lhs, rhs in
                if lhs.relevance != rhs.relevance {
                    return lhs.relevance > rhs.relevance
                }
                let lhsValidation = validationPriority(for: lhs.lesson.validationState)
                let rhsValidation = validationPriority(for: rhs.lesson.validationState)
                if lhsValidation != rhsValidation {
                    return lhsValidation > rhsValidation
                }
                if lhs.lesson.confidence != rhs.lesson.confidence {
                    return lhs.lesson.confidence > rhs.lesson.confidence
                }
                return lhs.lesson.createdAt > rhs.lesson.createdAt
            }
            .prefix(limit)
            .map(\.lesson)
    }

    private func shouldReplace(
        existing: (lesson: MemoryRewriteLesson, relevance: Int),
        with replacement: MemoryRewriteLesson,
        relevance replacementRelevance: Int
    ) -> Bool {
        if replacementRelevance != existing.relevance {
            return replacementRelevance > existing.relevance
        }

        let replacementValidation = validationPriority(for: replacement.validationState)
        let existingValidation = validationPriority(for: existing.lesson.validationState)
        if replacementValidation != existingValidation {
            return replacementValidation > existingValidation
        }

        if replacement.confidence != existing.lesson.confidence {
            return replacement.confidence > existing.lesson.confidence
        }

        return replacement.createdAt > existing.lesson.createdAt
    }

    private func normalizedPair(for suggestion: RewriteSuggestion) -> (original: String, correction: String)? {
        let original = MemoryTextNormalizer.collapsedWhitespace(suggestion.originalText)
        let correction = MemoryTextNormalizer.collapsedWhitespace(suggestion.suggestedText)
        guard !original.isEmpty, !correction.isEmpty else { return nil }
        guard original.caseInsensitiveCompare(correction) != .orderedSame else { return nil }
        guard looksLikeRewriteLessonPair(original: original, correction: correction) else { return nil }
        return (original, correction)
    }

    private func normalizedPair(for lesson: MemoryLesson) -> (original: String, correction: String)? {
        let original = MemoryTextNormalizer.collapsedWhitespace(lesson.mistakePattern)
        let correction = MemoryTextNormalizer.collapsedWhitespace(lesson.improvedPrompt)
        guard !original.isEmpty, !correction.isEmpty else { return nil }
        guard original.caseInsensitiveCompare(correction) != .orderedSame else { return nil }
        guard looksLikeRewriteLessonPair(original: original, correction: correction) else { return nil }
        return (original, correction)
    }

    private func makeLesson(
        from suggestion: RewriteSuggestion,
        pair: (original: String, correction: String)
    ) -> MemoryRewriteLesson {
        let validation = validationState(for: suggestion)
        let normalizedRationale = stripMetadataTags(from: suggestion.rationale)
        return MemoryRewriteLesson(
            id: suggestion.id,
            provider: suggestion.provider,
            mistakeText: pair.original,
            correctionText: pair.correction,
            rationale: normalizedRationale,
            confidence: min(1.0, max(0.0, suggestion.confidence)),
            createdAt: suggestion.createdAt,
            provenance: provenance(for: suggestion, validationState: validation),
            validationState: validation
        )
    }

    private func makeLesson(
        from storedLesson: MemoryLesson,
        pair: (original: String, correction: String)
    ) -> MemoryRewriteLesson {
        let validation = validationState(for: storedLesson)
        return MemoryRewriteLesson(
            id: storedLesson.id,
            provider: storedLesson.provider,
            mistakeText: pair.original,
            correctionText: pair.correction,
            rationale: MemoryTextNormalizer.collapsedWhitespace(storedLesson.rationale),
            confidence: min(1.0, max(0.0, storedLesson.validationConfidence)),
            createdAt: storedLesson.updatedAt,
            provenance: provenance(for: storedLesson, validationState: validation),
            validationState: validation
        )
    }

    private func validationState(for suggestion: RewriteSuggestion) -> MemoryRewriteLessonValidationState {
        let rationale = suggestion.rationale.lowercased()
        if rationale.contains("[lesson:invalidated]") {
            return .invalidated
        }
        if rationale.contains("[lesson:user-confirmed]") {
            return .userConfirmed
        }
        if rationale.contains("[lesson:indexed-validated]") {
            return .indexedValidated
        }
        if rationale.contains("[lesson:unvalidated]") {
            return .unvalidated
        }
        if rationale.contains("user accepted")
            || rationale.contains("user edited")
            || rationale.contains("user confirmed")
            || rationale.contains("accepted suggested rewrite")
            || rationale.contains("prompt-rewrite-feedback")
            || (rationale.contains("user") && rationale.contains("rewrite")) {
            return .userConfirmed
        }
        if suggestion.confidence >= 0.86 {
            return .indexedValidated
        }
        return .unvalidated
    }

    private func validationState(for lesson: MemoryLesson) -> MemoryRewriteLessonValidationState {
        let metadata = lesson.sourceMetadata
        if let explicitState = metadata["validation_state"]?.lowercased() {
            let normalized = explicitState.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized == MemoryRewriteLessonValidationState.invalidated.rawValue || normalized.contains("invalidated") {
                return .invalidated
            }
            if normalized == MemoryRewriteLessonValidationState.userConfirmed.rawValue || normalized.contains("user") {
                return .userConfirmed
            }
            if normalized == MemoryRewriteLessonValidationState.unvalidated.rawValue || normalized.contains("unvalidated") {
                return .unvalidated
            }
            if normalized == MemoryRewriteLessonValidationState.indexedValidated.rawValue || normalized.contains("validated") {
                return .indexedValidated
            }
        }

        let origin = metadata["origin"]?.lowercased() ?? ""
        if origin.contains("prompt-rewrite-feedback") || origin.contains("user-feedback") {
            return .userConfirmed
        }

        if lesson.validationConfidence >= 0.80 {
            return .indexedValidated
        }
        if metadata["extraction_method"]?.lowercased() == "ai",
           lesson.validationConfidence >= 0.65 {
            return .indexedValidated
        }
        return .unvalidated
    }

    private func isEligibleStoredLesson(_ lesson: MemoryLesson) -> Bool {
        let metadata = lesson.sourceMetadata
        let extractionMethod = metadata["extraction_method"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let origin = metadata["origin"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let providerMode = metadata["provider_mode"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if extractionMethod == "ai" || extractionMethod == "user-feedback" {
            return true
        }
        if origin.contains("prompt-rewrite-feedback") || origin.contains("user-feedback") {
            return true
        }
        if !providerMode.isEmpty {
            return true
        }
        return false
    }

    private func provenance(
        for suggestion: RewriteSuggestion,
        validationState: MemoryRewriteLessonValidationState
    ) -> String {
        if let sourceTag = metadataTag(named: "source", from: suggestion.rationale) {
            return sourceTag
        }
        switch validationState {
        case .userConfirmed:
            return "KeyScribe user feedback"
        case .indexedValidated:
            if suggestion.provider == .unknown {
                return "Indexed rewrite pair"
            }
            return "\(suggestion.provider.displayName) indexed rewrite pair"
        case .unvalidated:
            if suggestion.provider == .unknown {
                return "Unvalidated indexed rewrite"
            }
            return "\(suggestion.provider.displayName) memory extraction"
        case .invalidated:
            return "Invalidated lesson"
        }
    }

    private func provenance(
        for lesson: MemoryLesson,
        validationState: MemoryRewriteLessonValidationState
    ) -> String {
        let metadata = lesson.sourceMetadata
        if let explicit = metadata["provenance"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        let extraction = metadata["extraction_method"]?.lowercased() ?? ""
        if validationState == .invalidated {
            return "Invalidated lesson"
        }
        if validationState == .userConfirmed {
            return "KeyScribe user feedback"
        }
        if extraction == "ai" {
            if lesson.provider == .unknown {
                return "AI synthesized lesson"
            }
            return "\(lesson.provider.displayName) AI synthesized lesson"
        }
        if extraction == "deterministic" {
            if lesson.provider == .unknown {
                return "Deterministic indexed lesson"
            }
            return "\(lesson.provider.displayName) deterministic lesson"
        }
        if lesson.provider == .unknown {
            return "Indexed lesson"
        }
        return "\(lesson.provider.displayName) indexed lesson"
    }

    private func relevanceScore(
        originalText: String,
        normalizedTranscript: String
    ) -> Int {
        guard !normalizedTranscript.isEmpty else { return 0 }
        let normalizedOriginal = MemoryTextNormalizer.collapsedWhitespace(originalText).lowercased()
        guard !normalizedOriginal.isEmpty else { return 0 }

        if normalizedTranscript.contains(normalizedOriginal) {
            return 3
        }

        let originalTokens = Set(MemoryTextNormalizer.keywords(from: normalizedOriginal, limit: 24))
        if originalTokens.isEmpty {
            return 0
        }
        let transcriptTokens = Set(MemoryTextNormalizer.keywords(from: normalizedTranscript, limit: 40))
        let overlapCount = originalTokens.intersection(transcriptTokens).count
        if overlapCount >= min(2, originalTokens.count) {
            return 2
        }
        if overlapCount > 0 {
            return 1
        }
        return 0
    }

    private func validationPriority(for suggestion: RewriteSuggestion) -> Int {
        validationPriority(for: validationState(for: suggestion))
    }

    private func validationPriority(for state: MemoryRewriteLessonValidationState) -> Int {
        switch state {
        case .userConfirmed:
            return 3
        case .indexedValidated:
            return 2
        case .unvalidated:
            return 1
        case .invalidated:
            return 0
        }
    }

    private func looksLikeRewriteLessonPair(
        original: String,
        correction: String
    ) -> Bool {
        if original.count > 220 || correction.count > 220 {
            return false
        }
        if original.count < 2 || correction.count < 2 {
            return false
        }
        let combined = "\(original) \(correction)".lowercased()
        if combined.contains("{") && combined.contains("}") {
            return false
        }
        return true
    }

    private func rewriteSuggestion(from lesson: MemoryLesson) -> RewriteSuggestion? {
        guard let pair = normalizedPair(for: lesson) else { return nil }
        let state = validationState(for: lesson)
        if state == .invalidated {
            return nil
        }
        let provenance = provenance(for: lesson, validationState: state)
        let metadataPrefix = "[lesson:\(state.rawValue)] [source:\(provenance)]"
        let rationale = "\(metadataPrefix) \(MemoryTextNormalizer.collapsedWhitespace(lesson.rationale))"

        return RewriteSuggestion(
            id: MemoryIdentifier.stableUUID(
                for: "lesson-rewrite|\(lesson.id.uuidString)|\(pair.original)|\(pair.correction)"
            ),
            cardID: lesson.cardID,
            provider: lesson.provider,
            originalText: pair.original,
            suggestedText: pair.correction,
            rationale: rationale,
            confidence: min(1.0, max(0.05, lesson.validationConfidence)),
            createdAt: lesson.updatedAt
        )
    }

    private func dedupedSuggestions(
        _ suggestions: [RewriteSuggestion],
        excludingPairKeys: Set<String> = []
    ) -> [RewriteSuggestion] {
        var byPair: [String: RewriteSuggestion] = [:]
        for suggestion in suggestions {
            guard let pair = normalizedPair(for: suggestion) else { continue }
            let key = pairKey(original: pair.original, correction: pair.correction)
            if excludingPairKeys.contains(key) {
                continue
            }
            if let existing = byPair[key] {
                let existingValidation = validationPriority(for: existing)
                let candidateValidation = validationPriority(for: suggestion)
                if candidateValidation > existingValidation
                    || (candidateValidation == existingValidation && suggestion.confidence > existing.confidence)
                    || (candidateValidation == existingValidation
                        && suggestion.confidence == existing.confidence
                        && suggestion.createdAt > existing.createdAt) {
                    byPair[key] = suggestion
                }
            } else {
                byPair[key] = suggestion
            }
        }
        return Array(byPair.values)
    }

    private func invalidatedLessonPairKeys(store: MemorySQLiteStore) throws -> Set<String> {
        let lessons = try store.fetchLessonsForRewrite(
            query: "",
            provider: nil,
            limit: rewriteSuggestionFetchLimit * 2
        )
        var keys = Set<String>()
        for lesson in lessons {
            guard validationState(for: lesson) == .invalidated else { continue }
            guard let pair = normalizedPair(for: lesson) else { continue }
            keys.insert(pairKey(original: pair.original, correction: pair.correction))
        }
        return keys
    }

    private func filteredSuggestions(
        from suggestions: [RewriteSuggestion],
        excludingPairKeys: Set<String>
    ) -> [RewriteSuggestion] {
        guard !excludingPairKeys.isEmpty else { return suggestions }
        return suggestions.filter { suggestion in
            guard let pair = normalizedPair(for: suggestion) else { return false }
            return !excludingPairKeys.contains(pairKey(original: pair.original, correction: pair.correction))
        }
    }

    private func lessonPairKey(for lesson: MemoryRewriteLesson) -> String {
        pairKey(original: lesson.mistakeText, correction: lesson.correctionText)
    }

    private func pairKey(original: String, correction: String) -> String {
        "\(MemoryTextNormalizer.collapsedWhitespace(original).lowercased())|\(MemoryTextNormalizer.collapsedWhitespace(correction).lowercased())"
    }

    private func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func stripMetadataTags(from value: String) -> String {
        var remaining = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while remaining.hasPrefix("["),
              let end = remaining.firstIndex(of: "]") {
            let next = remaining.index(after: end)
            remaining = String(remaining[next...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MemoryTextNormalizer.collapsedWhitespace(remaining.isEmpty ? value : remaining)
    }

    private func metadataTag(named name: String, from rationale: String) -> String? {
        let lower = rationale.lowercased()
        let marker = "[\(name.lowercased()):"
        guard let startRange = lower.range(of: marker) else { return nil }
        let tail = rationale[startRange.upperBound...]
        guard let endIndex = tail.firstIndex(of: "]") else { return nil }
        let value = tail[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private func synthesizedLessonCard(from lesson: MemoryRewriteLesson) -> MemoryCard {
        let sourceID = MemoryIdentifier.stableUUID(for: "lesson-source|\(lesson.id.uuidString)")
        let sourceFileID = MemoryIdentifier.stableUUID(for: "lesson-file|\(lesson.id.uuidString)")
        let eventID = MemoryIdentifier.stableUUID(for: "lesson-event|\(lesson.id.uuidString)")
        let detail = """
        Mistake: \(lesson.mistakeText)
        Correction: \(lesson.correctionText)
        Validation: \(lesson.validationState.displayName)
        Provenance: \(lesson.provenance)
        Rationale: \(lesson.rationale)
        """
        let scoreBoost = lesson.validationState.isValidated ? 0.08 : 0

        return MemoryCard(
            id: MemoryIdentifier.stableUUID(for: "lesson-card|\(lesson.id.uuidString)"),
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            provider: lesson.provider,
            title: MemoryTextNormalizer.normalizedTitle("Lesson: \(lesson.mistakeText)", fallback: "Memory Lesson"),
            summary: MemoryTextNormalizer.normalizedSummary("\(lesson.mistakeText) -> \(lesson.correctionText)"),
            detail: detail,
            keywords: MemoryTextNormalizer.keywords(
                from: "\(lesson.mistakeText) \(lesson.correctionText) \(lesson.rationale)",
                limit: 16
            ),
            score: min(1.0, max(0.1, lesson.confidence + scoreBoost)),
            createdAt: lesson.createdAt,
            updatedAt: lesson.createdAt,
            isPlanContent: false,
            metadata: [
                "lesson_validation": lesson.validationState.rawValue,
                "lesson_provenance": lesson.provenance,
                "lesson_confidence": String(format: "%.2f", lesson.confidence)
            ]
        )
    }

    private func lessonContextLine(
        for lesson: MemoryRewriteLesson,
        includeRationale: Bool
    ) -> String {
        let pair = "\"\(snippet(lesson.mistakeText, limit: 48))\" -> \"\(snippet(lesson.correctionText, limit: 64))\""
        var context = "\(lesson.validationState.displayName) lesson from \(lesson.provenance) (confidence \(String(format: "%.2f", lesson.confidence))): \(pair)"
        if includeRationale {
            let trimmedRationale = lesson.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRationale.isEmpty {
                context += ". \(snippet(trimmedRationale, limit: 120))"
            }
        }
        return context
    }

    private func snippet(_ value: String, limit: Int) -> String {
        let normalized = MemoryTextNormalizer.collapsedWhitespace(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }

    private func cardLikelyRepresentsLesson(
        _ card: MemoryCard,
        lesson: MemoryRewriteLesson
    ) -> Bool {
        let content = "\(card.title) \(card.summary) \(card.detail)".lowercased()
        return content.contains(lesson.mistakeText.lowercased())
            && content.contains(lesson.correctionText.lowercased())
    }

    private func isWeakGenericCard(_ card: MemoryCard) -> Bool {
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let detail = card.detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let combined = "\(title) \(summary) \(detail)"

        let rewriteIndicators = ["->", "=>", "→", "rewrite", "original", "suggested", "correction", "typo"]
        let hasRewriteIndicator = rewriteIndicators.contains { combined.contains($0) }
        if hasRewriteIndicator {
            return false
        }

        let genericTitleTokens: Set<String> = [
            "chat", "message", "conversation", "session", "history", "note", "section", "event"
        ]
        if genericTitleTokens.contains(title) || genericTitleTokens.contains(summary) {
            return true
        }
        if card.score < 0.65 {
            return true
        }
        return false
    }

    private func isHighSignalCard(_ card: MemoryCard) -> Bool {
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = card.detail.trimmingCharacters(in: .whitespacesAndNewlines)

        if title == "workspace" || title == "storage" || title == "state" {
            return false
        }
        if detail.hasPrefix("{") && detail.hasSuffix("}") {
            if !detail.contains("->"),
               !detail.localizedCaseInsensitiveContains("prompt"),
               !detail.localizedCaseInsensitiveContains("rewrite"),
               !detail.localizedCaseInsensitiveContains("response") {
                return false
            }
        }

        let combined = "\(summary) \(detail)"
        let alphaWords = combined.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains(where: \.isLetter)
        }
        if alphaWords.count < 5 {
            return false
        }
        return true
    }
}
