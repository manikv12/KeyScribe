import Foundation

struct MemoryIndexingReport: Sendable {
    var discoveredSources = 0
    var indexedFiles = 0
    var skippedFiles = 0
    var indexedEvents = 0
    var indexedCards = 0
    var indexedRewriteSuggestions = 0
    var failures: [String] = []

    var hasFailures: Bool {
        !failures.isEmpty
    }
}

actor MemoryIndexingService {
    static let shared = MemoryIndexingService()

    private let fileManager: FileManager
    private let adapterRegistry: MemorySourceAdapterRegistry
    private let rewriteProvider: MemoryRewriteExtractionProviding
    private let maxFilesPerSource: Int
    private let maxEventsPerFile: Int

    init(
        fileManager: FileManager = .default,
        adapterRegistry: MemorySourceAdapterRegistry = MemorySourceAdapterRegistry(),
        rewriteProvider: MemoryRewriteExtractionProviding = StubMemoryRewriteExtractionProvider.shared,
        maxFilesPerSource: Int = 350,
        maxEventsPerFile: Int = 80
    ) {
        self.fileManager = fileManager
        self.adapterRegistry = adapterRegistry
        self.rewriteProvider = rewriteProvider
        self.maxFilesPerSource = max(1, maxFilesPerSource)
        self.maxEventsPerFile = max(1, maxEventsPerFile)
    }

    func rebuildIndex(
        from sources: [MemoryDiscoveredSource],
        store: MemorySQLiteStore
    ) async -> MemoryIndexingReport {
        do {
            try store.clearAllIndexedData()
        } catch {
            return MemoryIndexingReport(
                failures: ["Failed to clear existing index data before rebuild: \(error.localizedDescription)"]
            )
        }
        return await indexSources(sources, store: store)
    }

    func indexSources(
        _ sources: [MemoryDiscoveredSource],
        store: MemorySQLiteStore
    ) async -> MemoryIndexingReport {
        var report = MemoryIndexingReport()

        for source in sources {
            if Task.isCancelled {
                break
            }
            report.discoveredSources += 1
            await index(source: source, store: store, report: &report)
        }

        return report
    }

    private func index(
        source: MemoryDiscoveredSource,
        store: MemorySQLiteStore,
        report: inout MemoryIndexingReport
    ) async {
        guard let adapter = adapterRegistry.adapter(for: source.provider) else {
            report.failures.append("No source adapter found for provider \(source.provider.rawValue)")
            return
        }

        let sourceID = MemoryIdentifier.stableUUID(
            for: "source|\(source.provider.rawValue)|\(source.rootURL.path)"
        )
        let sourceRecord = MemorySource(
            id: sourceID,
            provider: source.provider,
            rootPath: source.rootURL.path,
            displayName: source.displayName,
            metadata: [
                "detail": source.detail,
                "source_id": source.id
            ]
        )

        do {
            try store.upsertSource(sourceRecord)
        } catch {
            report.failures.append("Failed to upsert source \(source.rootURL.path): \(error.localizedDescription)")
            return
        }

        let candidateFiles = adapter.discoverFiles(
            in: source.rootURL,
            fileManager: fileManager,
            maxFiles: maxFilesPerSource
        )

        for fileURL in candidateFiles {
            if Task.isCancelled {
                break
            }
            await index(
                fileURL: fileURL,
                source: source,
                sourceID: sourceID,
                adapter: adapter,
                store: store,
                report: &report
            )
        }
    }

    private func index(
        fileURL: URL,
        source: MemoryDiscoveredSource,
        sourceID: UUID,
        adapter: any MemorySourceAdapter,
        store: MemorySQLiteStore,
        report: inout MemoryIndexingReport
    ) async {
        let relativePath = Self.relativePath(of: fileURL, to: source.rootURL)
        let fileID = MemoryIdentifier.stableUUID(
            for: "file|\(sourceID.uuidString)|\(relativePath)"
        )

        let sourceFileRecord = makeSourceFileRecord(
            id: fileID,
            sourceID: sourceID,
            fileURL: fileURL,
            relativePath: relativePath
        )

        do {
            let existing = try store.fetchSourceFile(
                sourceID: sourceID,
                relativePath: relativePath
            )
            if let existing,
               existing.fileHash == sourceFileRecord.fileHash,
               existing.parseError == nil {
                report.skippedFiles += 1
                return
            }

            if let existing,
               existing.fileHash != sourceFileRecord.fileHash || existing.parseError != nil {
                try store.clearIndexedContent(forSourceFileID: fileID)
            }

            try store.upsertSourceFile(sourceFileRecord)
        } catch {
            report.failures.append("Failed to stage source file \(fileURL.path): \(error.localizedDescription)")
            return
        }

        do {
            let drafts = try adapter.parse(
                fileURL: fileURL,
                relativePath: relativePath,
                fileManager: fileManager
            )
            if drafts.isEmpty {
                report.skippedFiles += 1
                return
            }

            report.indexedFiles += 1
            let limitedDrafts = Array(drafts.prefix(maxEventsPerFile))
            for (index, draft) in limitedDrafts.enumerated() {
                if Task.isCancelled {
                    break
                }
                let eventID = MemoryIdentifier.stableUUID(
                    for: "event|\(fileID.uuidString)|\(index)|\(draft.kind.rawValue)|\(draft.title)|\(draft.body)"
                )
                let event = MemoryEvent(
                    id: eventID,
                    sourceID: sourceID,
                    sourceFileID: fileID,
                    provider: source.provider,
                    kind: draft.kind,
                    title: draft.title,
                    body: draft.body,
                    timestamp: draft.timestamp,
                    nativeSummary: draft.nativeSummary,
                    keywords: draft.keywords,
                    isPlanContent: draft.isPlanContent,
                    metadata: draft.metadata,
                    rawPayload: draft.rawPayload
                )
                try store.upsertEvent(event)
                report.indexedEvents += 1

                let summary = await rewriteProvider.summary(for: draft, provider: source.provider)
                let card = makeMemoryCard(
                    sourceID: sourceID,
                    sourceFileID: fileID,
                    eventID: eventID,
                    provider: source.provider,
                    draft: draft,
                    summary: summary
                )
                try store.upsertCard(card)
                report.indexedCards += 1

                if let rewriteSuggestion = await rewriteProvider.rewriteSuggestion(
                    for: draft,
                    card: card,
                    provider: source.provider
                ) {
                    try store.insertRewriteSuggestion(rewriteSuggestion)
                    report.indexedRewriteSuggestions += 1
                }
            }
        } catch {
            report.failures.append("Failed to index file \(fileURL.path): \(error.localizedDescription)")
            do {
                var erroredFile = sourceFileRecord
                erroredFile.parseError = error.localizedDescription
                erroredFile.indexedAt = Date()
                try store.upsertSourceFile(erroredFile)
            } catch {
                report.failures.append("Failed to save parse error for \(fileURL.path): \(error.localizedDescription)")
            }
        }
    }

    private func makeSourceFileRecord(
        id: UUID,
        sourceID: UUID,
        fileURL: URL,
        relativePath: String
    ) -> MemorySourceFile {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate ?? Date()
        let fileSize = Int64(values?.fileSize ?? 0)
        let fileHash: String
        if let data = fileManager.contents(atPath: fileURL.path) {
            fileHash = MemoryIdentifier.stableHexDigest(data: data)
        } else {
            fileHash = MemoryIdentifier.stableHexDigest(for: "\(fileURL.path)|\(modifiedAt.timeIntervalSince1970)|\(fileSize)")
        }

        return MemorySourceFile(
            id: id,
            sourceID: sourceID,
            absolutePath: fileURL.path,
            relativePath: relativePath,
            fileHash: fileHash,
            fileSizeBytes: fileSize,
            modifiedAt: modifiedAt,
            indexedAt: Date(),
            parseError: nil
        )
    }

    private func makeMemoryCard(
        sourceID: UUID,
        sourceFileID: UUID,
        eventID: UUID,
        provider: MemoryProviderKind,
        draft: MemoryEventDraft,
        summary: String?
    ) -> MemoryCard {
        let cardSummary = MemoryTextNormalizer.normalizedSummary(summary ?? draft.title)
        let detail = MemoryTextNormalizer.normalizedBody(draft.body)
        let score = baseScore(for: draft.kind, hasRewriteHint: draft.kind == .rewrite)
        let createdAt = Date()
        let cardID = MemoryIdentifier.stableUUID(
            for: "card|\(eventID.uuidString)|\(cardSummary)|\(detail)"
        )

        return MemoryCard(
            id: cardID,
            sourceID: sourceID,
            sourceFileID: sourceFileID,
            eventID: eventID,
            provider: provider,
            title: MemoryTextNormalizer.normalizedTitle(draft.title),
            summary: cardSummary,
            detail: detail,
            keywords: draft.keywords,
            score: score,
            createdAt: createdAt,
            updatedAt: createdAt,
            isPlanContent: draft.isPlanContent,
            metadata: draft.metadata
        )
    }

    private func baseScore(for kind: MemoryEventKind, hasRewriteHint: Bool) -> Double {
        let base: Double
        switch kind {
        case .rewrite:
            base = 1.0
        case .summary:
            base = 0.85
        case .conversation:
            base = 0.72
        case .note:
            base = 0.62
        case .fileEdit:
            base = 0.58
        case .command:
            base = 0.5
        case .plan:
            base = 0.24
        case .unknown:
            base = 0.4
        }
        return hasRewriteHint ? min(1.0, base + 0.08) : base
    }

    private static func relativePath(of fileURL: URL, to rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath) {
            let suffix = String(filePath.dropFirst(rootPath.count))
            return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return fileURL.lastPathComponent
    }
}
