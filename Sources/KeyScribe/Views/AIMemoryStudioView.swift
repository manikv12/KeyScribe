import AppKit
import SwiftUI

struct AIMemoryStudioView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var detectedMemoryProviders: [MemoryIndexingSettingsService.Provider] = []
    @State private var detectedMemorySourceFolders: [MemoryIndexingSettingsService.SourceFolder] = []

    @State private var memoryProviderFilterQuery = ""
    @State private var memoryFolderFilterQuery = ""
    @State private var memoryShowSelectedProvidersOnly = false
    @State private var memoryShowSelectedFoldersOnly = false
    @State private var memoryFoldersOnlyEnabledProviders = true

    @State private var memoryBrowserQuery = ""
    @State private var memoryBrowserSelectedProviderID = "all"
    @State private var memoryBrowserSelectedFolderID = "all"
    @State private var memoryBrowserIncludePlanContent = false
    @State private var memoryBrowserHighSignalOnly = true
    @State private var memoryBrowserEntries: [MemoryIndexedEntry] = []

    @State private var promptRewriteOpenAIKeyVisible = false
    @State private var promptRewriteShowManualAPIKey = false
    @State private var oauthBusyProviderRawValue: String?
    @State private var oauthStatusMessage: String?
    @State private var oauthConnectedProviders: [String: Bool] = [:]
    @State private var promptRewriteAvailableModels: [PromptRewriteModelOption] = []
    @State private var promptRewriteModelsLoading = false
    @State private var promptRewriteModelStatusMessage: String?
    @State private var promptRewriteModelRequestToken = UUID()
    @State private var openAIDeviceUserCode: String?
    @State private var openAIDeviceVerificationURL: URL?

    @State private var memoryActionMessage: String?
    @State private var isMemoryIndexingInProgress = false
    @State private var memoryIndexingProgressSummary: String?
    @State private var memoryIndexingProgressDetail: String?
    @State private var selectedMemoryBrowserEntry: MemoryIndexedEntry?
    @State private var memoryInspectionExplanation: String?
    @State private var memoryInspectionStatusMessage: String?
    @State private var isMemoryInspectionBusy = false
    @State private var showMemoryDetailSheet = false
    @State private var showingProvidersSheet = false
    @State private var showingSourceFoldersSheet = false
    @State private var selectedStudioPage: StudioPage = .dashboard

    private enum StudioPage: String, CaseIterable, Identifiable {
        case dashboard
        case connection
        case models
        case memorySources
        case sourceFolders
        case browser
        case actions

        var id: Self { self }

        var title: String {
            switch self {
            case .dashboard:
                return "Overview"
            case .connection:
                return "Connect Provider"
            case .models:
                return "Prompt Models"
            case .memorySources:
                return "Memory Sources"
            case .sourceFolders:
                return "Source Folders"
            case .browser:
                return "Memory Browser"
            case .actions:
                return "Maintenance"
            }
        }

        var subtitle: String {
            switch self {
            case .dashboard:
                return "Big-picture status and quick actions."
            case .connection:
                return "Connect each provider securely via OAuth or API key."
            case .models:
                return "Choose the model and endpoint for prompt rewrite."
            case .memorySources:
                return "Manage detected providers and enabled sources."
            case .sourceFolders:
                return "Review source folder inclusion rules."
            case .browser:
                return "Browse indexed memories by filters."
            case .actions:
                return "Rescan, rebuild, and cleanup controls."
            }
        }

        var iconName: String {
            switch self {
            case .dashboard:
                return "square.grid.2x2"
            case .connection:
                return "bolt.badge.a"
            case .models:
                return "cpu.fill"
            case .memorySources:
                return "square.stack.3d.up"
            case .sourceFolders:
                return "folder.badge.gearshape"
            case .browser:
                return "magnifyingglass.circle"
            case .actions:
                return "hammer"
            }
        }

        var tint: Color {
            switch self {
            case .dashboard:
                return .purple
            case .connection:
                return .green
            case .models:
                return .cyan
            case .memorySources:
                return .blue
            case .sourceFolders:
                return .orange
            case .browser:
                return .teal
            case .actions:
                return .pink
            }
        }
    }

    private let memoryIndexingSettingsService = MemoryIndexingSettingsService.shared
    private let studioSidebarWidth: CGFloat = 190

    var body: some View {
        ZStack {
            studioBackground
            VStack(spacing: 0) {
                studioHeader

                HStack(spacing: 0) {
                    studioSidebar
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            studioPageContent
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
                )
            }
            .padding(16)
        }
        .sheet(isPresented: $showingProvidersSheet) {
            providersSelectionSheet
        }
        .sheet(isPresented: $showingSourceFoldersSheet) {
            sourceFoldersSelectionSheet
        }
        .sheet(isPresented: $showMemoryDetailSheet) {
            memoryDetailSheet
        }
        .onAppear {
            prepare()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MemoryIndexingSettingsService.indexingDidProgressNotification
            )
        ) { notification in
            handleMemoryIndexingProgress(notification)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MemoryIndexingSettingsService.indexingDidFinishNotification
            )
        ) { notification in
            handleMemoryIndexingCompletion(notification)
        }
    }

    private var studioBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor).opacity(0.68)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.teal.opacity(0.15),
                            Color.blue.opacity(0.05),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: 80, y: -150)
        }
        .ignoresSafeArea()
    }

    private var studioHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI Memory Studio")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Configure memory sources and rewrite models.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                metricPill(label: "Assistant", value: memoryAssistantStateLabel, tint: memoryAssistantStateTint)
            }

            HStack(spacing: 8) {
                metricPill(
                    label: "Providers",
                    value: "\(enabledProviderCount)/\(detectedMemoryProviders.count)",
                    tint: .blue
                )
                metricPill(
                    label: "Folders",
                    value: "\(enabledSourceFolderCount)/\(detectedMemorySourceFolders.count)",
                    tint: .orange
                )
                metricPill(
                    label: "Visible",
                    value: "\(memoryBrowserVisibleCount)",
                    tint: .teal
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor).opacity(0.9),
                            Color(nsColor: .windowBackgroundColor).opacity(0.8)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 8)
    }

    private var studioSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspace")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            VStack(spacing: 3) {
                ForEach(StudioPage.allCases) { page in
                    Button {
                        selectedStudioPage = page
                    } label: {
                        studioPageRow(for: page)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: studioSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.36))
        )
    }

    @ViewBuilder
    private func studioPageRow(for page: StudioPage) -> some View {
        let isSelected = selectedStudioPage == page

        HStack(spacing: 10) {
            Image(systemName: page.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .white : page.tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? page.tint : page.tint.opacity(0.12))
                )

            Text(page.title)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        )
    }

    @ViewBuilder
    private var studioPageContent: some View {
        switch selectedStudioPage {
        case .dashboard:
            studioOverviewPage
        case .connection:
            studioConnectionPage
        case .models:
            studioModelPage
        case .memorySources:
            studioProvidersPage
        case .sourceFolders:
            studioSourceFoldersPage
        case .browser:
            studioBrowserPage
        case .actions:
            studioActionsPage
        }
    }

    private var studioOverviewPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "AI Memory Assistant",
                subtitle: "Toggle the assistant and auto-refresh behavior.",
                symbol: "brain.head.profile",
                tint: memoryAssistantStateTint
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable AI memory assistant", isOn: $settings.memoryIndexingEnabled)
                    Toggle("Auto-refresh detected providers and folders", isOn: $settings.memoryProviderCatalogAutoUpdate)
                    Text("Turn this off if you only want manual control via maintenance actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Quick Navigation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(StudioPage.allCases.filter { $0 != .dashboard }) { page in
                    Button {
                        selectedStudioPage = page
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: page.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(page.tint)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(page.tint.opacity(0.12))
                                )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(page.title)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(page.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let memoryActionMessage {
                Text(memoryActionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
    }

    private var studioConnectionPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerConnectionCard
        }
    }

    private var studioModelPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptModelConfigCard
        }
    }

    private var studioProvidersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Detected Providers",
                subtitle: "Choose which providers can add memory context.",
                symbol: "square.stack.3d.up",
                tint: .blue
            ) {
                if detectedMemoryProviders.isEmpty {
                    emptyStateRow(
                        title: "No providers detected",
                        message: "Open settings sources or run a rescan to discover providers.",
                        systemImage: "tray"
                    )
                } else {
                    HStack {
                        Text("\(enabledProviderCount) of \(detectedMemoryProviders.count) providers enabled")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Manage Providers…") {
                            showingProvidersSheet = true
                        }
                        .buttonStyle(.bordered)
                    }

                    if !memoryProviderFilterQuery.isEmpty || memoryShowSelectedProvidersOnly {
                        HStack {
                            TextField("Filter providers", text: $memoryProviderFilterQuery)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Selected only", isOn: $memoryShowSelectedProvidersOnly)
                                .toggleStyle(.checkbox)
                        }
                    } else {
                        HStack {
                            Text("Tip")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Use \"Manage Providers…\" to enable or disable multiple sources.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !detectedMemoryProviders.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredMemoryProviders) { provider in
                                    Toggle(isOn: Binding(
                                        get: { settings.isMemoryProviderEnabled(provider.id) },
                                        set: { isEnabled in
                                            settings.setMemoryProviderEnabled(provider.id, enabled: isEnabled)
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(provider.name)
                                                .font(.callout.weight(.medium))
                                            Text(provider.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .disabled(!settings.memoryIndexingEnabled)
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(maxHeight: 350)
                    }
                }
            }
        }
    }

    private var studioSourceFoldersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Detected Source Folders",
                subtitle: "Tune which folders are used to build memory index.",
                symbol: "folder.badge.gearshape",
                tint: .orange
            ) {
                if detectedMemorySourceFolders.isEmpty {
                    emptyStateRow(
                        title: "No source folders detected",
                        message: "Open settings sources or run a rescan to discover source folders.",
                        systemImage: "tray"
                    )
                } else {
                    HStack {
                        Text("\(enabledSourceFolderCount) of \(detectedMemorySourceFolders.count) folders enabled")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Manage Folders…") {
                            showingSourceFoldersSheet = true
                        }
                        .buttonStyle(.bordered)
                    }

                    if !memoryFolderFilterQuery.isEmpty || memoryShowSelectedFoldersOnly || !memoryFoldersOnlyEnabledProviders {
                        HStack(spacing: 8) {
                            TextField("Filter source folders", text: $memoryFolderFilterQuery)
                                .textFieldStyle(.roundedBorder)
                            Toggle("Selected only", isOn: $memoryShowSelectedFoldersOnly)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                            Toggle("Only enabled providers", isOn: $memoryFoldersOnlyEnabledProviders)
                                .toggleStyle(.checkbox)
                                .fixedSize()
                                .help("Only enabled providers")
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredMemorySourceFolders.isEmpty ? detectedMemorySourceFolders : filteredMemorySourceFolders) { folder in
                                Toggle(isOn: Binding(
                                    get: { settings.isMemorySourceFolderEnabled(folder.id) },
                                    set: { isEnabled in
                                        settings.setMemorySourceFolderEnabled(folder.id, enabled: isEnabled)
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.name)
                                            .font(.callout.weight(.medium))
                                        Text(folder.path)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .disabled(!settings.memoryIndexingEnabled)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(maxHeight: 350)
                }
            }
        }
    }

    private var studioBrowserPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            memoryBrowserCard
        }
    }

    private var studioActionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            memoryActionsCard
        }
    }

    private var memoryBrowserCard: some View {
        settingsCard(
            title: "Memory Browser",
            subtitle: "List and search indexed memories by provider and folder.",
            symbol: "magnifyingglass.circle",
            tint: .teal
        ) {
            HStack(spacing: 8) {
                TextField("Search indexed memories", text: $memoryBrowserQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        refreshMemoryBrowser()
                    }

                Button("Search") {
                    refreshMemoryBrowser()
                }
                .buttonStyle(.borderedProminent)

                Button("Reload") {
                    refreshMemoryBrowser()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Picker("Provider", selection: $memoryBrowserSelectedProviderID) {
                    Text("All providers").tag("all")
                    ForEach(memoryBrowserProviderOptions) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)

                Picker("Folder", selection: $memoryBrowserSelectedFolderID) {
                    Text("All folders").tag("all")
                    ForEach(memoryBrowserFolderOptions) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Include plan entries", isOn: $memoryBrowserIncludePlanContent)
                    .toggleStyle(.checkbox)
                Toggle("High-signal only", isOn: $memoryBrowserHighSignalOnly)
                    .toggleStyle(.checkbox)
            }
            .onChange(of: memoryBrowserSelectedProviderID) { _ in
                normalizeMemoryBrowserSelections()
                refreshMemoryBrowser()
            }
            .onChange(of: memoryBrowserSelectedFolderID) { _ in
                refreshMemoryBrowser()
            }
            .onChange(of: memoryBrowserIncludePlanContent) { _ in
                refreshMemoryBrowser()
            }
            .onChange(of: memoryBrowserHighSignalOnly) { _ in
                refreshMemoryBrowser()
            }

            if memoryBrowserEntries.isEmpty {
                emptyStateRow(
                    title: "No indexed memories matched",
                    message: "Try broadening your search, toggling filters, or rebuilding the index.",
                    systemImage: "tray"
                )
            } else {
                HStack {
                    Text("Showing \(memoryBrowserVisibleCount) of \(memoryBrowserEntries.count) memory cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if memoryBrowserEntries.count > memoryBrowserVisibleCount {
                        Text("Refine search to narrow results")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(memoryBrowserEntries.prefix(80)) { entry in
                            Button {
                                selectMemoryBrowserEntry(entry)
                            } label: {
                                memoryBrowserEntryRow(
                                    entry,
                                    isSelected: selectedMemoryBrowserEntry?.id == entry.id
                                )
                            }
                            .buttonStyle(.plain)
                            .onTapGesture(count: 2) {
                                selectMemoryBrowserEntry(entry)
                                showMemoryDetailSheet = true
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 460)

                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Double-click a memory to view details and ask AI about it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }
    }

    private var memoryActionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Indexing",
                subtitle: "Rescan sources or rebuild the memory index.",
                symbol: "arrow.triangle.2.circlepath",
                tint: .blue
            ) {
                HStack(spacing: 8) {
                    Button("Rescan") {
                        rescanMemorySources(showMessage: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!settings.memoryIndexingEnabled || isMemoryIndexingInProgress)

                    Button("Rebuild Index") {
                        isMemoryIndexingInProgress = true
                        memoryIndexingProgressSummary = "Preparing incremental rebuild..."
                        memoryIndexingProgressDetail = nil
                        memoryIndexingSettingsService.rebuildIndex(
                            enabledProviderIDs: settings.memoryEnabledProviderIDs,
                            enabledSourceFolderIDs: settings.memoryEnabledSourceFolderIDs
                        )
                        memoryActionMessage = "Started incremental rebuild (new/changed files only)."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.memoryIndexingEnabled || isMemoryIndexingInProgress)
                }

                if isMemoryIndexingInProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Memory indexing in progress...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let memoryIndexingProgressSummary {
                            Text(memoryIndexingProgressSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let memoryIndexingProgressDetail {
                            Text(memoryIndexingProgressDetail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if let memoryActionMessage {
                    Text(memoryActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            settingsCard(
                title: "Danger Zone",
                subtitle: "Destructive actions that clear stored data.",
                symbol: "exclamationmark.triangle",
                tint: .red
            ) {
                HStack(spacing: 8) {
                    Button("Clear + Rebuild From Start", role: .destructive) {
                        isMemoryIndexingInProgress = true
                        memoryIndexingProgressSummary = "Clearing indexed memory data..."
                        memoryIndexingProgressDetail = nil
                        memoryIndexingSettingsService.rebuildIndexFromScratch(
                            enabledProviderIDs: settings.memoryEnabledProviderIDs,
                            enabledSourceFolderIDs: settings.memoryEnabledSourceFolderIDs
                        )
                        memoryActionMessage = "Started full rebuild from scratch."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.memoryIndexingEnabled || isMemoryIndexingInProgress)

                    Button("Clear Memories", role: .destructive) {
                        memoryIndexingSettingsService.clearMemories()
                        memoryActionMessage = "Cleared indexed memories."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.memoryIndexingEnabled)

                    Button("Clear Archive", role: .destructive) {
                        memoryIndexingSettingsService.clearArchive()
                        memoryActionMessage = "Cleared archived memory entries."
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.memoryIndexingEnabled)
                }
            }
        }
    }

    private var enabledProviderCount: Int {
        detectedMemoryProviders.filter { settings.isMemoryProviderEnabled($0.id) }.count
    }

    private var enabledSourceFolderCount: Int {
        detectedMemorySourceFolders.filter { settings.isMemorySourceFolderEnabled($0.id) }.count
    }

    private var memoryAssistantStateLabel: String {
        settings.memoryIndexingEnabled ? "Enabled" : "Paused"
    }

    private var memoryAssistantStateTint: Color {
        settings.memoryIndexingEnabled ? .green : .orange
    }

    private var memoryBrowserVisibleCount: Int {
        min(memoryBrowserEntries.count, 80)
    }

    @ViewBuilder
    private func metricPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func emptyStateRow(title: String, message: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func memoryBrowserEntryRow(
        _ entry: MemoryIndexedEntry,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title.isEmpty ? "Untitled memory" : entry.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.isPlanContent {
                    memoryEntryBadge("Plan", tint: .orange)
                }
                memoryEntryBadge(entry.provider.displayName, tint: .teal)
            }

            Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(entry.sourceRootPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.07),
                    lineWidth: isSelected ? 1.2 : 0.8
                )
        )
    }

    @ViewBuilder
    private var memoryDetailSheet: some View {
        VStack(spacing: 0) {
            if let entry = selectedMemoryBrowserEntry {
                HStack {
                    Text("Memory Detail")
                        .font(.headline)
                    Spacer()
                    memoryEntryBadge(entry.provider.displayName, tint: .teal)
                    if entry.isPlanContent {
                        memoryEntryBadge("Plan", tint: .orange)
                    }
                    Button("Done") {
                        showMemoryDetailSheet = false
                    }
                }
                .padding()
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(entry.title.isEmpty ? "Untitled memory" : entry.title)
                            .font(.title3.weight(.semibold))

                        Text(entry.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Divider()

                        Text("What this memory stores")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(entry.detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )

                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(entry.sourceRootPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }

                        Text("Updated: \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()

                        Divider()

                        HStack(spacing: 8) {
                            Button("Ask AI About This Memory") {
                                explainMemoryEntryWithAI(entry)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isMemoryInspectionBusy)

                            if isMemoryInspectionBusy {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }

                        if let memoryInspectionStatusMessage {
                            Text(memoryInspectionStatusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let memoryInspectionExplanation {
                            Text("AI Explanation")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(memoryInspectionExplanation)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.06))
                                )
                        }
                    }
                    .padding()
                }
            } else {
                Text("No memory selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 540, height: 520)
    }

    @ViewBuilder
    private func memoryEntryBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }

    @ViewBuilder
    private var providerConnectionCard: some View {
        settingsCard(
            title: "Provider Authentication",
            subtitle: "Connect each provider securely before configuring models.",
            symbol: "bolt.badge.a",
            tint: .green
        ) {
            let mode = settings.promptRewriteProviderMode

            providerModeSection

            Divider()

            authStateSummary(for: mode)

            Divider()

            providerAuthenticationSection(for: mode)

            if let oauthStatusMessage {
                Text(oauthStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var promptModelConfigCard: some View {
        let mode = settings.promptRewriteProviderMode

        settingsCard(
            title: "Prompt Model",
            subtitle: "Choose model and endpoint used by prompt rewrite.",
            symbol: "cpu.fill",
            tint: .green
        ) {
            HStack(spacing: 8) {
                Text("Model Catalog")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if promptRewriteModelsLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button("Reload Models") {
                    refreshPromptRewriteModels(showMessage: true)
                }
                .buttonStyle(.bordered)
                .disabled(promptRewriteModelsLoading)
            }

            if !promptRewriteModelPickerOptions.isEmpty {
                Picker("Detected model", selection: $settings.promptRewriteOpenAIModel) {
                    ForEach(promptRewriteModelPickerOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 420, alignment: .leading)
            }

            TextField("Model (e.g. \(mode.defaultModel))", text: $settings.promptRewriteOpenAIModel)
                .textFieldStyle(.roundedBorder)
            Text("Pick a detected model, or type a custom model ID.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Base URL", text: $settings.promptRewriteOpenAIBaseURL)
                .textFieldStyle(.roundedBorder)

            Button("Use \(mode.displayName) Defaults") {
                settings.applyPromptRewriteProviderDefaultsIfNeeded(force: true)
                refreshPromptRewriteModels(showMessage: true)
            }
            .buttonStyle(.bordered)

            if let promptRewriteModelStatusMessage {
                Text(promptRewriteModelStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Model settings are persisted for this provider only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var providerModeSection: some View {
        Picker("Rewrite provider", selection: $settings.promptRewriteProviderModeRawValue) {
            ForEach(PromptRewriteProviderMode.allCases) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)
        .onChange(of: settings.promptRewriteProviderModeRawValue) { _ in
            promptRewriteShowManualAPIKey = false
            oauthStatusMessage = nil
            promptRewriteModelStatusMessage = nil
            promptRewriteAvailableModels = []
            resetOpenAIDeviceCodeState()
            refreshPromptRewriteModels(showMessage: false)
        }

        let mode = settings.promptRewriteProviderMode
        Text(mode.helpText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func authStateSummary(for mode: PromptRewriteProviderMode) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(promptRewriteAuthStateTint(for: mode))
                    .frame(width: 8, height: 8)
                Text(promptRewriteAuthStateLabel(for: mode))
                    .font(.callout)
                    .fontWeight(.medium)
            }

            Text("Your credentials are stored in macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func providerAuthenticationSection(for mode: PromptRewriteProviderMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode.supportsOAuthSignIn {
                oauthAuthenticationSection(for: mode)
            } else if mode.requiresAPIKey {
                apiKeyAuthenticationSection(for: mode)
            } else {
                Text("This provider does not require authentication details in KeyScribe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func oauthAuthenticationSection(for mode: PromptRewriteProviderMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let isConnected = oauthConnectedProviders[mode.rawValue] ?? false

            HStack(spacing: 8) {
                Image(systemName: isConnected ? "checkmark.shield.fill" : "key.slash.fill")
                    .foregroundStyle(isConnected ? .green : .orange)
                Text(isConnected ? "OAuth session is active." : "OAuth session is inactive.")
                    .font(.callout)
                Spacer()
                if oauthBusyProviderRawValue == mode.rawValue {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button(isConnected ? "Reconnect OAuth" : "Connect OAuth") {
                    connectOAuth(for: mode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(oauthBusyProviderRawValue == mode.rawValue)

                if isConnected {
                    Button("Disconnect") {
                        disconnectOAuth(for: mode)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let plan = mode.oauthPlanLabel {
                Text("OAuth uses your \(plan) subscription, similar to OpenCode provider login.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if mode == .openAI,
               let deviceCode = openAIDeviceUserCode,
               let verificationURL = openAIDeviceVerificationURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenAI Device Code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(deviceCode)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Code") {
                            copyToPasteboard(deviceCode)
                            oauthStatusMessage = "Device code copied. Enter it on the OpenAI page."
                        }
                        .buttonStyle(.bordered)
                        Button("Open Page") {
                            _ = NSWorkspace.shared.open(verificationURL)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Enter this code on the OpenAI device page to complete sign-in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }

            DisclosureGroup("Use API key instead (optional)", isExpanded: $promptRewriteShowManualAPIKey) {
                apiKeyField(for: mode)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func apiKeyAuthenticationSection(for mode: PromptRewriteProviderMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This provider uses API key authentication.")
                .font(.caption)
                .foregroundStyle(.secondary)

            apiKeyField(for: mode)
        }
    }

    private func promptRewriteAuthStateLabel(for mode: PromptRewriteProviderMode) -> String {
        if mode.supportsOAuthSignIn {
            let isConnected = oauthConnectedProviders[mode.rawValue] ?? false
            return isConnected ? "OAuth connected" : "OAuth not connected"
        }

        if mode.requiresAPIKey {
            let hasKey = !settings.promptRewriteOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasKey ? "API key configured" : "API key missing"
        }

        return "No credentials required"
    }

    private func promptRewriteAuthStateTint(for mode: PromptRewriteProviderMode) -> Color {
        switch promptRewriteAuthStateLabel(for: mode) {
        case "OAuth connected", "API key configured":
            return .green
        case "API key missing", "OAuth not connected":
            return .orange
        default:
            return .blue
        }
    }

    @ViewBuilder
    private func apiKeyField(for mode: PromptRewriteProviderMode) -> some View {
        HStack(spacing: 8) {
            if promptRewriteOpenAIKeyVisible {
                TextField("\(mode.displayName) API key", text: $settings.promptRewriteOpenAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            } else {
                SecureField("\(mode.displayName) API key", text: $settings.promptRewriteOpenAIAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Show", isOn: $promptRewriteOpenAIKeyVisible)
                .toggleStyle(.checkbox)
                .fixedSize()

            Button {
                copyToPasteboard(settings.promptRewriteOpenAIAPIKey)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy API key to clipboard")
            .disabled(settings.promptRewriteOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var providersSelectionSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Detected Providers")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showingProvidersSheet = false
                }
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if detectedMemoryProviders.isEmpty {
                    Text("No providers detected yet. Click Rescan to detect providers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    HStack(spacing: 8) {
                        TextField("Filter providers", text: $memoryProviderFilterQuery)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Selected only", isOn: $memoryShowSelectedProvidersOnly)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }

                    HStack(spacing: 8) {
                        Button("Select All Visible") {
                            setMemoryProvidersEnabled(filteredMemoryProviders, enabled: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!settings.memoryIndexingEnabled || filteredMemoryProviders.isEmpty)

                        Button("Clear Visible") {
                            setMemoryProvidersEnabled(filteredMemoryProviders, enabled: false)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!settings.memoryIndexingEnabled || filteredMemoryProviders.isEmpty)
                    }

                    if filteredMemoryProviders.isEmpty {
                        Text("No providers match the current filters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredMemoryProviders) { provider in
                                    Toggle(isOn: Binding(
                                        get: { settings.isMemoryProviderEnabled(provider.id) },
                                        set: { isEnabled in
                                            settings.setMemoryProviderEnabled(provider.id, enabled: isEnabled)
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(provider.name)
                                                .font(.callout.weight(.medium))
                                            Text(provider.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .disabled(!settings.memoryIndexingEnabled)
                                }
                            }
                            .padding(.trailing)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(width: 450, height: 500)
    }

    @ViewBuilder
    private var sourceFoldersSelectionSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Detected Source Folders")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showingSourceFoldersSheet = false
                }
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if detectedMemorySourceFolders.isEmpty {
                    Text("No source folders detected yet. Click Rescan to find folders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    HStack(spacing: 8) {
                        TextField("Filter source folders", text: $memoryFolderFilterQuery)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Selected only", isOn: $memoryShowSelectedFoldersOnly)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        Toggle("Only", isOn: $memoryFoldersOnlyEnabledProviders)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                            .help("Only enabled providers")
                    }

                    HStack(spacing: 8) {
                        Button("Select All Visible") {
                            setMemorySourceFoldersEnabled(filteredMemorySourceFolders, enabled: true)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!settings.memoryIndexingEnabled || filteredMemorySourceFolders.isEmpty)

                        Button("Clear Visible") {
                            setMemorySourceFoldersEnabled(filteredMemorySourceFolders, enabled: false)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!settings.memoryIndexingEnabled || filteredMemorySourceFolders.isEmpty)
                    }

                    if filteredMemorySourceFolders.isEmpty {
                        Text("No source folders match the current filters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredMemorySourceFolders) { folder in
                                    Toggle(isOn: Binding(
                                        get: { settings.isMemorySourceFolderEnabled(folder.id) },
                                        set: { isEnabled in
                                            settings.setMemorySourceFolderEnabled(folder.id, enabled: isEnabled)
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder.name)
                                                .font(.callout.weight(.medium))
                                            Text(folder.path)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .disabled(!settings.memoryIndexingEnabled)
                                }
                            }
                            .padding(.trailing)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(width: 550, height: 500)
    }

    private func prepare() {
        refreshOAuthConnectionState()
        refreshPromptRewriteModels(showMessage: false)
        if settings.memoryProviderCatalogAutoUpdate {
            rescanMemorySources(showMessage: false)
            return
        }
        if settings.memoryDetectedProviderIDs.isEmpty && settings.memoryDetectedSourceFolderIDs.isEmpty {
            rescanMemorySources(showMessage: false)
            return
        }
        hydrateMemorySourcesFromSavedSettings()
        normalizeMemoryBrowserSelections()
        refreshMemoryBrowser()
    }

    private func connectOAuth(for mode: PromptRewriteProviderMode) {
        guard mode.supportsOAuthSignIn else { return }
        oauthBusyProviderRawValue = mode.rawValue
        oauthStatusMessage = "Starting \(mode.displayName) OAuth sign-in..."

        Task {
            do {
                switch mode {
                case .openAI:
                    let context = try await PromptRewriteProviderOAuthService.shared.beginOpenAIDeviceAuthorization()
                    await MainActor.run {
                        openAIDeviceUserCode = context.userCode
                        openAIDeviceVerificationURL = context.verificationURL
                        copyToPasteboard(context.userCode)
                        oauthStatusMessage = "Enter code \(context.userCode) on the OpenAI page. Code copied to clipboard."
                        _ = NSWorkspace.shared.open(context.verificationURL)
                    }
                    _ = try await PromptRewriteProviderOAuthService.shared.completeOpenAIDeviceAuthorization(context)
                case .anthropic:
                    let context = try await PromptRewriteProviderOAuthService.shared.beginAnthropicAuthorization()
                    await MainActor.run {
                        _ = NSWorkspace.shared.open(context.authorizationURL)
                    }
                    guard let codeInput = await MainActor.run(body: {
                        presentOAuthCodePrompt(
                            providerName: mode.displayName,
                            instructions: context.instructions
                        )
                    }) else {
                        throw PromptRewriteProviderOAuthError.canceledByUser
                    }
                    _ = try await PromptRewriteProviderOAuthService.shared.completeAnthropicAuthorization(
                        context,
                        codeInput: codeInput
                    )
                case .openRouter, .groq, .ollama:
                    throw PromptRewriteProviderOAuthError.unsupportedProvider
                }

                await MainActor.run {
                    oauthBusyProviderRawValue = nil
                    oauthStatusMessage = "\(mode.displayName) OAuth connected."
                    resetOpenAIDeviceCodeState()
                    if mode.requiresAPIKey {
                        settings.promptRewriteOpenAIAPIKey = ""
                    }
                    refreshOAuthConnectionState()
                    refreshPromptRewriteModels(showMessage: true)
                }
            } catch {
                await MainActor.run {
                    oauthBusyProviderRawValue = nil
                    resetOpenAIDeviceCodeState()
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    oauthStatusMessage = detail.isEmpty
                        ? "\(mode.displayName) OAuth sign-in failed."
                        : "\(mode.displayName) OAuth sign-in failed: \(detail)"
                    refreshOAuthConnectionState()
                }
            }
        }
    }

    private func disconnectOAuth(for mode: PromptRewriteProviderMode) {
        settings.clearPromptRewriteOAuthSession(for: mode)
        resetOpenAIDeviceCodeState()
        refreshOAuthConnectionState()
        oauthStatusMessage = "\(mode.displayName) OAuth disconnected."
        refreshPromptRewriteModels(showMessage: true)
    }

    private func refreshOAuthConnectionState() {
        var next: [String: Bool] = [:]
        for mode in PromptRewriteProviderMode.allCases where mode.supportsOAuthSignIn {
            next[mode.rawValue] = settings.hasPromptRewriteOAuthSession(for: mode)
        }
        oauthConnectedProviders = next
    }

    private func refreshPromptRewriteModels(showMessage: Bool) {
        let mode = settings.promptRewriteProviderMode
        let requestToken = UUID()
        let baseURL = settings.promptRewriteOpenAIBaseURL
        let apiKey = settings.promptRewriteOpenAIAPIKey

        promptRewriteModelRequestToken = requestToken
        promptRewriteModelsLoading = true
        if showMessage {
            promptRewriteModelStatusMessage = "Loading \(mode.displayName) models..."
        }

        Task {
            let result = await PromptRewriteModelCatalogService.shared.fetchModels(
                providerMode: mode,
                baseURL: baseURL,
                apiKey: apiKey
            )
            await MainActor.run {
                guard requestToken == promptRewriteModelRequestToken else { return }
                promptRewriteModelsLoading = false
                promptRewriteAvailableModels = result.models

                let currentModel = settings.promptRewriteOpenAIModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if currentModel.isEmpty, let firstModel = result.models.first {
                    settings.promptRewriteOpenAIModel = firstModel.id
                }

                if showMessage || result.source == .fallback {
                    promptRewriteModelStatusMessage = result.message
                } else if let resultMessage = result.message,
                          resultMessage.localizedCaseInsensitiveContains("loaded") {
                    promptRewriteModelStatusMessage = resultMessage
                }
            }
        }
    }

    private func presentOAuthCodePrompt(providerName: String, instructions: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 24))
        field.placeholderString = "Paste code or callback URL"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(providerName) OAuth Sign-In"
        alert.informativeText = "\(instructions)\nPaste the code (or callback URL) below."
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        return value
    }

    private func hydrateMemorySourcesFromSavedSettings() {
        let providerLookup = Dictionary(
            uniqueKeysWithValues: memoryIndexingSettingsService.detectedProviders().map { ($0.id, $0) }
        )
        detectedMemoryProviders = settings.memoryDetectedProviderIDs.map { providerID in
            providerLookup[providerID] ?? MemoryIndexingSettingsService.Provider(
                id: providerID,
                name: providerDisplayName(from: providerID),
                detail: "Previously detected provider.",
                sourceCount: 0
            )
        }

        detectedMemorySourceFolders = settings.memoryDetectedSourceFolderIDs.map { folderPath in
            let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            let fallbackName = folderURL.lastPathComponent.isEmpty ? folderPath : folderURL.lastPathComponent
            return MemoryIndexingSettingsService.SourceFolder(
                id: folderPath,
                name: fallbackName,
                path: folderPath,
                providerID: inferredProviderID(forFolderPath: folderPath)
            )
        }
    }

    private func resetOpenAIDeviceCodeState() {
        openAIDeviceUserCode = nil
        openAIDeviceVerificationURL = nil
    }

    private func copyToPasteboard(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func inferredProviderID(forFolderPath folderPath: String) -> String {
        let normalizedPath = folderPath.lowercased()
        let candidates = Array(
            Set(settings.memoryDetectedProviderIDs + detectedMemoryProviders.map(\.id))
        )
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            .sorted()

        if let directMatch = candidates.first(where: { normalizedPath.contains($0) }) {
            return directMatch
        }

        if normalizedPath.contains("codex") { return MemoryProviderKind.codex.rawValue }
        if normalizedPath.contains("opencode") { return MemoryProviderKind.opencode.rawValue }
        if normalizedPath.contains("claude") || normalizedPath.contains("claw") { return MemoryProviderKind.claude.rawValue }
        if normalizedPath.contains("copilot") { return MemoryProviderKind.copilot.rawValue }
        if normalizedPath.contains("cursor") { return MemoryProviderKind.cursor.rawValue }
        if normalizedPath.contains("kimi") { return MemoryProviderKind.kimi.rawValue }
        if normalizedPath.contains("gemini") || normalizedPath.contains("gmini") { return MemoryProviderKind.gemini.rawValue }
        if normalizedPath.contains("windsurf") { return MemoryProviderKind.windsurf.rawValue }
        if normalizedPath.contains("codeium") { return MemoryProviderKind.codeium.rawValue }

        return MemoryProviderKind.unknown.rawValue
    }

    private func providerDisplayName(from providerID: String) -> String {
        providerID
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                let first = token.prefix(1).uppercased()
                let remainder = String(token.dropFirst())
                return first + remainder
            }
            .joined(separator: " ")
    }

    private var promptRewriteModelPickerOptions: [PromptRewriteModelOption] {
        let currentModel = settings.promptRewriteOpenAIModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var options = promptRewriteAvailableModels
        if !currentModel.isEmpty,
           !options.contains(where: { option in
               option.id.caseInsensitiveCompare(currentModel) == .orderedSame
           }) {
            options.insert(
                PromptRewriteModelOption(
                    id: currentModel,
                    displayName: "Current: \(currentModel)"
                ),
                at: 0
            )
        }
        return options
    }

    private var filteredMemoryProviders: [MemoryIndexingSettingsService.Provider] {
        var providers = detectedMemoryProviders
        if memoryShowSelectedProvidersOnly {
            providers = providers.filter { provider in
                settings.isMemoryProviderEnabled(provider.id)
            }
        }

        let query = normalizedMemoryFilter(memoryProviderFilterQuery)
        guard !query.isEmpty else { return providers }
        return providers.filter { provider in
            matchesMemoryFilter(query, in: provider.name)
                || matchesMemoryFilter(query, in: provider.detail)
                || matchesMemoryFilter(query, in: provider.id)
        }
    }

    private var filteredMemorySourceFolders: [MemoryIndexingSettingsService.SourceFolder] {
        var folders = detectedMemorySourceFolders
        if memoryFoldersOnlyEnabledProviders {
            folders = folders.filter { folder in
                settings.isMemoryProviderEnabled(folder.providerID)
            }
        }
        if memoryShowSelectedFoldersOnly {
            folders = folders.filter { folder in
                settings.isMemorySourceFolderEnabled(folder.id)
            }
        }

        let query = normalizedMemoryFilter(memoryFolderFilterQuery)
        guard !query.isEmpty else { return folders }
        return folders.filter { folder in
            matchesMemoryFilter(query, in: folder.name)
                || matchesMemoryFilter(query, in: folder.path)
                || matchesMemoryFilter(query, in: providerDisplayName(from: folder.providerID))
                || matchesMemoryFilter(query, in: folder.providerID)
        }
    }

    private var memoryBrowserProviderOptions: [MemoryIndexingSettingsService.Provider] {
        detectedMemoryProviders.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var memoryBrowserFolderOptions: [MemoryIndexingSettingsService.SourceFolder] {
        let providerID = normalizedMemoryBrowserProviderID
        return detectedMemorySourceFolders
            .filter { folder in
                guard let providerID else { return true }
                return folder.providerID == providerID
            }
            .sorted { lhs, rhs in
                if lhs.providerID != rhs.providerID {
                    return lhs.providerID.localizedCaseInsensitiveCompare(rhs.providerID) == .orderedAscending
                }
                if lhs.name != rhs.name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
    }

    private var normalizedMemoryBrowserProviderID: String? {
        let trimmedProviderID = memoryBrowserSelectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty, trimmedProviderID != "all" else {
            return nil
        }
        return trimmedProviderID
    }

    private var normalizedMemoryBrowserFolderID: String? {
        let trimmedFolderID = memoryBrowserSelectedFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolderID.isEmpty, trimmedFolderID != "all" else {
            return nil
        }
        return trimmedFolderID
    }

    private func normalizeMemoryBrowserSelections() {
        let providerIDs = Set(memoryBrowserProviderOptions.map(\.id))
        let selectedProviderID = memoryBrowserSelectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedProviderID != "all", !providerIDs.contains(selectedProviderID) {
            memoryBrowserSelectedProviderID = "all"
        }

        let folderIDs = Set(memoryBrowserFolderOptions.map(\.id))
        let selectedFolderID = memoryBrowserSelectedFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedFolderID != "all", !folderIDs.contains(selectedFolderID) {
            memoryBrowserSelectedFolderID = "all"
        }
    }

    private func refreshMemoryBrowser() {
        let entries = memoryIndexingSettingsService.browseIndexedMemories(
            query: memoryBrowserQuery,
            providerID: normalizedMemoryBrowserProviderID,
            sourceFolderID: normalizedMemoryBrowserFolderID,
            includePlanContent: memoryBrowserIncludePlanContent,
            limit: 200
        )
        if memoryBrowserHighSignalOnly {
            memoryBrowserEntries = entries.filter(isHighSignalMemoryEntry)
        } else {
            memoryBrowserEntries = entries
        }

        if let selectedMemoryBrowserEntry,
           let updatedSelection = memoryBrowserEntries.first(where: { $0.id == selectedMemoryBrowserEntry.id }) {
            self.selectedMemoryBrowserEntry = updatedSelection
        } else {
            selectedMemoryBrowserEntry = memoryBrowserEntries.first
        }
    }

    private func selectMemoryBrowserEntry(_ entry: MemoryIndexedEntry) {
        selectedMemoryBrowserEntry = entry
        memoryInspectionExplanation = nil
        memoryInspectionStatusMessage = nil
    }

    private func explainMemoryEntryWithAI(_ entry: MemoryIndexedEntry) {
        guard !isMemoryInspectionBusy else { return }
        isMemoryInspectionBusy = true
        memoryInspectionStatusMessage = "Asking \(settings.promptRewriteProviderMode.displayName) to explain this memory..."
        memoryInspectionExplanation = nil

        Task {
            let result = await MemoryEntryExplanationService.shared.explain(entry: entry)
            await MainActor.run {
                isMemoryInspectionBusy = false
                switch result {
                case .success(let explanation):
                    memoryInspectionStatusMessage = "AI explanation ready."
                    memoryInspectionExplanation = explanation
                case .failure(let message):
                    memoryInspectionStatusMessage = message
                    memoryInspectionExplanation = nil
                }
            }
        }
    }

    private func isHighSignalMemoryEntry(_ entry: MemoryIndexedEntry) -> Bool {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if title == "workspace" || title == "storage" || title == "state" {
            return false
        }

        let detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix("{") && detail.hasSuffix("}") {
            if !detail.contains("->"),
               !detail.localizedCaseInsensitiveContains("prompt"),
               !detail.localizedCaseInsensitiveContains("rewrite"),
               !detail.localizedCaseInsensitiveContains("response") {
                return false
            }
        }

        let combined = "\(entry.summary) \(entry.detail)"
        let alphaWords = combined.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains(where: \.isLetter)
        }
        return alphaWords.count >= 5
    }

    private func setMemoryProvidersEnabled(_ providers: [MemoryIndexingSettingsService.Provider], enabled: Bool) {
        for provider in providers {
            settings.setMemoryProviderEnabled(provider.id, enabled: enabled)
        }
    }

    private func setMemorySourceFoldersEnabled(_ folders: [MemoryIndexingSettingsService.SourceFolder], enabled: Bool) {
        for folder in folders {
            settings.setMemorySourceFolderEnabled(folder.id, enabled: enabled)
        }
    }

    private func normalizedMemoryFilter(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesMemoryFilter(_ normalizedQuery: String, in value: String) -> Bool {
        value.lowercased().contains(normalizedQuery)
    }

    private func rescanMemorySources(showMessage: Bool) {
        let result = memoryIndexingSettingsService.rescan(
            enabledProviderIDs: settings.memoryEnabledProviderIDs,
            enabledSourceFolderIDs: settings.memoryEnabledSourceFolderIDs,
            runIndexing: settings.memoryIndexingEnabled
        )
        detectedMemoryProviders = result.providers
        detectedMemorySourceFolders = result.sourceFolders

        settings.updateDetectedMemoryProviders(result.providers.map(\.id))
        settings.updateDetectedMemorySourceFolders(result.sourceFolders.map(\.id))
        normalizeMemoryBrowserSelections()
        refreshMemoryBrowser()

        if result.indexQueued {
            isMemoryIndexingInProgress = true
            memoryIndexingProgressSummary = "Preparing indexing run..."
            memoryIndexingProgressDetail = nil
            guard showMessage else { return }
            memoryActionMessage = "Rescan finished. Found \(result.providers.count) providers and \(result.sourceFolders.count) folders. Indexing started in background."
        } else if showMessage {
            memoryIndexingProgressSummary = nil
            memoryIndexingProgressDetail = nil
            memoryActionMessage = "Rescan finished. Found \(result.providers.count) providers and \(result.sourceFolders.count) folders."
        }
    }

    private func handleMemoryIndexingProgress(_ notification: Notification) {
        isMemoryIndexingInProgress = true
        let userInfo = notification.userInfo ?? [:]
        let totalSources = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.totalSources] as? Int ?? 0
        let discoveredSources = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.discoveredSources] as? Int ?? 0
        let indexedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedFiles] as? Int ?? 0
        let skippedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.skippedFiles] as? Int ?? 0
        let indexedCards = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedCards] as? Int ?? 0
        let indexedLessons = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedLessons] as? Int ?? 0
        let indexedRewrites = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedRewriteSuggestions] as? Int ?? 0
        let failureCount = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.failureCount] as? Int ?? 0

        let currentSource = (
            userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.currentSourceDisplayName] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFilePath = (
            userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.currentFilePath] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var summaryParts: [String] = []
        if totalSources > 0 {
            summaryParts.append("Sources \(min(discoveredSources, totalSources))/\(totalSources)")
        }
        summaryParts.append("Files \(indexedFiles) indexed")
        if skippedFiles > 0 {
            summaryParts.append("\(skippedFiles) skipped")
        }
        summaryParts.append("Cards \(indexedCards)")
        if indexedLessons > 0 || indexedRewrites > 0 {
            summaryParts.append("Lessons \(indexedLessons)")
            summaryParts.append("Rewrites \(indexedRewrites)")
        }
        if failureCount > 0 {
            summaryParts.append("Issues \(failureCount)")
        }
        memoryIndexingProgressSummary = summaryParts.joined(separator: " • ")

        if let currentSource, !currentSource.isEmpty {
            if let currentFilePath, !currentFilePath.isEmpty {
                memoryIndexingProgressDetail = "\(currentSource) • \(currentFilePath)"
            } else {
                memoryIndexingProgressDetail = currentSource
            }
        } else {
            memoryIndexingProgressDetail = nil
        }
    }

    private func handleMemoryIndexingCompletion(_ notification: Notification) {
        isMemoryIndexingInProgress = false
        memoryIndexingProgressSummary = nil
        memoryIndexingProgressDetail = nil
        let userInfo = notification.userInfo ?? [:]
        let isRebuild = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.rebuild] as? Bool ?? false
        let indexedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedFiles] as? Int ?? 0
        let skippedFiles = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.skippedFiles] as? Int ?? 0
        let indexedCards = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedCards] as? Int ?? 0
        let indexedRewrites = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.indexedRewriteSuggestions] as? Int ?? 0
        let failureCount = userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.failureCount] as? Int ?? 0
        let firstFailure = (
            userInfo[MemoryIndexingSettingsService.IndexingNotificationUserInfoKey.firstFailure] as? String
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let actionLabel = isRebuild ? "Rebuild" : "Indexing"
        if failureCount > 0 {
            if let firstFailure, !firstFailure.isEmpty {
                let truncatedFailure = firstFailure.count > 120 ? String(firstFailure.prefix(120)) + "..." : firstFailure
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards. First issue: \(truncatedFailure)"
            } else {
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards."
            }
            refreshMemoryBrowser()
            return
        }

        memoryActionMessage = "\(actionLabel) finished. Indexed \(indexedFiles) files, skipped \(skippedFiles), produced \(indexedCards) cards, and generated \(indexedRewrites) rewrite suggestion(s)."
        refreshMemoryBrowser()
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor).opacity(0.86),
                            Color(nsColor: .windowBackgroundColor).opacity(0.76)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: tint.opacity(0.08), radius: 10, x: 0, y: 8)
    }
}
