import Foundation

@MainActor
final class MemoryIndexingSettingsService {
    struct Provider: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let sourceCount: Int
    }

    struct SourceFolder: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
        let providerID: String
    }

    struct ScanResult {
        let providers: [Provider]
        let sourceFolders: [SourceFolder]
        let indexQueued: Bool
    }

    static let shared = MemoryIndexingSettingsService()
    static let indexingDidProgressNotification = Notification.Name("KeyScribe.memoryIndexingDidProgress")
    static let indexingDidFinishNotification = Notification.Name("KeyScribe.memoryIndexingDidFinish")

    enum IndexingNotificationUserInfoKey {
        static let rebuild = "rebuild"
        static let totalSources = "totalSources"
        static let discoveredSources = "discoveredSources"
        static let currentSourceDisplayName = "currentSourceDisplayName"
        static let currentFilePath = "currentFilePath"
        static let indexedFiles = "indexedFiles"
        static let skippedFiles = "skippedFiles"
        static let indexedEvents = "indexedEvents"
        static let indexedCards = "indexedCards"
        static let indexedLessons = "indexedLessons"
        static let indexedRewriteSuggestions = "indexedRewriteSuggestions"
        static let failureCount = "failureCount"
        static let firstFailure = "firstFailure"
    }

    private let discoveryService: MemoryProviderDiscoveryService
    private let indexingService: MemoryIndexingService
    private let storeFactory: @Sendable () throws -> MemorySQLiteStore
    private var activeIndexTask: Task<Void, Never>?

    init(
        discoveryService: MemoryProviderDiscoveryService = .shared,
        indexingService: MemoryIndexingService = .shared,
        storeFactory: @escaping @Sendable () throws -> MemorySQLiteStore = { try MemorySQLiteStore() }
    ) {
        self.discoveryService = discoveryService
        self.indexingService = indexingService
        self.storeFactory = storeFactory
    }

    func detectedProviders(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) -> [Provider] {
        let discovery = discoveryService.discover(
            enabledProviders: Set(enabledProviderIDs),
            enabledSourceFolders: Set(enabledSourceFolderIDs)
        )
        return discovery.providers.map(Self.makeProvider)
    }

    func detectedSourceFolders(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) -> [SourceFolder] {
        let discovery = discoveryService.discover(
            enabledProviders: Set(enabledProviderIDs),
            enabledSourceFolders: Set(enabledSourceFolderIDs)
        )
        return discovery.sourceFolders.map(Self.makeSourceFolder)
    }

    func rescan(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = [],
        runIndexing: Bool
    ) -> ScanResult {
        let discovery = discoveryService.discover()

        if runIndexing {
            let filteredDiscovery = discoveryService.discover(
                enabledProviders: Set(enabledProviderIDs),
                enabledSourceFolders: Set(enabledSourceFolderIDs)
            )
            queueIndexing(sources: filteredDiscovery.sources, rebuild: false, clearBeforeIndexing: false)
        }

        return ScanResult(
            providers: discovery.providers.map(Self.makeProvider),
            sourceFolders: discovery.sourceFolders.map(Self.makeSourceFolder),
            indexQueued: runIndexing
        )
    }

    func rebuildIndex(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) {
        let discovery = discoveryService.discover(
            enabledProviders: Set(enabledProviderIDs),
            enabledSourceFolders: Set(enabledSourceFolderIDs)
        )
        queueIndexing(sources: discovery.sources, rebuild: true, clearBeforeIndexing: false)
    }

    func rebuildIndexFromScratch(
        enabledProviderIDs: [String] = [],
        enabledSourceFolderIDs: [String] = []
    ) {
        let discovery = discoveryService.discover(
            enabledProviders: Set(enabledProviderIDs),
            enabledSourceFolders: Set(enabledSourceFolderIDs)
        )
        queueIndexing(sources: discovery.sources, rebuild: true, clearBeforeIndexing: true)
    }

    func clearMemories() {
        do {
            let store = try storeFactory()
            try store.clearIndexedMemories()
        } catch {
            // best effort cleanup
        }
    }

    func clearArchive() {
        do {
            let store = try storeFactory()
            try store.clearAllIndexedData()
        } catch {
            // best effort cleanup
        }
    }

    func browseIndexedMemories(
        query: String,
        providerID: String?,
        sourceFolderID: String?,
        includePlanContent: Bool = false,
        limit: Int = 80
    ) -> [MemoryIndexedEntry] {
        do {
            let store = try storeFactory()
            let normalizedProviderID = providerID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSourceFolderID = sourceFolderID?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let provider = normalizedProviderID.flatMap { rawValue in
                MemoryProviderKind(rawValue: rawValue.lowercased())
            }

            return try store.fetchIndexedEntries(
                query: query,
                provider: provider,
                sourceRootPath: normalizedSourceFolderID,
                includePlanContent: includePlanContent,
                limit: limit
            )
        } catch {
            return []
        }
    }

    private func queueIndexing(sources: [MemoryDiscoveredSource], rebuild: Bool, clearBeforeIndexing: Bool) {
        activeIndexTask?.cancel()
        let indexingService = self.indexingService
        let storeFactory = self.storeFactory
        let totalSources = sources.count

        activeIndexTask = Task.detached(priority: .utility) {
            let emitProgress: MemoryIndexingService.ProgressHandler = { report, currentSource, currentFilePath in
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.indexingDidProgressNotification,
                        object: nil,
                        userInfo: [
                            IndexingNotificationUserInfoKey.rebuild: rebuild,
                            IndexingNotificationUserInfoKey.totalSources: totalSources,
                            IndexingNotificationUserInfoKey.discoveredSources: report.discoveredSources,
                            IndexingNotificationUserInfoKey.currentSourceDisplayName: currentSource?.displayName ?? "",
                            IndexingNotificationUserInfoKey.currentFilePath: currentFilePath ?? "",
                            IndexingNotificationUserInfoKey.indexedFiles: report.indexedFiles,
                            IndexingNotificationUserInfoKey.skippedFiles: report.skippedFiles,
                            IndexingNotificationUserInfoKey.indexedEvents: report.indexedEvents,
                            IndexingNotificationUserInfoKey.indexedCards: report.indexedCards,
                            IndexingNotificationUserInfoKey.indexedLessons: report.indexedLessons,
                            IndexingNotificationUserInfoKey.indexedRewriteSuggestions: report.indexedRewriteSuggestions,
                            IndexingNotificationUserInfoKey.failureCount: report.failures.count,
                            IndexingNotificationUserInfoKey.firstFailure: report.failures.first ?? ""
                        ]
                    )
                }
            }

            await emitProgress(MemoryIndexingReport(), nil, nil)
            do {
                let store = try storeFactory()
                let report: MemoryIndexingReport
                if clearBeforeIndexing {
                    report = await indexingService.rebuildFromScratch(
                        from: sources,
                        store: store,
                        progress: emitProgress
                    )
                } else if rebuild {
                    report = await indexingService.rebuildIndex(
                        from: sources,
                        store: store,
                        progress: emitProgress
                    )
                } else {
                    report = await indexingService.indexSources(
                        sources,
                        store: store,
                        progress: emitProgress
                    )
                }
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.indexingDidFinishNotification,
                        object: nil,
                        userInfo: [
                            IndexingNotificationUserInfoKey.rebuild: rebuild,
                            IndexingNotificationUserInfoKey.discoveredSources: report.discoveredSources,
                            IndexingNotificationUserInfoKey.indexedFiles: report.indexedFiles,
                            IndexingNotificationUserInfoKey.skippedFiles: report.skippedFiles,
                            IndexingNotificationUserInfoKey.indexedEvents: report.indexedEvents,
                            IndexingNotificationUserInfoKey.indexedCards: report.indexedCards,
                            IndexingNotificationUserInfoKey.indexedLessons: report.indexedLessons,
                            IndexingNotificationUserInfoKey.indexedRewriteSuggestions: report.indexedRewriteSuggestions,
                            IndexingNotificationUserInfoKey.failureCount: report.failures.count,
                            IndexingNotificationUserInfoKey.firstFailure: report.failures.first ?? ""
                        ]
                    )
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.indexingDidFinishNotification,
                        object: nil,
                        userInfo: [
                            IndexingNotificationUserInfoKey.rebuild: rebuild,
                            IndexingNotificationUserInfoKey.discoveredSources: 0,
                            IndexingNotificationUserInfoKey.indexedFiles: 0,
                            IndexingNotificationUserInfoKey.skippedFiles: 0,
                            IndexingNotificationUserInfoKey.indexedEvents: 0,
                            IndexingNotificationUserInfoKey.indexedCards: 0,
                            IndexingNotificationUserInfoKey.indexedLessons: 0,
                            IndexingNotificationUserInfoKey.indexedRewriteSuggestions: 0,
                            IndexingNotificationUserInfoKey.failureCount: 1,
                            IndexingNotificationUserInfoKey.firstFailure: error.localizedDescription
                        ]
                    )
                }
                return
            }
        }
    }

    private static func makeProvider(_ provider: MemoryDiscoveredProvider) -> Provider {
        Provider(
            id: provider.id,
            name: provider.name,
            detail: provider.detail,
            sourceCount: provider.sourceCount
        )
    }

    private static func makeSourceFolder(_ source: MemoryDiscoveredSourceFolder) -> SourceFolder {
        SourceFolder(
            id: source.id,
            name: source.name,
            path: source.path,
            providerID: source.providerID
        )
    }
}
