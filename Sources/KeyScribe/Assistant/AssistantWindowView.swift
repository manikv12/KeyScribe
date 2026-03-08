import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct AssistantTimelineActivityGroup: Identifiable, Equatable {
    let items: [AssistantTimelineItem]

    var id: String {
        let firstID = items.first?.id ?? UUID().uuidString
        let lastID = items.last?.id ?? firstID
        return "activity-group-\(firstID)-\(lastID)"
    }

    var activities: [AssistantActivityItem] {
        items.compactMap(\.activity)
    }

    var sortDate: Date {
        items.first?.sortDate ?? .distantPast
    }

    var lastUpdatedAt: Date {
        items.map(\.lastUpdatedAt).max() ?? sortDate
    }
}

enum AssistantTimelineRenderItem: Identifiable, Equatable {
    case timeline(AssistantTimelineItem)
    case activityGroup(AssistantTimelineActivityGroup)

    var id: String {
        switch self {
        case .timeline(let item):
            return item.id
        case .activityGroup(let group):
            return group.id
        }
    }

    var lastUpdatedAt: Date {
        switch self {
        case .timeline(let item):
            return item.lastUpdatedAt
        case .activityGroup(let group):
            return group.lastUpdatedAt
        }
    }
}

func buildAssistantTimelineRenderItems(from items: [AssistantTimelineItem]) -> [AssistantTimelineRenderItem] {
    var renderItems: [AssistantTimelineRenderItem] = []
    var activityBuffer: [AssistantTimelineItem] = []

    func flushActivityBuffer() {
        guard !activityBuffer.isEmpty else { return }
        if activityBuffer.count == 1, let single = activityBuffer.first {
            renderItems.append(.timeline(single))
        } else {
            renderItems.append(.activityGroup(AssistantTimelineActivityGroup(items: activityBuffer)))
        }
        activityBuffer.removeAll(keepingCapacity: true)
    }

    for item in items {
        if item.kind == .activity, item.activity != nil {
            activityBuffer.append(item)
        } else {
            flushActivityBuffer()
            renderItems.append(.timeline(item))
        }
    }

    flushActivityBuffer()
    return renderItems
}

func assistantTimelineVisibleWindow(
    from items: [AssistantTimelineRenderItem],
    visibleLimit: Int
) -> [AssistantTimelineRenderItem] {
    guard !items.isEmpty else { return [] }

    let normalizedLimit = max(1, visibleLimit)
    guard items.count > normalizedLimit else { return items }
    return Array(items.suffix(normalizedLimit))
}

func assistantTimelineNextVisibleLimit(
    currentLimit: Int,
    totalCount: Int,
    batchSize: Int
) -> Int {
    guard totalCount > 0 else { return 0 }

    let normalizedCurrent = max(0, currentLimit)
    let normalizedBatch = max(1, batchSize)
    return min(totalCount, max(1, normalizedCurrent + normalizedBatch))
}

private func assistantTimelineSessionIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines),
          !lhs.isEmpty,
          !rhs.isEmpty else {
        return false
    }

    return lhs.caseInsensitiveCompare(rhs) == .orderedSame
}

struct AssistantWindowView: View {
    private static let initialVisibleHistoryLimit = 48
    private static let historyBatchSize = 24
    private static let nearBottomThreshold: CGFloat = 80
    private static let loadOlderThreshold: CGFloat = 140

    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var assistant: AssistantStore

    @State private var isRefreshing = false
    @State private var toolCallsExpanded = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var pendingDeleteSession: AssistantSessionSummary?
    @State private var showingDeleteAllConfirmation = false
    @State private var showSessionInstructions = false
    @State private var userHasScrolledUp = false
    @State private var visibleHistoryLimit = Self.initialVisibleHistoryLimit
    @State private var chatViewportHeight: CGFloat = 0
    @State private var isLoadingOlderHistory = false
    @State private var previewAttachment: AssistantAttachment?
    @AppStorage("assistantRuntimeExpanded") private var isRuntimeExpanded = true

    /// Uses the pre-computed render items from AssistantStore (rebuilt only when
    /// timelineItems changes, not on every @Published update).
    private var allRenderItems: [AssistantTimelineRenderItem] {
        assistant.cachedRenderItems
    }

    private var visibleRenderItems: [AssistantTimelineRenderItem] {
        assistantTimelineVisibleWindow(
            from: allRenderItems,
            visibleLimit: visibleHistoryLimit
        )
    }

    private var hiddenRenderItemCount: Int {
        max(0, allRenderItems.count - visibleRenderItems.count)
    }

    private var timelineLastUpdatedAt: Date {
        allRenderItems.last?.lastUpdatedAt ?? .distantPast
    }

    private var isAgentBusy: Bool {
        let phase = assistant.hudState.phase
        return phase == .acting || phase == .thinking || phase == .streaming
    }

    private var isVoiceCapturing: Bool {
        assistant.hudState.phase == .listening
    }

    private var canChat: Bool {
        assistant.isRuntimeReadyForConversation
    }

    private var canStartConversation: Bool {
        settings.assistantBetaEnabled && assistant.canStartConversation
    }

    private var composerPlaceholder: String {
        if !settings.assistantBetaEnabled {
            return "Enable assistant in Settings to chat."
        }
        if assistant.isLoadingModels {
            return "Loading models..."
        }
        if assistant.selectedModel == nil {
            return assistant.visibleModels.isEmpty
                ? "Models will appear here when Codex is ready."
                : "Select a model to start chatting..."
        }
        return "Message assistant..."
    }

    private var emptyStateMessage: String {
        if !settings.assistantBetaEnabled {
            return "Enable the assistant in Settings, then come back here."
        }
        if !canChat {
            return "Open Setup to connect to Codex, then come back to chat."
        }
        return assistant.conversationBlockedReason ?? "Send a message to start a conversation with the assistant."
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            chatDetail
        }
        .background(AppChromeBackground())
        .onAppear {
            Task { await refreshEverything(refreshPermissions: true) }
        }
        .alert(
            "Delete this KeyScribe session?",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteSession = nil
                    }
                }
            ),
            presenting: pendingDeleteSession
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await assistant.deleteSession(session.id) }
                pendingDeleteSession = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: { session in
            Text("This removes the saved KeyScribe thread “\(session.title)”.")
        }
        .alert("Delete all KeyScribe sessions?", isPresented: $showingDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                Task { await assistant.deleteAllOwnedSessions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved assistant sessions created in KeyScribe.")
        }
        .sheet(isPresented: $assistant.showBrowserProfilePicker) {
            BrowserProfilePickerSheet(
                onSelect: { profile in
                    assistant.selectBrowserProfile(profile)
                },
                onCancel: {
                    assistant.showBrowserProfilePicker = false
                }
            )
        }
        .sheet(isPresented: $assistant.showMemorySuggestionReview) {
            AssistantMemorySuggestionReviewSheet(assistant: assistant)
        }
        .popover(item: $previewAttachment, attachmentAnchor: .point(.center)) { attachment in
            if let nsImage = NSImage(data: attachment.data) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            previewAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 800, maxHeight: 600)
                        .padding([.bottom, .horizontal])
                }
                .frame(minWidth: 400, minHeight: 300)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconBadge(
                    symbol: "sparkles.rectangle.stack.fill",
                    tint: AppVisualTheme.accentTint,
                    size: 30,
                    symbolSize: 13,
                    isEmphasized: true
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text("Sessions")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(AppVisualTheme.mutedText)
                }
                Spacer()
                Button {
                    guard !isRefreshing else { return }
                    Task { await refreshEverything() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }

            Button {
                Task { await assistant.startNewSession() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New Session")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canStartConversation)

            runtimeCard

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if assistant.sessions.isEmpty {
                        Text("No sessions yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppVisualTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    } else {
                        ForEach(assistant.sessions) { session in
                            Button {
                                guard session.isLocalSession else { return }
                                Task { await assistant.openSession(session) }
                            } label: {
                                AssistantSessionRow(session: session, isSelected: assistant.selectedSessionID == session.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    presentRenameSessionPrompt(for: session)
                                } label: {
                                    Label("Rename Session", systemImage: "pencil")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    pendingDeleteSession = session
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .appScrollbars()

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 280, idealWidth: 300)
    }

    private var chatDetail: some View {
        VStack(spacing: 0) {
            // Thin top bar
            chatTopBar
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.22))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                }

            // Messages area — fills remaining space
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: ScrollTopOffsetKey.self,
                                    value: geo.frame(in: .named("chatScroll")).minY
                                )
                        }
                        .frame(height: 0)

                        if hiddenRenderItemCount > 0 {
                            historyWindowNotice
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                        }

                        if assistant.isTransitioningSession {
                            sessionTransitionPlaceholder
                        } else if visibleRenderItems.isEmpty {
                            chatEmptyState
                        } else {
                            LazyVStack(spacing: 6) {
                                ForEach(visibleRenderItems) { item in
                                    renderTimelineRow(item)
                                        .id(item.id)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                        }

                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: ScrollBottomOffsetKey.self,
                                    value: geo.frame(in: .named("chatScroll")).maxY
                                )
                        }
                        .frame(height: 0)
                        .id("bottomAnchor")
                    }
                    .coordinateSpace(name: "chatScroll")
                    .onPreferenceChange(ScrollTopOffsetKey.self) { topOffset in
                        loadOlderHistoryIfNeeded(topOffset: topOffset, with: proxy)
                    }
                    .onPreferenceChange(ScrollBottomOffsetKey.self) { bottomOffset in
                        updateUserScrollState(bottomOffset: bottomOffset)
                    }
                    .appScrollbars()

                    if userHasScrolledUp && !visibleRenderItems.isEmpty {
                        jumpToLatestButton {
                            jumpToLatestMessage(with: proxy)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 16)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ScrollViewportHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ScrollViewportHeightKey.self) { viewportHeight in
                    chatViewportHeight = viewportHeight
                }
                .onAppear {
                    resetVisibleHistoryWindow()
                    scrollToLatestMessage(with: proxy, animated: false)
                }
                .onChange(of: assistant.isTransitioningSession) { transitioning in
                    if transitioning {
                        // Reset scroll state immediately when session switch starts
                        resetVisibleHistoryWindow()
                    } else {
                        // Content is ready — jump to bottom without animation
                        DispatchQueue.main.async {
                            scrollToLatestMessage(with: proxy, animated: false)
                        }
                    }
                }
                .onChange(of: timelineLastUpdatedAt) { _ in
                    if !userHasScrolledUp {
                        scrollToLatestMessage(with: proxy)
                    }
                }
            }

            // Composer — pinned to bottom
            chatComposer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.18))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.09, blue: 0.11),
                    Color(red: 0.06, green: 0.06, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var chatTopBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runtimeDotColor)
                .frame(width: 7, height: 7)
                .shadow(color: runtimeDotColor.opacity(0.5), radius: 3)

            Text("Assistant")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text(assistant.selectedModelSummary)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(
                    assistant.selectedModel == nil
                        ? .white.opacity(0.35)
                        : .white.opacity(0.30)
                )

            Spacer()

            if assistant.runtimeHealth.availability == .connecting || assistant.runtimeHealth.availability == .active {
                AssistantStatusBadge(
                    title: assistant.hudState.shortLabel,
                    tint: badgeTint(for: assistant.runtimeHealth.availability)
                )
            }

            Button {
                showSessionInstructions.toggle()
            } label: {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        assistant.sessionInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .white.opacity(0.45)
                            : Color.green.opacity(0.8)
                    )
            }
            .buttonStyle(.plain)
            .help("Session instructions")
            .popover(isPresented: $showSessionInstructions, arrowEdge: .bottom) {
                SessionInstructionsPopover(instructions: $assistant.sessionInstructions)
            }

            Button {
                NotificationCenter.default.post(name: .keyScribeOpenAssistantSetup, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
            }
            .buttonStyle(.plain)
        }
    }

    private var historyWindowNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.message")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppVisualTheme.accentTint)

            Text("Older chat history is hidden for speed. Scroll up to load more.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func jumpToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("Latest")
                    .font(.system(size: 12, weight: .semibold))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.82))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(AppVisualTheme.accentTint.opacity(0.24), lineWidth: 0.8)
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .help("Jump to the newest message")
    }

    private func presentRenameSessionPrompt(for session: AssistantSessionSummary) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = session.title
        field.placeholderString = "Session name"
        field.selectText(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename Session"
        alert.informativeText = "Choose a friendly name for this thread. It will stay the same until you rename it again."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let proposedTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await assistant.renameSession(session.id, to: proposedTitle) }
    }

    private func copyMessageButton(text: String, helpText: String) -> some View {
        Button {
            copyAssistantTextToPasteboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.46))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func resetVisibleHistoryWindow() {
        visibleHistoryLimit = Self.initialVisibleHistoryLimit
        userHasScrolledUp = false
        isLoadingOlderHistory = false
    }

    private func updateUserScrollState(bottomOffset: CGFloat) {
        guard chatViewportHeight > 0 else { return }

        let isNearBottom =
            bottomOffset >= 0 &&
            bottomOffset <= chatViewportHeight + Self.nearBottomThreshold
        userHasScrolledUp = !isNearBottom
    }

    private func loadOlderHistoryIfNeeded(topOffset: CGFloat, with proxy: ScrollViewProxy) {
        guard hiddenRenderItemCount > 0,
              topOffset > -Self.loadOlderThreshold,
              !isLoadingOlderHistory,
              let anchorID = visibleRenderItems.first?.id else {
            return
        }

        let nextLimit = assistantTimelineNextVisibleLimit(
            currentLimit: visibleHistoryLimit,
            totalCount: allRenderItems.count,
            batchSize: Self.historyBatchSize
        )
        guard nextLimit > visibleHistoryLimit else { return }

        isLoadingOlderHistory = true
        visibleHistoryLimit = nextLimit
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .top)
            isLoadingOlderHistory = false
        }
    }

    private func jumpToLatestMessage(with proxy: ScrollViewProxy) {
        userHasScrolledUp = false
        scrollToLatestMessage(with: proxy)
    }

    private var chatEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppVisualTheme.accentTint, AppVisualTheme.accentTint.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("How can I help?")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text(emptyStateMessage)
                .font(.system(size: 14, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: 400)

            if !canChat {
                Button("Open Settings") {
                    NotificationCenter.default.post(name: .keyScribeOpenSettings, object: nil)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
    }

    private var sessionTransitionPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.5))
            Text("Loading session")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderTimelineRow(_ item: AssistantTimelineRenderItem) -> some View {
        switch item {
        case .timeline(let timelineItem):
            timelineRow(timelineItem)
        case .activityGroup(let group):
            timelineActivityGroupRow(group)
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: AssistantTimelineItem) -> some View {
        switch item.kind {
        case .userMessage:
            timelineUserBubble(text: item.text ?? "", timestamp: item.sortDate, imageAttachments: item.imageAttachments)

        case .assistantProgress:
            timelineAssistantRow(
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                tint: Color.white.opacity(0.30),
                isStreaming: item.isStreaming,
                compact: true,
                showsMemoryActions: false
            )

        case .assistantFinal:
            timelineAssistantRow(
                text: AssistantVisibleTextSanitizer.clean(item.text) ?? "",
                timestamp: item.sortDate,
                title: "Assistant",
                tint: Color(red: 0.55, green: 0.65, blue: 0.80),
                isStreaming: item.isStreaming,
                compact: false,
                showsMemoryActions: settings.assistantMemoryEnabled && !item.isStreaming
            )

        case .system:
            timelineAssistantRow(
                text: item.text ?? "",
                timestamp: item.sortDate,
                title: item.emphasis ? "Needs Attention" : "System",
                tint: item.emphasis ? .red : .white.opacity(0.5),
                isStreaming: false,
                compact: true,
                showsMemoryActions: false
            )

        case .activity:
            if let activity = item.activity {
                timelineActivityRow(activity)
            }

        case .permission:
            if let request = item.permissionRequest {
                let sessionStatus = assistant.sessions.first {
                    assistantTimelineSessionIDsMatch($0.id, request.sessionID)
                }?.status
                let cardState = assistantPermissionCardState(
                    for: request,
                    pendingRequest: assistant.pendingPermissionRequest,
                    sessionStatus: sessionStatus
                )
                HStack(alignment: .top, spacing: 0) {
                    permissionCard(request, state: cardState)
                    Spacer(minLength: 80)
                }
                .padding(.vertical, 2)
            }

        case .plan:
            if let plan = item.planText {
                HStack(alignment: .top, spacing: 0) {
                    proposedPlanCard(
                        plan,
                        isStreaming: item.isStreaming,
                        showsActions: assistant.proposedPlan == plan
                    )
                    Spacer(minLength: 80)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func timelineUserBubble(text: String, timestamp: Date, imageAttachments: [Data]? = nil) -> some View {
        HStack {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 6) {
                if let images = imageAttachments, !images.isEmpty {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, imageData in
                        if let nsImage = NSImage(data: imageData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 280, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        }
                    }
                }

                Text(verbatim: text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppVisualTheme.accentTint.opacity(0.18))
                    )
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    copyMessageButton(text: text, helpText: "Copy user message")

                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy Message") {
                copyAssistantTextToPasteboard(text)
            }
        }
    }

    private func timelineAssistantRow(
        text: String,
        timestamp: Date,
        title: String,
        tint: Color,
        isStreaming: Bool,
        compact: Bool,
        showsMemoryActions: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(0.7))
                .frame(width: 2.5, height: compact ? 16 : 22)
                .padding(.top, compact ? 4 : 6)

            VStack(alignment: .leading, spacing: compact ? 4 : 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(compact ? 0.42 : 0.60))

                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))

                    Spacer(minLength: 8)

                    copyMessageButton(
                        text: text,
                        helpText: title == "Assistant" ? "Copy assistant message" : "Copy message"
                    )
                }

                AssistantMarkdownText(
                    text: text,
                    role: .assistant,
                    isStreaming: isStreaming
                )
                .opacity(compact ? 0.88 : 1.0)
                .textSelection(.enabled)
            }

            Spacer(minLength: 24)
        }
        .padding(.vertical, compact ? 5 : 8)
        .contextMenu {
            Button("Copy Message") {
                copyAssistantTextToPasteboard(text)
            }
            if showsMemoryActions {
                Button("Save as Memory") {
                    assistant.saveAssistantMessageAsMemory(text)
                }
                Button("Mark as Unhelpful") {
                    assistant.markAssistantMessageUnhelpful(text)
                }
            }
        }
    }

    private func timelineActivityRow(_ activity: AssistantActivityItem) -> some View {
        let isExpanded = Binding(
            get: { expandedActivityIDs.contains(activity.id) },
            set: { expanded in
                if expanded {
                    expandedActivityIDs.insert(activity.id)
                } else {
                    expandedActivityIDs.remove(activity.id)
                }
            }
        )

        return HStack(alignment: .top, spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(activity.friendlySummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)

                    if let rawDetails = activity.rawDetails?.assistantNonEmpty {
                        Text(rawDetails)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.50))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: activityIconName(activity))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(activityIconTint(activity))
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(activity.friendlySummary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(activityStatusLabel(activity))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(activityStatusTint(activity))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(activityStatusTint(activity).opacity(0.12))
                            )

                        Text(activity.updatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .tint(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )

            Spacer(minLength: 80)
        }
        .padding(.vertical, 2)
    }

    private func timelineActivityGroupRow(_ group: AssistantTimelineActivityGroup) -> some View {
        let isExpanded = Binding(
            get: { expandedActivityIDs.contains(group.id) },
            set: { expanded in
                if expanded {
                    expandedActivityIDs.insert(group.id)
                } else {
                    expandedActivityIDs.remove(group.id)
                }
            }
        )

        return HStack(alignment: .top, spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(group.activities.enumerated()), id: \.element.id) { index, activity in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: activityIconName(activity))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(activityIconTint(activity))
                                    .frame(width: 14, height: 14)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.82))

                                    Text(activity.friendlySummary)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.56))
                                        .fixedSize(horizontal: false, vertical: true)

                                    if let rawDetails = activity.rawDetails?.assistantNonEmpty {
                                        Text(rawDetails)
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.46))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                }

                                Spacer(minLength: 16)
                            }

                            if index < group.activities.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 1)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: activityGroupIconName(group))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(activityGroupIconTint(group))
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(activityGroupTitle(group))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(activityGroupSummary(group))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(activityGroupStatusLabel(group))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(activityGroupStatusTint(group))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(activityGroupStatusTint(group).opacity(0.12))
                            )

                        Text(group.lastUpdatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .tint(.white.opacity(0.35))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )

            Spacer(minLength: 80)
        }
        .padding(.vertical, 2)
    }

    private var toolActivityStrip: some View {
        DisclosureGroup(isExpanded: $toolCallsExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !assistant.toolCalls.isEmpty {
                        toolActivitySection(title: "Active", calls: assistant.toolCalls)
                    }
                    if !assistant.recentToolCalls.isEmpty {
                        toolActivitySection(title: "Recent", calls: assistant.recentToolCalls)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 200)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text(toolActivitySummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .tint(.white.opacity(0.35))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private func toolActivitySection(title: String, calls: [AssistantToolCallState]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .textCase(.uppercase)

            ForEach(calls) { call in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName(for: call))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconTint(for: call))
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(call.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let detail = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }

                    Text(statusLabel(for: call))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint(for: call))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(statusTint(for: call).opacity(0.12))
                        )
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var toolActivitySummary: String {
        switch (assistant.toolCalls.count, assistant.recentToolCalls.count) {
        case let (active, recent) where active > 0 && recent > 0:
            return "\(active) active, \(recent) recent activities"
        case let (active, _) where active > 0:
            return "\(active) active tool\(active == 1 ? "" : "s")"
        case let (_, recent):
            return "\(recent) recent activit\(recent == 1 ? "y" : "ies")"
        }
    }

    private func iconName(for call: AssistantToolCallState) -> String {
        switch call.kind {
        case "webSearch":
            return "globe"
        case "commandExecution":
            return "terminal"
        case "mcpToolCall":
            return "shippingbox"
        case "browserAutomation":
            return "safari"
        case "fileChange":
            return "doc.badge.gearshape"
        case "reasoning":
            return "brain"
        case "dynamicToolCall":
            return "wrench.and.screwdriver"
        default:
            return "gearshape.fill"
        }
    }

    private func statusLabel(for call: AssistantToolCallState) -> String {
        let normalized = call.status.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
        return normalized.capitalized
    }

    private func iconTint(for call: AssistantToolCallState) -> Color {
        switch call.kind {
        case "webSearch":
            return .cyan.opacity(0.8)
        case "commandExecution":
            return .green.opacity(0.8)
        case "fileChange":
            return .orange.opacity(0.85)
        default:
            return .white.opacity(0.5)
        }
    }

    private func statusTint(for call: AssistantToolCallState) -> Color {
        switch call.status.lowercased() {
        case "completed":
            return Color.green.opacity(0.78)
        case "failed", "errored":
            return Color.red.opacity(0.78)
        default:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityIconName(_ activity: AssistantActivityItem) -> String {
        switch activity.kind {
        case .webSearch:
            return "globe"
        case .commandExecution:
            return "terminal"
        case .mcpToolCall:
            return "shippingbox"
        case .browserAutomation:
            return "safari"
        case .fileChange:
            return "doc.badge.gearshape"
        case .subagent:
            return "person.2.fill"
        case .reasoning:
            return "brain"
        case .dynamicToolCall:
            return "wrench.and.screwdriver"
        case .other:
            return "gearshape.fill"
        }
    }

    private func activityIconTint(_ activity: AssistantActivityItem) -> Color {
        switch activity.kind {
        case .webSearch:
            return .cyan.opacity(0.8)
        case .commandExecution:
            return .green.opacity(0.8)
        case .fileChange:
            return .orange.opacity(0.85)
        case .subagent:
            return .blue.opacity(0.8)
        default:
            return .white.opacity(0.5)
        }
    }

    private func activityStatusLabel(_ activity: AssistantActivityItem) -> String {
        activity.status.rawValue.capitalized
    }

    private func activityStatusTint(_ activity: AssistantActivityItem) -> Color {
        switch activity.status {
        case .completed:
            return Color.green.opacity(0.78)
        case .failed:
            return Color.red.opacity(0.78)
        case .interrupted:
            return Color.orange.opacity(0.78)
        case .waiting:
            return Color.yellow.opacity(0.78)
        case .pending, .running:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityGroupTitle(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard let first = activities.first else { return "Activity" }

        let uniqueKinds = Set(activities.map(\.kind))
        if uniqueKinds.count == 1 {
            switch first.kind {
            case .commandExecution:
                return activities.count == 1 ? "Command" : "Commands"
            case .fileChange:
                return activities.count == 1 ? "File Change" : "File Changes"
            case .webSearch:
                return activities.count == 1 ? "Search" : "Searches"
            case .browserAutomation:
                return activities.count == 1 ? "Browser Step" : "Browser Steps"
            case .subagent:
                return activities.count == 1 ? "Subagent Step" : "Subagent Steps"
            case .mcpToolCall, .dynamicToolCall:
                return activities.count == 1 ? "Tool Use" : "Tool Uses"
            case .reasoning:
                return "Reasoning"
            case .other:
                return activities.count == 1 ? "Activity" : "Activities"
            }
        }

        return "Activity"
    }

    private func activityGroupSummary(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard !activities.isEmpty else { return "No activity details available." }

        let counts = Dictionary(grouping: activities, by: \.kind).mapValues(\.count)
        var fragments: [String] = []

        if let commands = counts[.commandExecution], commands > 0 {
            fragments.append("\(commands) command\(commands == 1 ? "" : "s")")
        }
        if let fileChanges = counts[.fileChange], fileChanges > 0 {
            fragments.append("\(fileChanges) file change\(fileChanges == 1 ? "" : "s")")
        }
        if let searches = counts[.webSearch], searches > 0 {
            fragments.append("\(searches) search\(searches == 1 ? "" : "es")")
        }
        if let browserSteps = counts[.browserAutomation], browserSteps > 0 {
            fragments.append("\(browserSteps) browser step\(browserSteps == 1 ? "" : "s")")
        }
        if let subagentSteps = counts[.subagent], subagentSteps > 0 {
            fragments.append("\(subagentSteps) subagent step\(subagentSteps == 1 ? "" : "s")")
        }

        let toolUses = (counts[.mcpToolCall] ?? 0) + (counts[.dynamicToolCall] ?? 0)
        if toolUses > 0 {
            fragments.append("\(toolUses) tool use\(toolUses == 1 ? "" : "s")")
        }

        let otherCount = counts[.other] ?? 0
        if otherCount > 0 {
            fragments.append("\(otherCount) other activit\(otherCount == 1 ? "y" : "ies")")
        }

        if fragments.isEmpty {
            return "\(activities.count) activit\(activities.count == 1 ? "y" : "ies")"
        }

        return fragments.prefix(3).joined(separator: ", ")
    }

    private func activityGroupStatusLabel(_ group: AssistantTimelineActivityGroup) -> String {
        if group.activities.contains(where: { $0.status == .failed }) {
            return "Failed"
        }
        if group.activities.contains(where: { $0.status == .interrupted }) {
            return "Interrupted"
        }
        if group.activities.contains(where: { $0.status == .waiting }) {
            return "Waiting"
        }
        if group.activities.contains(where: { $0.status == .running || $0.status == .pending }) {
            return "Running"
        }
        return "Completed"
    }

    private func activityGroupStatusTint(_ group: AssistantTimelineActivityGroup) -> Color {
        switch activityGroupStatusLabel(group) {
        case "Completed":
            return Color.green.opacity(0.78)
        case "Failed":
            return Color.red.opacity(0.78)
        case "Interrupted":
            return Color.orange.opacity(0.82)
        default:
            return AppVisualTheme.accentTint.opacity(0.75)
        }
    }

    private func activityGroupIconName(_ group: AssistantTimelineActivityGroup) -> String {
        let activities = group.activities
        guard let first = activities.first else { return "square.stack.3d.up" }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconName(first) : "square.stack.3d.up"
    }

    private func activityGroupIconTint(_ group: AssistantTimelineActivityGroup) -> Color {
        let activities = group.activities
        guard let first = activities.first else { return .white.opacity(0.5) }
        let uniqueKinds = Set(activities.map(\.kind))
        return uniqueKinds.count == 1 ? activityIconTint(first) : .white.opacity(0.5)
    }

    private func sendCurrentPrompt() {
        userHasScrolledUp = false
        let prompt = assistant.promptDraft
        if let appDelegate = AppDelegate.shared {
            appDelegate.sendAssistantTypedPrompt(prompt)
        } else {
            Task { await assistant.sendPrompt(prompt) }
        }
    }

    private func toggleInteractionMode() {
        let allModes = AssistantInteractionMode.allCases
        guard let currentIndex = allModes.firstIndex(of: assistant.interactionMode) else {
            assistant.interactionMode = .conversational
            return
        }
        let nextIndex = allModes.index(after: currentIndex)
        assistant.interactionMode = nextIndex == allModes.endIndex ? allModes[allModes.startIndex] : allModes[nextIndex]
    }

    private var chatComposer: some View {
        VStack(spacing: 8) {
            // Main composer card
            VStack(spacing: 0) {
                // Text input area
                ZStack(alignment: .topLeading) {
                    if assistant.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(composerPlaceholder)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.32))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }

                    ComposerTextView(
                        text: $assistant.promptDraft,
                        isEnabled: canStartConversation,
                        onSubmit: { sendCurrentPrompt() },
                        onToggleMode: { toggleInteractionMode() },
                        onPasteAttachment: { attachment in
                            DispatchQueue.main.async {
                                assistant.attachments.append(attachment)
                            }
                        }
                    )
                    .frame(minHeight: 40, maxHeight: 120)
                }
                .onDrop(of: [.fileURL, .image, .png, .jpeg], isTargeted: nil) { providers in
                    handleDrop(providers)
                    return true
                }

                // Attachment preview strip
                if !assistant.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(assistant.attachments) { attachment in
                                attachmentChip(attachment)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }

                // Toolbar row: attach, mode, model, effort, context, send
                HStack(spacing: 8) {
                    // Attach file button
                    Button { openFilePicker() } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Attach files or images")
                    // Interaction mode indicator (toggle with Shift-Tab or click)
                    HStack(spacing: 3) {
                        Image(systemName: assistant.interactionMode.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(
                                assistant.interactionMode == .conversational
                                ? .blue
                                : (assistant.interactionMode == .plan ? .yellow : AppVisualTheme.accentTint)
                            )
                        Text(assistant.interactionMode.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .help("\(assistant.interactionMode.hint) (Shift-Tab to switch)")
                    .onTapGesture { toggleInteractionMode() }

                    // Model selector (inline, always visible)
                    Menu {
                        ForEach(assistant.visibleModels) { model in
                            Button {
                                assistant.chooseModel(model.id)
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                    if model.id == assistant.selectedModelID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppVisualTheme.accentTint)
                            Text(assistant.selectedModelSummary)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            if !assistant.visibleModels.isEmpty {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(assistant.visibleModels.isEmpty)

                    // Reasoning effort selector (filtered by selected model)
                    Menu {
                        ForEach(supportedEfforts, id: \.self) { effort in
                            Button {
                                assistant.reasoningEffort = effort
                            } label: {
                                HStack {
                                    Text(effort.label)
                                    if effort == assistant.reasoningEffort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(assistant.reasoningEffort.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(assistant.selectedModel == nil)

                    // Context window usage for current session
                    if assistant.tokenUsage.currentContextTokens > 0 {
                        Divider()
                            .frame(height: 14)
                            .padding(.horizontal, 2)

                        HStack(spacing: 4) {
                            if let fraction = assistant.tokenUsage.contextUsageFraction {
                                ContextUsageBar(fraction: fraction)
                                    .frame(width: 40, height: 4)
                            }
                            Text(assistant.tokenUsage.contextSummary)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle({
                                    if let f = assistant.tokenUsage.contextUsageFraction, f > 0.8 {
                                        return Color.red.opacity(0.7)
                                    }
                                    return Color.white.opacity(0.35)
                                }() as Color)
                        }
                    }

                    Spacer()

                    // Send / Stop button
                    if isVoiceCapturing {
                        Button {
                            NotificationCenter.default.post(name: .keyScribeStopAssistantVoiceCapture, object: nil)
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(Color.orange.opacity(0.8))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Stop listening")
                    } else if isAgentBusy {
                        Button {
                            Task { await assistant.cancelActiveTurn() }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(Color.red.opacity(0.7))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Stop the current turn")
                    } else {
                        Button { sendCurrentPrompt() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(
                                    Circle()
                                        .fill(
                                            canSendMessage
                                            ? AppVisualTheme.accentTint
                                            : Color.white.opacity(0.10)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSendMessage)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

                if let memoryStatusMessage = assistant.memoryStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !memoryStatusMessage.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.accentTint.opacity(0.85))
                        Text(memoryStatusMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                        Spacer()
                        if !assistant.pendingMemorySuggestions.isEmpty {
                            Button("Review") {
                                assistant.openMemorySuggestionReview()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.accentTint.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                if let blockedReason = assistant.conversationBlockedReason {
                    HStack(spacing: 6) {
                        Image(systemName: assistant.isLoadingModels ? "hourglass" : "exclamationmark.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppVisualTheme.accentTint.opacity(0.85))
                        Text(blockedReason)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )

            // Bottom row: browser profile
            HStack(spacing: 8) {
                Spacer()

                if settings.browserAutomationEnabled {
                    Button {
                        assistant.requestBrowserProfileSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 10))
                            if let profile = assistant.selectedBrowserProfile {
                                Text(profile.label)
                                    .font(.system(size: 10, weight: .medium))
                            } else {
                                Text("No browser")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .foregroundStyle(
                            assistant.selectedBrowserProfile != nil
                                ? Color.green.opacity(0.7)
                                : Color.white.opacity(0.35)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var canSendMessage: Bool {
        canStartConversation && !assistant.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var supportedEfforts: [AssistantReasoningEffort] {
        guard let selectedModel = assistant.selectedModel else {
            return AssistantReasoningEffort.allCases
        }
        let efforts = selectedModel.supportedReasoningEfforts.compactMap { AssistantReasoningEffort(rawValue: $0) }
        return efforts.isEmpty ? AssistantReasoningEffort.allCases : efforts
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isRuntimeExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(runtimeDotColor)
                            .frame(width: 7, height: 7)
                            .shadow(color: runtimeDotColor.opacity(0.5), radius: 3)
                        Text("Runtime")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.90))
                        Image(systemName: isRuntimeExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if isRuntimeExpanded {
                Text(assistant.runtimeHealth.summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                if let detail = assistant.runtimeHealth.detail, !detail.isEmpty,
                   !detail.lowercased().contains("failed to load rollout") {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(AppVisualTheme.mutedText)
                }
                if assistant.accountSnapshot.isLoggedIn {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppVisualTheme.accentTint.opacity(0.8))
                        Text(assistant.accountSnapshot.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                }
            }

            if !assistant.rateLimits.isEmpty {
                RateLimitsView(limits: assistant.rateLimits, isExpanded: isRuntimeExpanded)
            }

            if isRuntimeExpanded && !canChat {
                Button("Open Settings") {
                    NotificationCenter.default.post(name: .keyScribeOpenSettings, object: nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .appThemedSurface(cornerRadius: 12, tint: AppVisualTheme.accentTint, strokeOpacity: 0.12, tintOpacity: 0.03)
        .contentShape(Rectangle())
        .allowsHitTesting(!isRefreshing)
    }

    private var runtimeDotColor: Color {
        switch assistant.runtimeHealth.availability {
        case .ready, .active: return .green
        case .checking, .connecting: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private func permissionCard(_ request: AssistantPermissionRequest, state: AssistantPermissionCardState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.cardTitle)
                    .font(.headline)
                Spacer()
                AssistantStatusBadge(title: state.badgeTitle, tint: permissionBadgeTint(for: state))
            }

            Text(request.toolTitle)
                .font(.callout.weight(.semibold))
            if let rationale = request.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }

            switch state {
            case .waitingForApproval, .waitingForInput:
                ForEach(request.options) { option in
                    if option.isDefault {
                        Button(option.title) {
                            Task { await assistant.resolvePermission(optionID: option.id) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(option.title) {
                            Task { await assistant.resolvePermission(optionID: option.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let toolKind = request.toolKind, !toolKind.isEmpty {
                    Button("Always Allow") {
                        assistant.alwaysAllowToolKind(toolKind)
                        let sessionOption = request.options.first(where: { $0.id == "acceptForSession" })
                            ?? request.options.first(where: { $0.isDefault })
                        if let optionID = sessionOption?.id {
                            Task { await assistant.resolvePermission(optionID: optionID) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Button("Cancel Request") {
                    Task { await assistant.cancelPermissionRequest() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            case .completed:
                Text("This request is part of the session history. The task finished after it.")
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)

            case .notActive:
                Text("This request is no longer active in the live session.")
                    .font(.caption)
                    .foregroundStyle(AppVisualTheme.mutedText)
            }
        }
        .padding(16)
        .appThemedSurface(
            cornerRadius: 16,
            tint: permissionSurfaceTint(for: state),
            strokeOpacity: 0.16,
            tintOpacity: 0.045
        )
    }

    private func permissionBadgeTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return .green.opacity(0.78)
        case .notActive:
            return .white.opacity(0.45)
        }
    }

    private func permissionSurfaceTint(for state: AssistantPermissionCardState) -> Color {
        switch state {
        case .waitingForApproval, .waitingForInput:
            return .orange
        case .completed:
            return .green
        case .notActive:
            return .white
        }
    }

    private func proposedPlanCard(_ plan: String, isStreaming: Bool, showsActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint)
                Text("Proposed Plan")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                if showsActions {
                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                AssistantMarkdownText(text: plan, role: .assistant, isStreaming: isStreaming)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            if plan.count > 400 {
                Text("Scroll to view the full plan")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
            }

                if showsActions {
                    HStack(spacing: 10) {
                        Button {
                            Task { await assistant.executePlan() }
                        } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Execute Plan")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppVisualTheme.accentTint)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(assistant.hasActiveTurn)
                    .opacity(assistant.hasActiveTurn ? 0.55 : 1.0)

                    Button {
                        assistant.dismissPlan()
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                if assistant.hasActiveTurn {
                    Text("Wait for the plan to finish before executing it.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(14)
        .appThemedSurface(cornerRadius: 14, tint: AppVisualTheme.accentTint, strokeOpacity: 0.2, tintOpacity: 0.04)
    }

    private func badgeTint(for availability: AssistantRuntimeAvailability) -> Color {
        switch availability {
        case .ready, .active:
            return .green
        case .checking, .connecting:
            return AppVisualTheme.accentTint
        case .installRequired, .loginRequired:
            return .orange
        case .failed:
            return .red
        case .idle, .unavailable:
            return .secondary
        }
    }

    private func refreshEverything(refreshPermissions: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let permissions = refreshPermissions ? currentPermissionSnapshot() : assistant.permissions
        await assistant.refreshEnvironment(permissions: permissions)
        await assistant.refreshSessions()
    }

    private func currentPermissionSnapshot() -> AssistantPermissionSnapshot {
        let snapshot = PermissionCenter.snapshot(using: settings)
        return AssistantPermissionSnapshot(
            accessibility: snapshot.accessibilityGranted ? .granted : .missing,
            microphone: snapshot.microphoneGranted ? .granted : .missing,
            speechRecognition: snapshot.speechRecognitionGranted || !snapshot.speechRecognitionRequired ? .granted : .missing,
            appleEvents: .unknown,
            fullDiskAccess: .unknown
        )
    }

    private func scrollToLatestMessage(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard let lastID = visibleRenderItems.last?.id else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    // MARK: - Attachments

    private func attachmentChip(_ attachment: AssistantAttachment) -> some View {
        HStack(spacing: 4) {
            if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
                Button {
                    previewAttachment = attachment
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(attachment.filename)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Button {
                assistant.attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .plainText, .json, .yaml, .xml, .html, .sourceCode, .pdf, .data]
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                addAttachmentFromURL(url)
            }
        }
    }

    private func addAttachmentFromURL(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let filename = url.lastPathComponent
        let mimeType = mimeTypeForExtension(url.pathExtension.lowercased())
        let attachment = AssistantAttachment(filename: filename, data: data, mimeType: mimeType)
        DispatchQueue.main.async {
            assistant.attachments.append(attachment)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    addAttachmentFromURL(url)
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { item, _ in
                    guard let image = item as? NSImage,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    let attachment = AssistantAttachment(filename: "pasted-image.png", data: png, mimeType: "image/png")
                    DispatchQueue.main.async {
                        assistant.attachments.append(attachment)
                    }
                }
            }
        }
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "txt", "md", "log": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        case "xml": return "text/xml"
        case "yaml", "yml": return "text/yaml"
        case "swift", "py", "js", "ts", "rs", "go", "java", "c", "cpp", "h", "m", "rb", "sh", "zsh", "bash":
            return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

private struct AssistantMemorySuggestionReviewSheet: View {
    @ObservedObject var assistant: AssistantStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Suggestions")
                        .font(.system(size: 18, weight: .bold))
                    Text("Review these lessons before they become long-term assistant memory.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            if assistant.pendingMemorySuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No memory suggestions waiting for review.")
                        .font(.system(size: 13, weight: .semibold))
                    Text("When the assistant finds a useful rule or a repeated mistake, it will show up here for review.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(assistant.pendingMemorySuggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(suggestion.title)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(suggestion.kind.label)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(suggestion.memoryType.label)
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(AppVisualTheme.accentTint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(AppVisualTheme.accentTint.opacity(0.12))
                                        )
                                }

                                Text(suggestion.summary)
                                    .font(.system(size: 13, weight: .medium))

                                Text(suggestion.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let sourceExcerpt = suggestion.sourceExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !sourceExcerpt.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Source")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text(sourceExcerpt)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.white.opacity(0.04))
                                    )
                                }

                                HStack(spacing: 8) {
                                    Button("Ignore") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.ignoreMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Save Lesson") {
                                        let shouldClose = assistant.pendingMemorySuggestions.count == 1
                                        assistant.acceptMemorySuggestion(suggestion)
                                        if shouldClose {
                                            dismiss()
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                                    )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(AppChromeBackground())
    }
}

private struct AssistantSessionRow: View {
    let session: AssistantSessionSummary
    let isSelected: Bool

    private var badgeSymbol: String {
        switch session.source {
        case .cli:
            return "terminal.fill"
        case .vscode:
            return "chevron.left.forwardslash.chevron.right"
        case .appServer:
            return "sparkles"
        case .other:
            return "tray.full.fill"
        }
    }

    private var badgeTint: Color {
        switch session.source {
        case .cli:
            return AppVisualTheme.baseTint
        case .vscode:
            return AppVisualTheme.accentTint
        case .appServer:
            return .green
        case .other:
            return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppIconBadge(
                symbol: badgeSymbol,
                tint: badgeTint,
                size: 22,
                symbolSize: 10
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.88))
                    .lineLimit(1)
                Text(session.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(isSelected ? 0.55 : 0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AppVisualTheme.rowSelection.opacity(0.28) : Color.clear)
        )
    }
}

private struct AssistantStatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
    }
}

private struct AssistantChatBubble: View {
    let message: AssistantChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantRow
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)

            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppVisualTheme.accentTint.opacity(0.22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AppVisualTheme.accentTint.opacity(0.15), lineWidth: 0.6)
                            )
                    )
                    .textSelection(.enabled)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.vertical, 4)
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: roleIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(message.tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(message.tint.opacity(0.10))
                        .overlay(Circle().stroke(message.tint.opacity(0.12), lineWidth: 0.5))
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.roleLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }

                AssistantMarkdownText(text: message.text, role: message.role, isStreaming: message.isStreaming)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 24)
        }
        .padding(.vertical, 6)
    }

    private var roleIcon: String {
        switch message.role {
        case .assistant: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        case .permission: return "lock.shield.fill"
        case .system: return "server.rack"
        default: return "bubble.left.fill"
        }
    }
}

private struct AssistantMarkdownText: View {
    let text: String
    let role: AssistantTranscriptRole
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Markdown(text)
                .markdownTheme(assistantTheme)
                .markdownCodeSyntaxHighlighter(.plainText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isStreaming {
                StreamingCursor()
            }
        }
    }

    private var assistantTheme: MarkdownUI.Theme {
        .init()
            .text {
                ForegroundColor(.white.opacity(0.88))
                FontSize(14)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(18)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.90))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(15)
                        FontWeight(.semibold)
                        ForegroundColor(.white.opacity(0.88))
                    }
                    .markdownMargin(top: 8, bottom: 6)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(.white.opacity(0.92))
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(AppVisualTheme.accentTint)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(13)
                ForegroundColor(.white.opacity(0.82))
                BackgroundColor(Color(red: 0.10, green: 0.10, blue: 0.13))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(13)
                            ForegroundColor(.white.opacity(0.82))
                        }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                        )
                )
                .markdownMargin(top: 4, bottom: 4)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppVisualTheme.accentTint.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.white.opacity(0.7))
                            FontStyle(.italic)
                        }
                        .padding(.leading, 10)
                }
                .markdownMargin(top: 4, bottom: 4)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 8)
            }
    }
}

private struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(visible ? 0.7 : 0.0))
            .frame(width: 2, height: 16)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}

// MARK: - Session Instructions Popover

private struct SessionInstructionsPopover: View {
    @Binding var instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Session Instructions")
                    .font(.system(size: 13, weight: .semibold))
            }

            Text("These instructions apply only to this session. They are combined with your global instructions from Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $instructions)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor).opacity(0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.8)
                        )
                )

            if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text("Active for this session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        instructions = ""
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

@MainActor
private struct AssistantChatMessage: Identifiable {
    let id: UUID
    let role: AssistantTranscriptRole
    let text: String
    let timestamp: Date
    let emphasis: Bool
    let isStreaming: Bool

    var roleLabel: String {
        switch role {
        case .assistant: return "Assistant"
        case .user: return "You"
        case .permission: return "Permission"
        case .error: return "Error"
        case .status: return "Status"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    var tint: Color {
        switch role {
        case .assistant:
            return AppVisualTheme.accentTint
        case .user:
            return AppVisualTheme.baseTint
        case .permission:
            return .orange
        case .error:
            return .red
        case .status, .system, .tool:
            return Color(red: 0.42, green: 0.76, blue: 0.95)
        }
    }

    var alignment: HorizontalAlignment {
        switch role {
        case .user:
            return .trailing
        default:
            return .leading
        }
    }

    var fillOpacity: Double {
        switch role {
        case .user:
            return 0.16
        case .assistant:
            return 0.11
        case .error:
            return 0.13
        default:
            return 0.09
        }
    }

    var strokeOpacity: Double {
        emphasis ? 0.34 : 0.22
    }

    static func grouped(from entries: [AssistantTranscriptEntry]) -> [AssistantChatMessage] {
        entries.compactMap { entry in
            guard let text = entry.text.assistantNonEmpty else { return nil }
            return AssistantChatMessage(
                id: entry.id,
                role: entry.role,
                text: text,
                timestamp: entry.createdAt,
                emphasis: entry.emphasis,
                isStreaming: entry.isStreaming
            )
        }
    }
}

enum AssistantTextRenderingStyle {
    case plain
    case markdown
}

enum AssistantTextRenderingPolicy {
    static func style(for text: String, isStreaming: Bool) -> AssistantTextRenderingStyle {
        if isStreaming {
            return .plain
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        if normalized.contains("```") || normalized.contains("`") {
            return .markdown
        }

        if normalized.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil {
            return .markdown
        }

        if normalized.range(of: #"(^|[\s])(\*\*|__|~~)[^\n]+(\*\*|__|~~)(?=$|[\s])"#, options: [.regularExpression]) != nil {
            return .markdown
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#")
                || line.hasPrefix("> ")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("+ ")
                || line.hasPrefix("|") {
                return .markdown
            }

            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return .markdown
            }
        }

        return .plain
    }
}

enum AssistantVisibleTextSanitizer {
    static func clean(_ rawValue: String?) -> String? {
        guard var text = rawValue?.replacingOccurrences(of: "\r\n", with: "\n").assistantNonEmpty else {
            return nil
        }

        text = removingAnalysisBlocks(from: text)

        if let closingRange = text.range(of: "</analysis>", options: [.caseInsensitive]) {
            let prefix = text[..<closingRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = text[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            text = preferredVisibleSlice(prefix: String(prefix), suffix: String(suffix))
        }

        if let openingRange = text.range(of: "<analysis>", options: [.caseInsensitive]) {
            text = String(text[..<openingRange.lowerBound])
        }

        text = text
            .replacingOccurrences(of: "<analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</analysis>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "<proposed_plan>", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "</proposed_plan>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.assistantNonEmpty
    }

    private static func removingAnalysisBlocks(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<analysis\b[^>]*>[\s\S]*?</analysis>"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredVisibleSlice(prefix: String, suffix: String) -> String {
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)

        if looksLikeInternalScratchpad(normalizedSuffix), !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        if !normalizedSuffix.isEmpty && normalizedPrefix.isEmpty {
            return normalizedSuffix
        }

        if !normalizedPrefix.isEmpty {
            return normalizedPrefix
        }

        return normalizedSuffix
    }

    private static func looksLikeInternalScratchpad(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "need ",
            "let's ",
            "wait:",
            "maybe ",
            "we should ",
            "i should ",
            "final answer",
            "output final",
            "plan-only",
            "ensure "
        ]
        return markers.contains(where: lowered.contains)
    }
}

private struct AssistantMarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case codeBlock(language: String?, code: String)
    }

    let id: Int
    let kind: Kind

    static func parse(from text: String) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var currentMarkdown: [String] = []
        var insideCodeBlock = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var nextIndex = 0

        func flushMarkdown() {
            let value = currentMarkdown.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .markdown(value)))
                nextIndex += 1
            }
            currentMarkdown.removeAll()
        }

        func flushCodeBlock() {
            let value = codeLines.joined(separator: "\n")
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(AssistantMarkdownSegment(id: nextIndex, kind: .codeBlock(language: codeLanguage, code: value)))
                nextIndex += 1
            }
            codeLines.removeAll()
            codeLanguage = nil
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if insideCodeBlock {
                    flushCodeBlock()
                    insideCodeBlock = false
                } else {
                    flushMarkdown()
                    insideCodeBlock = true
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if insideCodeBlock {
                codeLines.append(line)
            } else {
                currentMarkdown.append(line)
            }
        }

        if insideCodeBlock {
            flushCodeBlock()
        } else {
            flushMarkdown()
        }

        if segments.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                segments.append(AssistantMarkdownSegment(id: 0, kind: .markdown(fallback)))
            }
        }

        return segments
    }
}

// MARK: - Composer Text View (Enter to send, Shift+Enter for newline)

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onSubmit: () -> Void
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmittableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.onSubmit = onSubmit
        textView.onToggleMode = onToggleMode
        textView.onPasteAttachment = onPasteAttachment
        AssistantComposerBridge.shared.register(textView: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        AssistantComposerBridge.shared.register(textView: textView)
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class SubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onPasteAttachment: ((AssistantAttachment) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        
        // Check for images
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let firstImage = images.first {
            if let tiff = firstImage.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let attachment = AssistantAttachment(filename: "pasted-image.png", data: png, mimeType: "image/png")
                onPasteAttachment?(attachment)
                return
            }
        }
        
        // Check for file URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext),
                   let data = try? Data(contentsOf: url) {
                    let attachment = AssistantAttachment(filename: url.lastPathComponent, data: data, mimeType: "image/\(ext == "jpg" ? "jpeg" : ext)")
                    onPasteAttachment?(attachment)
                    return
                }
            }
        }
        
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShift = event.modifierFlags.contains(.shift)
        let isTab = event.keyCode == 48

        if isReturn && !isShift {
            onSubmit?()
            return
        }
        if isTab && isShift {
            onToggleMode?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Context Usage Bar

private struct ContextUsageBar: View {
    let fraction: Double

    private var barColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .orange }
        return AppVisualTheme.accentTint
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(fraction))
            }
        }
    }
}

// MARK: - Rate Limits View

private struct RateLimitsView: View {
    let limits: AccountRateLimits
    var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
            if let primary = limits.primary {
                rateLimitRow(window: primary, label: primary.windowLabel.isEmpty ? "Usage" : primary.windowLabel)
            }
            if let secondary = limits.secondary {
                rateLimitRow(window: secondary, label: secondary.windowLabel.isEmpty ? "Limit" : secondary.windowLabel)
            }
        }
    }

    private func rateLimitRow(window: RateLimitWindow, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer()
                Text("\(window.usedPercent)% used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(window.usedPercent > 80 ? .red.opacity(0.8) : .white.opacity(0.45))
                if isExpanded, let resets = window.resetsInLabel {
                    Text("resets \(resets)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }
            ContextUsageBar(fraction: Double(window.usedPercent) / 100.0)
                .frame(height: isExpanded ? 3 : 2)
        }
        .help(!isExpanded && window.resetsInLabel != nil ? "Resets \(window.resetsInLabel!)" : "")
    }
}

// MARK: - Subagent Strip

private struct SubagentStrip: View {
    let subagents: [SubagentState]

    private var activeAgents: [SubagentState] {
        subagents.filter { $0.status.isActive }
    }

    private var completedCount: Int {
        subagents.filter { !$0.status.isActive }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint.opacity(0.8))
                Text("\(activeAgents.count) active agent\(activeAgents.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                if completedCount > 0 {
                    Text("· \(completedCount) done")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer()
            }

            ForEach(activeAgents) { agent in
                HStack(spacing: 6) {
                    Image(systemName: agent.status.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(agentTint(agent.status))
                    Text(agent.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                    if let prompt = agent.prompt?.prefix(50), !prompt.isEmpty {
                        Text(String(prompt))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.30))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(agent.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(agentTint(agent.status).opacity(0.7))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func agentTint(_ status: SubagentStatus) -> Color {
        switch status {
        case .spawning, .running: return .blue
        case .waiting: return .orange
        case .completed: return .green
        case .errored: return .red
        case .closed: return .gray
        }
    }
}

// MARK: - Scroll tracking

private struct ScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
