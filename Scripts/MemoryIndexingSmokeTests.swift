import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MemoryIndexingSmokeTests {
    static func main() async {
        do {
            let sandboxRoot = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandboxRoot) }

            let discoveryService = MemoryProviderDiscoveryService(homeURL: sandboxRoot, fileManager: .default)
            let discovery = discoveryService.discover()

            check(!discovery.providers.isEmpty, "Expected provider discovery to find at least one provider")
            check(
                discovery.providers.contains(where: { $0.kind == .codex }),
                "Expected codex provider to be discovered"
            )
            check(
                discovery.providers.contains(where: { $0.kind == .opencode }),
                "Expected opencode provider to be discovered"
            )

            let dbURL = sandboxRoot
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("KeyScribe", isDirectory: true)
                .appendingPathComponent("Memory", isDirectory: true)
                .appendingPathComponent("memory.sqlite3")

            let store = try MemorySQLiteStore(databaseURL: dbURL)
            let indexingService = MemoryIndexingService(
                fileManager: .default,
                adapterRegistry: MemorySourceAdapterRegistry(),
                rewriteProvider: MockAILessonRewriteProvider(),
                maxFilesPerSource: 100,
                maxEventsPerFile: 50
            )

            let report = await indexingService.indexSources(discovery.sources, store: store)
            check(report.indexedFiles > 0, "Expected at least one indexed source file")
            check(report.indexedEvents > 0, "Expected at least one indexed event")
            check(report.indexedCards > 0, "Expected at least one indexed memory card")

            let unchangedReindexReport = await indexingService.rebuildIndex(from: discovery.sources, store: store)
            check(
                unchangedReindexReport.indexedFiles == 0,
                "Expected unchanged rebuild to skip file re-indexing"
            )
            check(
                unchangedReindexReport.skippedFiles > 0,
                "Expected unchanged rebuild to report skipped files"
            )

            let cards = try store.fetchCardsForRewrite(
                query: "teh",
                options: MemoryRewriteLookupOptions(provider: .codex, includePlanContent: false, limit: 5)
            )
            check(!cards.isEmpty, "Expected codex memory card query to return results")

            let rewriteSuggestions = try store.fetchRewriteSuggestions(
                query: "teh",
                provider: .codex,
                limit: 10
            )
            check(
                rewriteSuggestions.contains(where: {
                    $0.originalText.localizedCaseInsensitiveContains("teh")
                        && $0.suggestedText.localizedCaseInsensitiveContains("the")
                }),
                "Expected rewrite suggestion to include teh -> the correction"
            )

            try write(
                """
                {"type":"rewrite","title":"Fix locale spelling","content":"colour -> color","original":"colour","suggested":"color","timestamp":"2026-02-01T10:10:00Z"}
                """,
                to: sandboxRoot.appendingPathComponent(".codex/archived_sessions/session-1.jsonl")
            )

            let reindexReport = await indexingService.indexSources(discovery.sources, store: store)
            check(reindexReport.indexedFiles > 0, "Expected reindex to process modified files")

            let staleSuggestions = try store.fetchRewriteSuggestions(
                query: "teh",
                provider: .codex,
                limit: 10
            )
            check(
                staleSuggestions.isEmpty,
                "Expected stale rewrite suggestions to be removed after file changes"
            )

            let updatedSuggestions = try store.fetchRewriteSuggestions(
                query: "colour",
                provider: .codex,
                limit: 10
            )
            check(
                updatedSuggestions.contains(where: {
                    $0.originalText.localizedCaseInsensitiveContains("colour")
                        && $0.suggestedText.localizedCaseInsensitiveContains("color")
                }),
                "Expected updated rewrite suggestion after reindex"
            )

            let fullRebuildReport = await indexingService.rebuildFromScratch(from: discovery.sources, store: store)
            check(
                fullRebuildReport.indexedFiles > 0,
                "Expected clear + rebuild from scratch to re-index files"
            )

            print("PASS: Memory indexing smoke tests passed")
        } catch {
            fputs("FAIL: Memory indexing smoke test threw error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-memory-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(
            """
            {"type":"rewrite","title":"Fix typo","content":"teh -> the","original":"teh","suggested":"the","timestamp":"2026-02-01T10:00:00Z"}
            {"type":"conversation","title":"Chat","content":"Remember to ask for acceptance criteria","timestamp":"2026-02-01T10:01:00Z"}
            """,
            to: root.appendingPathComponent(".codex/archived_sessions/session-1.jsonl")
        )

        try write(
            """
            {"input":"please summarize this bug and include root cause","mode":"chat","parts":["summary","root cause"]}
            """,
            to: root.appendingPathComponent(".local/state/opencode/prompt-history.jsonl")
        )

        try write(
            """
            {"type":"message","title":"Claude Note","message":"Do not skip edge-case tests","timestamp":"2026-02-01T11:05:00Z"}
            """,
            to: root.appendingPathComponent(".claude/projects/sample/chat.jsonl")
        )

        return root
    }

    private static func write(_ value: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try value.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private struct MockAILessonRewriteProvider: MemoryRewriteExtractionProviding {
        func summary(
            for draft: MemoryEventDraft,
            provider: MemoryProviderKind
        ) async -> String? {
            _ = provider
            if let nativeSummary = draft.nativeSummary, !nativeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return MemoryTextNormalizer.normalizedSummary(nativeSummary)
            }
            return MemoryTextNormalizer.normalizedSummary(draft.body, limit: 200)
        }

        func rewriteSuggestion(
            for draft: MemoryEventDraft,
            card: MemoryCard,
            provider: MemoryProviderKind
        ) async -> RewriteSuggestion? {
            _ = draft
            _ = card
            _ = provider
            return nil
        }

        func lesson(
            for draft: MemoryEventDraft,
            card: MemoryCard,
            provider: MemoryProviderKind
        ) async -> MemoryLessonDraft? {
            _ = card
            _ = provider
            guard !draft.isPlanContent else { return nil }
            guard let pair = rewritePair(for: draft) else { return nil }
            guard pair.original.caseInsensitiveCompare(pair.suggested) != .orderedSame else { return nil }

            return MemoryLessonDraft(
                mistakePattern: pair.original,
                improvedPrompt: pair.suggested,
                rationale: "AI synthesized lesson (smoke-test mock)",
                validationConfidence: 0.92,
                sourceMetadata: [
                    "extraction_method": "ai",
                    "provider_mode": "openai",
                    "test_provider": "mock-ai"
                ]
            )
        }

        private func rewritePair(for draft: MemoryEventDraft) -> (original: String, suggested: String)? {
            let metadata = draft.metadata
            if let original = firstNonEmpty(
                metadata["original_text"],
                metadata["original"],
                metadata["input"],
                metadata["prompt"]
            ),
               let suggested = firstNonEmpty(
                metadata["suggested_text"],
                metadata["suggested"],
                metadata["rewrite"],
                metadata["response"],
                metadata["completion"],
                metadata["output"]
               ) {
                return (original, suggested)
            }

            return splitArrowRewrite(MemoryTextNormalizer.normalizedBody(draft.body))
        }

        private func splitArrowRewrite(_ body: String) -> (original: String, suggested: String)? {
            for marker in ["->", "=>", "→"] {
                let parts = body.components(separatedBy: marker)
                guard parts.count == 2 else { continue }
                let lhs = MemoryTextNormalizer.normalizedBody(parts[0])
                let rhs = MemoryTextNormalizer.normalizedBody(parts[1])
                guard !lhs.isEmpty, !rhs.isEmpty else { continue }
                return (lhs, rhs)
            }
            return nil
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
}
