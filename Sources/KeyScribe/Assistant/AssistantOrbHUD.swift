import AppKit
import Combine
import MarkdownUI
import SwiftUI
import UserNotifications

// MARK: - Model

@MainActor
final class AssistantOrbHUDModel: ObservableObject {
    @Published var state: AssistantHUDState = .idle
    @Published var level: Float = 0
    @Published var interactionMode: AssistantInteractionMode = .conversational
    @Published var busySessionID: String?

    // Expansion state
    @Published var isExpanded = false
    @Published var isLoadingSessions = false
    @Published var sessions: [AssistantSessionSummary] = []
    @Published var selectedSessionID: String?
    @Published var messageText = ""
    @Published var shouldFocusTextField = false

    // Done detail popup
    @Published var showDoneDetail = false
    @Published private(set) var storedDoneDetailText: String?
    var doneDetailText: String? { storedDoneDetailText }

    // Live working detail popup
    @Published var showWorkingDetail = false
    @Published var workingToolActivity: [AssistantToolCallState] = []
    @Published var activeSessionSummary: AssistantSessionSummary?

    // Model selection
    @Published var availableModels: [AssistantModelOption] = []
    @Published var selectedModelSummary: String = ""

    // Voice recording
    @Published var isVoiceRecording = false

    // Permission request popup
    @Published var pendingPermissionRequest: AssistantPermissionRequest?

    // Callbacks wired by the manager
    var onRefreshSessions: (() async -> Void)?
    var onSendMessage: ((String, String?) -> Void)?
    var onSessionSelected: ((AssistantSessionSummary) -> Void)?
    var onOpenSession: ((AssistantSessionSummary) -> Void)?
    var onNewSession: (() async -> Void)?
    var onChooseModel: ((String) -> Void)?
    var onStartVoiceRecording: (() -> Void)?
    var onStopVoiceRecording: (() -> Void)?
    var onResolvePermission: ((String) -> Void)?
    var onCancelPermission: (() -> Void)?
    var onAlwaysAllowPermission: ((String) -> Void)?

    func update(state: AssistantHUDState) {
        self.state = state

        switch state.phase {
        case .success:
            let trimmedDetail = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            storedDoneDetailText = trimmedDetail
            showDoneDetail = trimmedDetail != nil
            showWorkingDetail = false
        case .idle:
            // Keep the completion popup visible until the user closes it.
            showWorkingDetail = false
            break
        case .waitingForPermission, .failed:
            storedDoneDetailText = nil
            showDoneDetail = false
            showWorkingDetail = false
        case .listening, .thinking, .acting, .streaming:
            storedDoneDetailText = nil
            showDoneDetail = false
        }
    }

    var canPresentWorkingDetail: Bool {
        guard shouldOfferWorkingDetail(for: state.phase) else { return false }
        if state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil {
            return true
        }
        if !workingToolActivity.isEmpty {
            return true
        }
        if activeSessionSummary != nil {
            return true
        }
        return false
    }

    @discardableResult
    func presentWorkingDetailIfAvailable() -> Bool {
        guard canPresentWorkingDetail else { return false }
        showWorkingDetail = true
        return true
    }

    func dismissWorkingDetail() {
        showWorkingDetail = false
    }

    var workingSummaryText: String? {
        if let detail = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return detail
        }
        if let hudDetail = workingToolActivity.first?.hudDetail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return hudDetail
        }
        if let detail = workingToolActivity.first?.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return detail
        }
        if let session = activeSessionSummary {
            return session.detail.nonEmpty ?? session.cwd?.nonEmpty
        }
        return nil
    }

    var workingPopupTitle: String {
        switch state.phase {
        case .listening:
            return "LISTENING"
        case .thinking, .acting:
            return "WORKING NOW"
        case .streaming:
            return "WRITING NOW"
        case .waitingForPermission:
            return "ACTION NEEDED"
        case .idle, .success, .failed:
            return "LIVE STATUS"
        }
    }

    private func shouldOfferWorkingDetail(for phase: AssistantHUDPhase) -> Bool {
        switch phase {
        case .listening, .thinking, .acting, .streaming:
            return true
        case .idle, .waitingForPermission, .success, .failed:
            return false
        }
    }

    private func clearTransientPopupsForNewTurn() {
        if showDoneDetail {
            storedDoneDetailText = nil
            showDoneDetail = false
        }
        if showWorkingDetail {
            showWorkingDetail = false
        }
    }

    func dismissDoneDetail() {
        showDoneDetail = false
        storedDoneDetailText = nil
    }

    func updateLevel(_ level: Float) {
        self.level = max(0, min(1, level))
    }

    func expand() {
        isExpanded = true
        Task { await onRefreshSessions?() }
    }

    func collapse() {
        if isVoiceRecording {
            onStopVoiceRecording?()
            isVoiceRecording = false
        }
        isExpanded = false
        dismissDoneDetail()
        dismissWorkingDetail()
        shouldFocusTextField = false
        messageText = ""
    }

    func toggleExpanded() {
        if isExpanded { collapse() } else { expand() }
    }

    /// Display name for the session that will receive the message.
    var targetSessionName: String? {
        guard let sid = selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == sid })?.title.nonEmpty ?? "Selected session"
    }
}

// MARK: - Manager

private let kOrbPositionKey = "assistantOrbHUDPosition"

@MainActor
final class AssistantOrbHUDManager {
    private enum Layout {
        static let collapsedSize = NSSize(width: 140, height: 156)
        static let expandedSize = NSSize(width: 300, height: 480)
        static let doneDetailSize = NSSize(width: 340, height: 456)
    }

    private let model = AssistantOrbHUDModel()
    private let controller: AssistantStore
    private var panel: OrbHUDPanel?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?

    /// Saved orb origin (bottom-left of collapsed frame). `nil` = use default center position.
    private var savedOrigin: NSPoint?

    var isEnabled = true {
        didSet {
            if !isEnabled { hide() }
        }
    }

    private var autoDismissItem: DispatchWorkItem?

    init(controller: AssistantStore) {
        self.controller = controller

        // Restore saved position
        if let dict = UserDefaults.standard.dictionary(forKey: kOrbPositionKey),
           let x = dict["x"] as? Double, let y = dict["y"] as? Double {
            savedOrigin = NSPoint(x: x, y: y)
        }

        // HUD state from runtime
        controller.$hudState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.syncModelFromController()
                self?.update(state: state)
            }
            .store(in: &cancellables)

        controller.$interactionMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.model.interactionMode = mode
            }
            .store(in: &cancellables)

        controller.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                self?.model.sessions = sessions
                self?.syncModelFromController()
            }
            .store(in: &cancellables)

        controller.$selectedSessionID
            .receive(on: RunLoop.main)
            .sink { [weak self] selectedSessionID in
                self?.model.selectedSessionID = selectedSessionID
                self?.syncModelFromController()
            }
            .store(in: &cancellables)

        controller.$availableModels
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$selectedModelID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$toolCalls
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        controller.$recentToolCalls
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncModelFromController() }
            .store(in: &cancellables)

        // Resize panel when expansion toggles
        model.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in
                self?.handleExpansionChange(expanded)
            }
            .store(in: &cancellables)

        // Resize panel when done detail popup toggles
        model.$showDoneDetail
            .receive(on: RunLoop.main)
            .sink { [weak self] showing in
                self?.handleDoneDetailChange(showing)
            }
            .store(in: &cancellables)

        model.$showWorkingDetail
            .receive(on: RunLoop.main)
            .sink { [weak self] showing in
                self?.handleWorkingDetailChange(showing)
            }
            .store(in: &cancellables)

        // Wire model callbacks
        model.onRefreshSessions = { [weak self] in
            await self?.refreshSessionsForOrb()
        }

        model.onSendMessage = { [weak self] message, sessionID in
            self?.sendMessageFromOrb(message, sessionID: sessionID)
        }

        model.onSessionSelected = { [weak self] session in
            Task { @MainActor in
                await self?.controller.openSession(session)
            }
        }

        model.onOpenSession = { [weak self] session in
            Task { @MainActor in
                await self?.controller.openSession(session)
                self?.model.collapse()
                NotificationCenter.default.post(name: .keyScribeOpenAssistant, object: nil)
            }
        }

        model.onNewSession = { [weak self] in
            await self?.controller.startNewSession()
            await self?.refreshSessionsForOrb()
        }

        model.onChooseModel = { [weak self] modelID in
            self?.controller.chooseModel(modelID)
            self?.syncModelFromController()
        }

        model.onStartVoiceRecording = { [weak self] in
            self?.model.isVoiceRecording = true
            NotificationCenter.default.post(name: .keyScribeStartOrbVoiceCapture, object: nil)
        }

        model.onStopVoiceRecording = { [weak self] in
            self?.model.isVoiceRecording = false
            NotificationCenter.default.post(name: .keyScribeStopOrbVoiceCapture, object: nil)
        }

        model.onResolvePermission = { [weak self] optionID in
            guard let self else { return }
            Task { await self.controller.resolvePermission(optionID: optionID) }
        }

        model.onCancelPermission = { [weak self] in
            guard let self else { return }
            Task { await self.controller.cancelPermissionRequest() }
        }

        model.onAlwaysAllowPermission = { [weak self] toolKind in
            self?.controller.alwaysAllowToolKind(toolKind)
        }

        // Permission request from controller
        controller.$pendingPermissionRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                self?.model.pendingPermissionRequest = request
                self?.handlePermissionRequestChange(request)
            }
            .store(in: &cancellables)

        syncModelFromController()

        // Show the orb immediately on launch
        if isEnabled {
            show(state: .idle)
        }
    }

    // MARK: Public

    func show(state: AssistantHUDState) {
        if panel == nil { createPanel() }
        guard let panel else { return }
        model.update(state: displayState(for: state))
        if !panel.isVisible || panel.frame.size != targetSize {
            reposition()
        }
        panel.orderFrontRegardless()
    }

    func update(state: AssistantHUDState) {
        autoDismissItem?.cancel()
        autoDismissItem = nil

        guard isEnabled, shouldPresent(state) else {
            if !model.isExpanded { hide() }
            return
        }

        if state.phase == .success, let detail = state.detail, !detail.isEmpty, model.state.phase != .success {
            sendCompletionNotification(message: detail)
        }

        show(state: state)

        if state.phase == .failed && !model.isExpanded {
            let item = DispatchWorkItem { [weak self] in
                self?.resetToIdle()
            }
            autoDismissItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: item)
        }
    }

    func updateLevel(_ level: Float) {
        model.updateLevel(level)
    }

    func receiveVoiceTranscript(_ text: String) {
        model.isVoiceRecording = false
        model.messageText = text
        model.updateLevel(0)
    }

    func hide() {
        model.collapse()
        model.update(state: .idle)
        model.updateLevel(0)
        stopClickOutsideMonitor()
        panel?.orderOut(nil)
    }

    /// Resets the orb to idle appearance without hiding it.
    private func resetToIdle() {
        guard !model.isExpanded else { return }
        model.update(state: .idle)
        model.updateLevel(0)
    }

    // MARK: Private

    private func shouldPresent(_ state: AssistantHUDState) -> Bool {
        return true
    }

    private func createPanel() {
        let panel = OrbHUDPanel(
            contentRect: NSRect(origin: .zero, size: Layout.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.onPositionPersist = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.persistCollapsedOrigin(
                from: panel.frame.origin,
                isExpanded: self.model.isExpanded
            )
        }
        panel.contentViewController = NSHostingController(rootView: AssistantOrbHUDView(model: model))
        self.panel = panel
    }

    private var targetSize: NSSize {
        if model.isExpanded { return Layout.expandedSize }
        if model.showDoneDetail || model.showWorkingDetail || model.pendingPermissionRequest != nil {
            return Layout.doneDetailSize
        }
        return Layout.collapsedSize
    }

    private func reposition() {
        guard let panel else { return }
        let screen = screenForCurrentPlacement(panel: panel)
        guard let screen else { return }

        let size = targetSize
        let availableFrame = screen.visibleFrame

        let origin: NSPoint
        if let saved = savedOrigin {
            if model.isExpanded {
                // Keep the orb itself at the same user-placed spot when expanding.
                let orbCenterX = saved.x + Layout.collapsedSize.width / 2
                origin = NSPoint(
                    x: orbCenterX - size.width / 2,
                    y: saved.y + Layout.collapsedSize.height - size.height
                )
            } else {
                origin = saved
            }
        } else {
            // Default: center on screen near bottom.
            let x = availableFrame.midX - (size.width / 2)
            let y = availableFrame.minY + 36
            origin = NSPoint(x: x, y: y)
        }

        let clampedX = max(availableFrame.minX, min(origin.x, availableFrame.maxX - size.width))
        let clampedY = max(availableFrame.minY, min(origin.y, availableFrame.maxY - size.height))
        let frame = NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        CATransaction.commit()

        if savedOrigin == nil {
            persistCollapsedOrigin(from: frame.origin, isExpanded: model.isExpanded)
        }
    }

    private func handleDoneDetailChange(_ showing: Bool) {
        if !model.isExpanded {
            reposition()
        }
        if showing {
            if !model.isExpanded {
                startClickOutsideMonitor()
            }
        } else {
            if !model.isExpanded {
                stopClickOutsideMonitor()
            }
            // When the user dismisses the done detail, reset the orb to idle
            // so it doesn't stay stuck showing the "DONE" state.
            if model.state.phase == .success {
                resetToIdle()
            }
        }
    }

    private func handleWorkingDetailChange(_ showing: Bool) {
        if !model.isExpanded {
            reposition()
        }
        if showing {
            if !model.isExpanded {
                startClickOutsideMonitor()
            }
        } else if !model.isExpanded {
            stopClickOutsideMonitor()
        }
    }

    private func handlePermissionRequestChange(_ request: AssistantPermissionRequest?) {
        guard !model.isExpanded else { return }
        reposition()
        if request != nil {
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
            startClickOutsideMonitor()
        } else {
            stopClickOutsideMonitor()
        }
    }

    private func handleExpansionChange(_ expanded: Bool) {
        reposition()
        if expanded {
            panel?.allowsKeyStatus = true
            panel?.makeKeyAndOrderFront(nil)
            startClickOutsideMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.model.shouldFocusTextField = true
            }
        } else {
            model.shouldFocusTextField = false
            panel?.allowsKeyStatus = false
            stopClickOutsideMonitor()
        }
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.model.isExpanded || self.model.showDoneDetail || self.model.showWorkingDetail else { return }
                if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                if self.model.isExpanded {
                    self.model.collapse()
                } else if self.model.showDoneDetail {
                    self.model.dismissDoneDetail()
                } else {
                    self.model.dismissWorkingDetail()
                }
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func refreshSessionsForOrb() async {
        syncModelFromController()

        model.isLoadingSessions = model.sessions.isEmpty

        if controller.visibleModels.isEmpty {
            await controller.refreshEnvironment()
        }

        await controller.refreshSessions()
        syncModelFromController()
        model.isLoadingSessions = false
    }

    private func sendMessageFromOrb(_ message: String, sessionID: String?) {
        Task { @MainActor in
            if let sessionID {
                if let session = controller.sessions.first(where: { self.sessionIDsMatch($0.id, sessionID) }) {
                    await controller.openSession(session)
                } else {
                    controller.selectedSessionID = sessionID
                }
            }
            controller.interactionMode = model.interactionMode
            if controller.hasActiveTurn {
                await controller.cancelActiveTurn()
            }
            await controller.sendPrompt(message)
            await controller.refreshSessions()
            self.syncModelFromController()
        }
    }

    private func syncModelFromController() {
        model.sessions = controller.sessions
        model.selectedSessionID = controller.selectedSessionID
        model.interactionMode = controller.interactionMode
        model.busySessionID = activeSessionIDForOrb()
        model.availableModels = controller.visibleModels
        model.selectedModelSummary = controller.selectedModelSummary
        model.workingToolActivity = Array(controller.visibleToolActivity.prefix(6))
        model.activeSessionSummary = activeSessionSummaryForOrb()
        model.update(state: displayState(for: model.state))
    }

    private func activeSessionIDForOrb() -> String? {
        guard shouldShowBusyIndicator(for: controller.hudState.phase) else {
            return nil
        }
        return controller.activeRuntimeSessionID ?? controller.selectedSessionID
    }

    private func shouldShowBusyIndicator(for phase: AssistantHUDPhase) -> Bool {
        switch phase {
        case .listening, .thinking, .acting, .waitingForPermission, .streaming:
            return true
        case .idle, .success, .failed:
            return false
        }
    }

    private func displayState(for state: AssistantHUDState) -> AssistantHUDState {
        guard state.phase == .success else { return state }
        guard state.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil,
              let preview = latestAssistantPreview()?.nonEmpty else {
            return state
        }

        return AssistantHUDState(
            phase: state.phase,
            title: "Reply ready",
            detail: preview
        )
    }

    private func latestAssistantPreview() -> String? {
        let preferredSessionID = controller.activeRuntimeSessionID ?? controller.selectedSessionID

        if let preferredSessionID,
           let session = controller.sessions.first(where: { sessionIDsMatch($0.id, preferredSessionID) }),
           let preview = session.latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return preview
        }

        return controller.sessions.first?.latestAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func activeSessionSummaryForOrb() -> AssistantSessionSummary? {
        let preferredSessionID = controller.activeRuntimeSessionID ?? controller.selectedSessionID

        if let preferredSessionID,
           let session = controller.sessions.first(where: { sessionIDsMatch($0.id, preferredSessionID) }) {
            return session
        }

        return controller.sessions.first
    }

    private func sessionIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func persistCollapsedOrigin(from panelOrigin: NSPoint, isExpanded: Bool) {
        let collapsedOrigin: NSPoint
        if isExpanded {
            collapsedOrigin = NSPoint(
                x: panelOrigin.x + ((Layout.expandedSize.width - Layout.collapsedSize.width) / 2),
                y: panelOrigin.y + (Layout.expandedSize.height - Layout.collapsedSize.height)
            )
        } else {
            collapsedOrigin = panelOrigin
        }

        savedOrigin = collapsedOrigin
        let dict: [String: Double] = [
            "x": Double(collapsedOrigin.x),
            "y": Double(collapsedOrigin.y)
        ]
        UserDefaults.standard.set(dict, forKey: kOrbPositionKey)
    }

    private func screenForCurrentPlacement(panel: NSPanel) -> NSScreen? {
        if let panelScreen = panel.screen {
            return panelScreen
        }

        if let saved = savedOrigin {
            let collapsedFrame = NSRect(origin: saved, size: Layout.collapsedSize)
            if let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(collapsedFrame) }) {
                return matchingScreen
            }
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func sendCompletionNotification(message: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "KeyScribe Assistant"
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Key-capable Panel with native drag

fileprivate enum OrbTheme: String, CaseIterable {
    case standard = "Standard"
    case solarEclipse = "Solar Eclipse"
    case bloodMoon = "Blood Moon"
}

private class OrbHUDPanel: NSPanel {
    var allowsKeyStatus = false
    var onPositionPersist: (() -> Void)?

    /// Height of the orb area (top of window) that initiates dragging.
    private let orbAreaHeight: CGFloat = 120
    private let dragThreshold: CGFloat = 4

    private var dragStartScreenLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isWindowDragging = false

    override var canBecomeKey: Bool { allowsKeyStatus }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let loc = event.locationInWindow
            // Only track drag in the orb area (top portion of window)
            if loc.y >= frame.height - orbAreaHeight {
                dragStartScreenLocation = NSEvent.mouseLocation
                dragStartOrigin = frame.origin
                isWindowDragging = false
            }
            super.sendEvent(event)

        case .leftMouseDragged:
            guard let startLoc = dragStartScreenLocation,
                  let startOrigin = dragStartOrigin else {
                super.sendEvent(event)
                return
            }

            let currentLoc = NSEvent.mouseLocation
            let dx = currentLoc.x - startLoc.x
            let dy = currentLoc.y - startLoc.y

            if !isWindowDragging {
                if abs(dx) > dragThreshold || abs(dy) > dragThreshold {
                    isWindowDragging = true
                } else {
                    return // Below threshold, swallow to avoid jitter
                }
            }

            // Move window using screen-space delta (window-server level, zero latency)
            setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            // Don't pass to super — we own this gesture now

        case .leftMouseUp:
            if isWindowDragging {
                onPositionPersist?()
                isWindowDragging = false
                dragStartScreenLocation = nil
                dragStartOrigin = nil
                return // Consumed by drag, don't forward as tap
            }
            dragStartScreenLocation = nil
            dragStartOrigin = nil
            super.sendEvent(event)

        case .rightMouseDown:
            let loc = event.locationInWindow
            if loc.y >= frame.height - orbAreaHeight {
                showOrbContextMenu(at: event)
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    private func showOrbContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        let currentThemeStr = UserDefaults.standard.string(forKey: "AssistantOrbTheme") ?? OrbTheme.standard.rawValue
        
        for theme in OrbTheme.allCases {
            let item = NSMenuItem(title: theme.rawValue, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            if theme.rawValue == currentThemeStr {
                item.state = .on
            }
            themeMenu.addItem(item)
        }
        
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit KeyScribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        NSMenu.popUpContextMenu(menu, with: event, for: contentView!)
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        if let themeObj = sender.representedObject as? String {
            UserDefaults.standard.set(themeObj, forKey: "AssistantOrbTheme")
        }
    }
}

// MARK: - HUD View

private struct AssistantOrbHUDView: View {
    @ObservedObject var model: AssistantOrbHUDModel
    @FocusState private var isTextFieldFocused: Bool
    @AppStorage("AssistantOrbTheme") private var orbTheme: String = OrbTheme.standard.rawValue

    private var showingPopup: Bool {
        (model.showDoneDetail || model.showWorkingDetail || model.pendingPermissionRequest != nil) && !model.isExpanded
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showDoneDetail && !model.isExpanded {
                doneDetailPopup(maxHeight: 280, showsFollowUpComposer: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.showWorkingDetail && !model.showDoneDetail && model.pendingPermissionRequest == nil && !model.isExpanded {
                workingDetailPopup(maxHeight: 280, showsOpenButton: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.pendingPermissionRequest != nil && !model.showDoneDetail && !model.showWorkingDetail && !model.isExpanded {
                permissionPopup(maxHeight: 280)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            orbSection

            if model.isExpanded {
                sessionPopoverSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(
            width: model.isExpanded ? 300 : (showingPopup ? 340 : 140),
            height: model.isExpanded ? 480 : (showingPopup ? 456 : 156)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.showDoneDetail)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.showWorkingDetail)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.pendingPermissionRequest != nil)
        .onChange(of: model.shouldFocusTextField) { focused in
            if focused { isTextFieldFocused = true }
        }
    }

    // MARK: Orb

    private var orbSection: some View {
        VStack(spacing: 4) {
            orbSphereView
                .onTapGesture { handleOrbTap() }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

            VStack(spacing: 1.5) {
                Text(phaseLabel)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: glowColor.opacity(0.6), radius: 6, x: 0, y: 0)
                    .contentTransition(.opacity)

                if let detail = model.state.detail, !detail.isEmpty, !model.showDoneDetail, !model.showWorkingDetail {
                    Text(detail)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(model.state.phase == .success ? 2 : 1)
                        .truncationMode(model.state.phase == .success ? .tail : .middle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 132)
                        .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 1)
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(HUDCapsuleBackground(tint: glowColor))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.state.detail)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.state.phase)
        }
    }

    private var orbSphereView: some View {
        let isIdle = model.state.phase == .idle || model.state.phase == .success
        return TimelineView(.animation(minimumInterval: isIdle ? 1.0 / 8.0 : 1.0 / 30.0, paused: false)) { context in
            OrbSphere(
                phase: model.state.phase,
                level: CGFloat(model.level),
                time: context.date.timeIntervalSinceReferenceDate,
                theme: OrbTheme(rawValue: orbTheme) ?? .standard
            )
            .frame(width: 56, height: 56)
        }
    }

    // MARK: Done Detail Popup

    private func doneDetailPopup(maxHeight: CGFloat, showsFollowUpComposer: Bool) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("DONE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        model.dismissDoneDetail()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Scrollable markdown content
            ScrollView(.vertical, showsIndicators: true) {
                if let detail = model.doneDetailText, !detail.isEmpty {
                    OrbDoneMarkdownText(text: detail)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxHeight: .infinity)

            if showsFollowUpComposer {
                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(AssistantInteractionMode.allCases, id: \.self) { mode in
                            inlineModeButton(mode)
                        }
                        Spacer(minLength: 8)
                        Text("Enter sends")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.40))
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        OrbComposerTextView(
                            text: $model.messageText,
                            placeholder: "Follow up...",
                            onSubmit: { sendDoneFollowUp() }
                        )
                        .frame(minHeight: 58, maxHeight: 96)
                        .appThemedSurface(
                            cornerRadius: 10,
                            tint: AppVisualTheme.baseTint,
                            strokeOpacity: 0.12,
                            tintOpacity: 0.028
                        )

                        Button {
                            sendDoneFollowUp()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(
                                    model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color.white.opacity(0.25)
                                        : Color(red: 0.15, green: 0.80, blue: 0.40)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding(.bottom, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                Divider()
                    .overlay(Color.white.opacity(0.08))

                HStack(spacing: 8) {
                    Text("Keep chatting below or close this notice to return to ready.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Ready") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            model.dismissDoneDetail()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.15, green: 0.80, blue: 0.40))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.15, green: 0.80, blue: 0.40).opacity(0.14))
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .appThemedSurface(
            cornerRadius: 14,
            tint: Color(red: 0.15, green: 0.80, blue: 0.40).opacity(0.96),
            strokeOpacity: 0.18,
            tintOpacity: 0.06
        )
        .shadow(color: Color(red: 0.15, green: 0.80, blue: 0.40).opacity(0.24), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Working Detail Popup

    private func workingDetailPopup(maxHeight: CGFloat, showsOpenButton: Bool) -> some View {
        let tint = glowColor

        return VStack(spacing: 0) {
            HStack {
                Text(model.workingPopupTitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        model.dismissWorkingDetail()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .overlay(Color.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.state.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    if let summary = model.workingSummaryText, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.70))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let session = model.activeSessionSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.88))
                            if let cwd = session.cwd?.nonEmpty {
                                Text(cwd)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(2)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    }

                    if !model.workingToolActivity.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live steps")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.52))

                            ForEach(Array(model.workingToolActivity.prefix(4))) { item in
                                OrbWorkingActivityRow(item: item)
                            }
                        }
                    } else {
                        Text("Detailed step output has not arrived yet, but the agent is still working.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.white.opacity(0.08))

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(AssistantInteractionMode.allCases, id: \.self) { mode in
                        inlineModeButton(mode)
                    }
                    Spacer(minLength: 8)
                    Text("Enter steers now")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                }

                HStack(alignment: .bottom, spacing: 8) {
                    OrbComposerTextView(
                        text: $model.messageText,
                        placeholder: "Steer it or prepare the next follow-up...",
                        onSubmit: { sendWorkingFollowUp() }
                    )
                    .frame(minHeight: 58, maxHeight: 96)
                    .appThemedSurface(
                        cornerRadius: 10,
                        tint: AppVisualTheme.baseTint,
                        strokeOpacity: 0.12,
                        tintOpacity: 0.028
                    )

                    VStack(spacing: 6) {
                        Button {
                            sendWorkingFollowUp()
                        } label: {
                            Image(systemName: "paperplane.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(
                                    model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color.white.opacity(0.25)
                                        : tint
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if showsOpenButton {
                            Button("Open") {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                    model.expand()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(tint.opacity(0.14))
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }

                HStack(spacing: 8) {
                    Text("You can type while it works. Sending here interrupts the current turn and applies your new instruction.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .appThemedSurface(
            cornerRadius: 14,
            tint: tint.opacity(0.96),
            strokeOpacity: 0.18,
            tintOpacity: 0.06
        )
        .shadow(color: tint.opacity(0.24), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Permission Popup

    private func permissionPopup(maxHeight: CGFloat) -> some View {
        let orangeTint = Color(red: 0.95, green: 0.60, blue: 0.10)

        return VStack(spacing: 0) {
            // Header
            HStack {
                Text(permissionHeaderTitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                Button {
                    model.onCancelPermission?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .overlay(Color.white.opacity(0.08))

            if let request = model.pendingPermissionRequest {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(request.toolTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))

                        if let rationale = request.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(3)
                        }

                        if let summary = request.rawPayloadSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(4)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.04))
                                )
                        }

                        // Permission option buttons
                        VStack(spacing: 6) {
                            ForEach(request.options) { option in
                                Button {
                                    model.onResolvePermission?(option.id)
                                } label: {
                                    Text(option.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(
                                                    option.isDefault
                                                        ? orangeTint.opacity(0.35)
                                                        : Color.white.opacity(0.08)
                                                )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(
                                                    option.isDefault
                                                        ? orangeTint.opacity(0.5)
                                                        : Color.white.opacity(0.08),
                                                    lineWidth: 0.5
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            // Always Allow button
                            if let toolKind = request.toolKind, !toolKind.isEmpty {
                                Button {
                                    model.onAlwaysAllowPermission?(toolKind)
                                    let sessionOption = request.options.first(where: { $0.id == "acceptForSession" })
                                        ?? request.options.first(where: { $0.isDefault })
                                    if let optionID = sessionOption?.id {
                                        model.onResolvePermission?(optionID)
                                    }
                                } label: {
                                    Text("Always Allow")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(orangeTint)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(orangeTint.opacity(0.10))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(orangeTint.opacity(0.25), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Cancel request
                        Button {
                            model.onCancelPermission?()
                        } label: {
                            Text("Cancel Request")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .appThemedSurface(
            cornerRadius: 14,
            tint: orangeTint.opacity(0.96),
            strokeOpacity: 0.18,
            tintOpacity: 0.06
        )
        .shadow(color: orangeTint.opacity(0.24), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Session Popover

    private var sessionPopoverSection: some View {
        VStack(spacing: 0) {
            sessionListSection
        }
        .appThemedSurface(
            cornerRadius: 14,
            tint: AppVisualTheme.baseTint,
            strokeOpacity: 0.18,
            tintOpacity: 0.05
        )
        .shadow(color: Color.black.opacity(0.42), radius: 24, x: 0, y: 10)
        .padding(.top, 6)
    }

    // MARK: Session List

    private var sessionListSection: some View {
        Group {
            // New session button
            Button(action: {
                Task { await model.onNewSession?() }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New Session")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .appThemedSurface(
                    cornerRadius: 10,
                    tint: AppVisualTheme.accentTint,
                    strokeOpacity: 0.14,
                    tintOpacity: 0.035
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if model.showDoneDetail {
                doneDetailPopup(maxHeight: 180, showsFollowUpComposer: false)
                    .padding(.top, 8)
            } else if model.pendingPermissionRequest != nil {
                permissionPopup(maxHeight: 240)
                    .padding(.top, 8)
            } else if model.showWorkingDetail {
                workingDetailPopup(maxHeight: 200, showsOpenButton: false)
                    .padding(.top, 8)
            }

            // Session list
            if model.isLoadingSessions {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if model.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.sessions.prefix(5)) { session in
                        OrbSessionRow(
                            session: session,
                            isSelected: session.id == model.selectedSessionID,
                            isBusy: sessionMatches(session.id, model.busySessionID)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.onOpenSession?(session)
                        }
                        .onTapGesture(count: 1) {
                            model.selectedSessionID = session.id
                            model.onSessionSelected?(session)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            // Target indicator
            if let name = model.targetSessionName {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.right.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Sending to: \(name)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.40))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            // Message input with inline mode + model picker
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    ForEach(AssistantInteractionMode.allCases, id: \.self) { mode in
                        inlineModeButton(mode)
                    }
                    Spacer()
                    orbModelPicker
                }

                HStack(spacing: 8) {
                    TextField(
                        model.isVoiceRecording ? "Listening..." : "Send a message...",
                        text: $model.messageText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .focused($isTextFieldFocused)
                    .onSubmit { sendMessage() }
                    .disabled(model.isVoiceRecording)

                    Button {
                        if model.isVoiceRecording {
                            model.onStopVoiceRecording?()
                        } else {
                            model.onStartVoiceRecording?()
                        }
                    } label: {
                        Image(systemName: model.isVoiceRecording ? "mic.fill" : "mic")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(
                                model.isVoiceRecording
                                    ? Color(red: 0.0, green: 0.75, blue: 0.95)
                                    : Color.white.opacity(0.45)
                            )
                            .frame(width: 24, height: 24)
                            .scaleEffect(model.isVoiceRecording ? 1.15 : 1.0)
                            .animation(
                                model.isVoiceRecording
                                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                    : .default,
                                value: model.isVoiceRecording
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: { sendMessage() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(
                                canSend ? glowColor : Color.white.opacity(0.25)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || model.isVoiceRecording)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .appThemedSurface(
                cornerRadius: 10,
                tint: AppVisualTheme.baseTint,
                strokeOpacity: 0.12,
                tintOpacity: 0.028
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    // MARK: Helpers

    private func inlineModeButton(_ mode: AssistantInteractionMode) -> some View {
        let isActive = model.interactionMode == mode
        let fg: Color = isActive ? .white.opacity(0.92) : .white.opacity(0.45)
        let bg: Color = isActive ? mode.tint.opacity(0.28) : Color.white.opacity(0.06)
        let stroke: Color = isActive ? mode.tint.opacity(0.30) : Color.clear

        return Button { model.interactionMode = mode } label: {
            Text(mode.orbLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(fg)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(bg)
                        .overlay(Capsule().stroke(stroke, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }

    private var orbModelPicker: some View {
        Menu {
            ForEach(model.availableModels) { m in
                Button {
                    model.onChooseModel?(m.id)
                } label: {
                    Text(m.displayName)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppVisualTheme.accentTint)
                Text(model.selectedModelSummary)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.07))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.availableModels.isEmpty)
    }

    private var canSend: Bool {
        !model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleOrbTap() {
        if model.isExpanded {
            model.collapse()
            return
        }

        if model.showDoneDetail || model.pendingPermissionRequest != nil {
            model.expand()
            return
        }

        if model.showWorkingDetail {
            model.expand()
            return
        }

        if model.presentWorkingDetailIfAvailable() {
            return
        }

        model.expand()
    }

    private func sendDoneFollowUp() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            model.dismissDoneDetail()
        }
    }

    private func sendWorkingFollowUp() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.messageText = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            model.dismissWorkingDetail()
        }
    }

    private func sendMessage() {
        let trimmed = model.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if model.showDoneDetail {
            model.dismissDoneDetail()
        }
        if model.showWorkingDetail {
            model.dismissWorkingDetail()
        }
        model.onSendMessage?(trimmed, model.selectedSessionID)
        model.collapse()
    }

    private var permissionHeaderTitle: String {
        guard let request = model.pendingPermissionRequest else { return "ACTION NEEDED" }
        let normalizedTitle = request.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedTitle.contains("information") || normalizedTitle.contains("input") || normalizedTitle.contains("question") {
            return "INPUT NEEDED"
        }
        return "APPROVAL NEEDED"
    }

    private var phaseLabel: String {
        switch model.state.phase {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .acting: return "Working"
        case .waitingForPermission: return "Waiting"
        case .streaming: return "Streaming"
        case .success: return "Done"
        case .failed: return "Error"
        }
    }

    private var glowColor: Color {
        let theme = OrbTheme(rawValue: orbTheme) ?? .standard
        switch theme {
        case .solarEclipse:
            return Color.white
        case .bloodMoon:
            return Color(red: 0.9, green: 0.1, blue: 0.1)
        case .standard:
            return OrbSphere.phaseColor(for: model.state.phase)
        }
    }

    private func sessionMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

@MainActor
private extension AssistantInteractionMode {
    var orbLabel: String {
        switch self {
        case .conversational: return "Chat"
        case .plan: return "Plan"
        case .agentic: return "Agentic"
        }
    }

    var tint: Color {
        switch self {
        case .conversational: return .blue
        case .plan: return .orange
        case .agentic: return AppVisualTheme.accentTint
        }
    }
}

// MARK: - Session Row

private struct OrbSessionRow: View {
    let session: AssistantSessionSummary
    let isSelected: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            leadingIndicator

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? "Untitled Session" : session.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)

                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if isSelected && !isBusy {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.60))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                    ? AppVisualTheme.rowSelection.opacity(0.78)
                    : AppVisualTheme.panelTint.opacity(0.34)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected
                            ? AppVisualTheme.accentTint.opacity(0.26)
                            : Color.white.opacity(0.05),
                            lineWidth: 0.6
                        )
                )
        }
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        if isBusy {
            BusySessionIndicator(tint: AppVisualTheme.accentTint)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .active: return .green.opacity(0.85)
        case .waitingForApproval, .waitingForInput: return .orange.opacity(0.85)
        case .completed: return Color(white: 0.50)
        case .failed: return .red.opacity(0.85)
        case .idle, .unknown: return Color(white: 0.35)
        }
    }
}

private struct BusySessionIndicator: View {
    let tint: Color

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.65)
            .tint(tint)
    }
}

private struct OrbWorkingActivityRow: View {
    let item: AssistantToolCallState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))

                if let detail = (item.hudDetail ?? item.detail)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var statusTint: Color {
        let normalized = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fail") || normalized.contains("error") {
            return .red
        }
        if normalized.contains("complete") || normalized.contains("done") {
            return .green
        }
        return .orange
    }
}

private struct OrbComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

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

        let textView = OrbSubmittableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 3
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.placeholder = placeholder

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? OrbSubmittableTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        textView.placeholder = placeholder
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: OrbComposerTextView

        init(parent: OrbComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

private final class OrbSubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder: String = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.32)
        ]
        let placeholderRect = NSRect(
            x: textContainerInset.width + 2,
            y: textContainerInset.height + 1,
            width: bounds.width - (textContainerInset.width * 2) - 4,
            height: bounds.height - (textContainerInset.height * 2)
        )
        NSString(string: placeholder).draw(in: placeholderRect, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShift = event.modifierFlags.contains(.shift)

        if isReturn && !isShift {
            onSubmit?()
            return
        }

        super.keyDown(with: event)
        needsDisplay = true
    }
}

// MARK: - Orb Sphere (Siri-inspired)

private struct OrbSphere: View {
    let phase: AssistantHUDPhase
    let level: CGFloat
    let time: TimeInterval
    let theme: OrbTheme

    private let sphereSize: CGFloat = 42

    var body: some View {
        let pulse = pulseScale
        let c = colors
        let speed = animSpeed

        ZStack {
            // 1 — Wide ambient glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            c.primary.opacity(0.60),
                            c.secondary.opacity(0.30),
                            c.accent.opacity(0.12),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 46
                    )
                )
                .frame(width: 90, height: 90)
                .blur(radius: 18)
                .scaleEffect(pulse * 1.08)

            // 2 — Luminous color-filled base + flowing blobs (Siri-style)
            ZStack {
                // Colored base instead of dark — mid-tone of primary
                Circle().fill(
                    RadialGradient(
                        colors: [
                            c.primary.opacity(0.70),
                            c.secondary.opacity(0.50),
                            c.primary.opacity(0.35)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 24
                    )
                )

                // Primary blob — large, saturated
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [c.primary, c.primary.opacity(0.50), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 22
                        )
                    )
                    .frame(width: 40, height: 40)
                    .offset(
                        x: CGFloat(sin(time * speed * 0.35)) * 7,
                        y: CGFloat(cos(time * speed * 0.25)) * 7
                    )
                    .blur(radius: 6)

                // Secondary blob
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [c.secondary.opacity(0.95), c.secondary.opacity(0.30), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 18
                        )
                    )
                    .frame(width: 32, height: 32)
                    .offset(
                        x: CGFloat(cos(time * speed * 0.55)) * 8,
                        y: CGFloat(sin(time * speed * 0.40)) * 6
                    )
                    .blur(radius: 5)

                // Accent blob
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [c.accent.opacity(0.85), c.accent.opacity(0.20), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 14
                        )
                    )
                    .frame(width: 26, height: 26)
                    .offset(
                        x: CGFloat(sin(time * speed * 0.70)) * 6,
                        y: CGFloat(cos(time * speed * 0.50)) * 7
                    )
                    .blur(radius: 4)

                // Bright highlight wash — adds luminosity
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                c.primary.opacity(0.15),
                                Color.clear
                            ],
                            center: UnitPoint(
                                x: 0.5 + sin(time * speed * 0.2) * 0.15,
                                y: 0.5 + cos(time * speed * 0.15) * 0.15
                            ),
                            startRadius: 0,
                            endRadius: 20
                        )
                    )
                    .frame(width: sphereSize, height: sphereSize)
            }
            .frame(width: sphereSize, height: sphereSize)
            .clipShape(Circle())

            // 3 — Glass inner glow (additive)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.38),
                            Color.white.opacity(0.10),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.36, y: 0.28),
                        startRadius: 0,
                        endRadius: 18
                    )
                )
                .frame(width: sphereSize, height: sphereSize)
                .blendMode(.screen)

            // 4 — Specular catch-light
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.82),
                            Color.white.opacity(0.18),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.30, y: 0.22),
                        startRadius: 0,
                        endRadius: 9
                    )
                )
                .frame(width: sphereSize, height: sphereSize)

            // 5 — Edge ring with color
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            c.primary.opacity(0.30),
                            Color.white.opacity(0.22),
                            c.secondary.opacity(0.25),
                            Color.white.opacity(0.15),
                            c.primary.opacity(0.30)
                        ],
                        center: .center
                    ),
                    lineWidth: 0.8
                )
                .frame(width: sphereSize, height: sphereSize)
        }
        .shadow(color: c.primary.opacity(0.60), radius: 16, x: 0, y: 3)
        .scaleEffect(pulse)
    }

    // MARK: Animation

    private var pulseScale: CGFloat {
        switch phase {
        case .idle:
            return 1.0 + CGFloat(sin(time * 1.2)) * 0.008
        case .listening:
            return 1.0 + level * 0.10 + CGFloat(sin(time * 2.0)) * 0.015
        case .thinking:
            return 1.0 + CGFloat(sin(time * 1.6)) * 0.025
        case .acting:
            return 1.01 + CGFloat(sin(time * 2.2)) * 0.02
        case .waitingForPermission:
            return 0.99 + CGFloat(sin(time * 0.9)) * 0.02
        case .streaming:
            return 1.005 + CGFloat(sin(time * 1.8)) * 0.02
        case .success:
            return 1.02
        case .failed:
            return 1.0 + CGFloat(sin(time * 4.0)) * 0.015
        }
    }

    /// Controls how fast the internal blobs drift.
    private var animSpeed: Double {
        switch phase {
        case .idle: return 1.0
        case .listening: return 2.4
        case .thinking: return 1.8
        case .acting: return 3.0
        case .waitingForPermission: return 0.8
        case .streaming: return 2.2
        case .success: return 1.2
        case .failed: return 4.0
        }
    }

    // MARK: Colors

    private struct OrbColors {
        let primary: Color
        let secondary: Color
        let accent: Color
    }

    private var colors: OrbColors {
        switch theme {
        case .solarEclipse:
            return OrbColors(
                primary: Color(white: 0.15),
                secondary: Color(white: 0.95),
                accent: Color.yellow.opacity(0.8)
            )
        case .bloodMoon:
            return OrbColors(
                primary: Color(red: 0.25, green: 0.05, blue: 0.05),
                secondary: Color(red: 0.9, green: 0.1, blue: 0.1),
                accent: Color(red: 0.8, green: 0.2, blue: 0.2)
            )
        case .standard:
            switch phase {
            case .idle:
                return OrbColors(
                    primary: AppVisualTheme.accentTint,
                    secondary: AppVisualTheme.accentTint.opacity(0.65),
                    accent: Color.white.opacity(0.30)
                )
            case .listening:
                return OrbColors(
                    primary: Color(red: 0.0, green: 0.75, blue: 0.95),
                    secondary: Color(red: 0.20, green: 0.30, blue: 0.90),
                    accent: Color(red: 0.10, green: 0.85, blue: 0.80)
                )
            case .thinking:
                return OrbColors(
                    primary: Color(red: 0.50, green: 0.30, blue: 0.95),
                    secondary: Color(red: 0.75, green: 0.35, blue: 0.90),
                    accent: Color(red: 0.35, green: 0.20, blue: 0.80)
                )
            case .acting:
                return OrbColors(
                    primary: Color(red: 0.10, green: 0.82, blue: 0.72),
                    secondary: Color(red: 0.25, green: 0.90, blue: 0.55),
                    accent: Color(red: 0.06, green: 0.52, blue: 0.48)
                )
            case .waitingForPermission:
                return OrbColors(
                    primary: Color(red: 0.95, green: 0.60, blue: 0.10),
                    secondary: Color(red: 0.95, green: 0.80, blue: 0.20),
                    accent: Color(red: 0.72, green: 0.38, blue: 0.05)
                )
            case .streaming:
                return OrbColors(
                    primary: Color(red: 0.28, green: 0.65, blue: 0.98),
                    secondary: Color(red: 0.45, green: 0.80, blue: 0.98),
                    accent: Color(red: 0.18, green: 0.42, blue: 0.85)
                )
            case .success:
                return OrbColors(
                    primary: Color(red: 0.20, green: 0.85, blue: 0.45),
                    secondary: Color(red: 0.45, green: 0.92, blue: 0.55),
                    accent: Color(red: 0.15, green: 0.60, blue: 0.35)
                )
            case .failed:
                return OrbColors(
                    primary: Color(red: 0.92, green: 0.20, blue: 0.20),
                    secondary: Color(red: 0.95, green: 0.35, blue: 0.15),
                    accent: Color(red: 0.65, green: 0.10, blue: 0.12)
                )
            }
        }
    }

    static func phaseColor(for phase: AssistantHUDPhase) -> Color {
        switch phase {
        case .idle: return AppVisualTheme.accentTint
        case .listening: return Color(red: 0.0, green: 0.75, blue: 0.95)
        case .thinking: return Color(red: 0.45, green: 0.25, blue: 0.90)
        case .acting: return Color(red: 0.10, green: 0.82, blue: 0.72)
        case .waitingForPermission: return .orange
        case .streaming: return Color(red: 0.22, green: 0.60, blue: 0.95)
        case .success: return Color(red: 0.15, green: 0.80, blue: 0.40)
        case .failed: return .red
        }
    }
}

// MARK: - Done Detail Markdown

private struct OrbDoneMarkdownText: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(orbDoneTheme)
            .markdownCodeSyntaxHighlighter(.plainText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orbDoneTheme: MarkdownUI.Theme {
        .init()
            .text {
                ForegroundColor(.white.opacity(0.88))
                FontSize(13)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(14.5)
                        FontWeight(.bold)
                        ForegroundColor(.white.opacity(0.90))
                    }
                    .markdownMargin(top: 8, bottom: 5)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(13.5)
                        FontWeight(.semibold)
                        ForegroundColor(.white.opacity(0.88))
                    }
                    .markdownMargin(top: 6, bottom: 4)
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
                FontSize(12)
                ForegroundColor(.white.opacity(0.82))
                BackgroundColor(Color(red: 0.10, green: 0.10, blue: 0.13))
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(12)
                            ForegroundColor(.white.opacity(0.82))
                        }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                        )
                )
                .markdownMargin(top: 4, bottom: 4)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(AppVisualTheme.accentTint.opacity(0.4))
                        .frame(width: 2.5)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.white.opacity(0.7))
                            FontStyle(.italic)
                        }
                        .padding(.leading, 8)
                }
                .markdownMargin(top: 3, bottom: 3)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 3, bottom: 3)
            }
    }
}
