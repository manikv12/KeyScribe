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
            queueIndexing(sources: filteredDiscovery.sources, rebuild: false)
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
        queueIndexing(sources: discovery.sources, rebuild: true)
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

    private func queueIndexing(sources: [MemoryDiscoveredSource], rebuild: Bool) {
        activeIndexTask?.cancel()
        let indexingService = self.indexingService
        let storeFactory = self.storeFactory

        activeIndexTask = Task.detached(priority: .utility) {
            do {
                let store = try storeFactory()
                if rebuild {
                    _ = await indexingService.rebuildIndex(from: sources, store: store)
                } else {
                    _ = await indexingService.indexSources(sources, store: store)
                }
            } catch {
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
