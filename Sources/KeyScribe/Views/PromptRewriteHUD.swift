import AppKit
import SwiftUI

@MainActor
enum PromptRewritePreviewChoice {
    case useSuggested
    case editThenInsert
    case insertOriginal
    case rejectSuggestion
}

private enum PromptRewriteBubbleEdge {
    case top
    case bottom
}

struct PromptRewriteInsertionHUDContext: Equatable {
    let anchorRect: NSRect
    let screenNumber: UInt32?
    let screenName: String
    let targetProcessIdentifier: pid_t?
}

private struct PromptRewriteHUDPlacement {
    let frame: NSRect
    let bubbleEdge: PromptRewriteBubbleEdge
    let bubbleOffsetX: CGFloat
}

private struct PromptRewriteHUDSessionKey: Hashable {
    let screenNumber: UInt32?
    let processIdentifier: Int?
}

private enum PromptRewriteHUDLayout {
    static let panelWidth: CGFloat = 500
    static let minPanelHeight: CGFloat = 84
    static let maxPanelHeight: CGFloat = 166
    static let screenMargin: CGFloat = 8
    static let anchorGap: CGFloat = 14
    static let cornerRadius: CGFloat = 26
    static let loadingSize = NSSize(width: 72, height: 30)
    static let loadingOffsetY: CGFloat = 16
}

@MainActor
final class PromptRewriteHUDManager {
    static let shared = PromptRewriteHUDManager()

    private enum HUDKeyCodes {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    private struct PendingSuggestion: Identifiable {
        let id: UUID
        let originalText: String
        let suggestion: PromptRewriteSuggestion
        let continuation: CheckedContinuation<PromptRewritePreviewChoice, Never>
    }

    @MainActor
    private final class PromptRewriteHUDSession {
        let key: PromptRewriteHUDSessionKey
        var insertionContext: PromptRewriteInsertionHUDContext
        let window: NSPanel
        var pendingSuggestions: [PendingSuggestion]
        var selectedSuggestionIndex: Int = 0
        var manualOffset: CGSize = .zero
        var dragBaseManualOffset: CGSize?

        init(key: PromptRewriteHUDSessionKey, insertionContext: PromptRewriteInsertionHUDContext, pendingSuggestions: [PendingSuggestion] = [], selectedSuggestionIndex: Int = 0) {
            self.key = key
            self.insertionContext = insertionContext
            self.window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: PromptRewriteHUDLayout.panelWidth, height: 0),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            self.window.isFloatingPanel = true
            self.window.level = .floating
            self.window.backgroundColor = .clear
            self.window.isOpaque = false
            self.window.hasShadow = false
            self.window.hidesOnDeactivate = false
            self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.window.contentView?.wantsLayer = true
            self.window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            self.pendingSuggestions = pendingSuggestions
            self.selectedSuggestionIndex = selectedSuggestionIndex
        }

        deinit {
            let win = window
            Task { @MainActor [weak win] in
                win?.orderOut(nil)
                win?.contentViewController = nil
            }
        }
    }

    @MainActor
    private final class PromptRewriteLoadingSession {
        let key: PromptRewriteHUDSessionKey
        var insertionContext: PromptRewriteInsertionHUDContext
        let window: NSPanel

        init(key: PromptRewriteHUDSessionKey, insertionContext: PromptRewriteInsertionHUDContext) {
            self.key = key
            self.insertionContext = insertionContext
            self.window = NSPanel(
                contentRect: NSRect(origin: .zero, size: PromptRewriteHUDLayout.loadingSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            self.window.isFloatingPanel = true
            self.window.level = .floating
            self.window.backgroundColor = .clear
            self.window.isOpaque = false
            self.window.hasShadow = false
            self.window.hidesOnDeactivate = false
            self.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.window.contentView?.wantsLayer = true
            self.window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }

        deinit {
            let win = window
            Task { @MainActor [weak win] in
                win?.orderOut(nil)
                win?.contentViewController = nil
            }
        }
    }

    private var sessions: [PromptRewriteHUDSessionKey: PromptRewriteHUDSession] = [:]
    private var loadingSessions: [PromptRewriteHUDSessionKey: PromptRewriteLoadingSession] = [:]
    private var activeSessionOrder: [PromptRewriteHUDSessionKey] = []
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func showLoadingIndicator(insertionContext: PromptRewriteInsertionHUDContext) {
        let key = sessionKey(for: insertionContext)
        let session: PromptRewriteLoadingSession
        if let existing = loadingSessions[key] {
            session = existing
            session.insertionContext = insertionContext
        } else {
            session = PromptRewriteLoadingSession(key: key, insertionContext: insertionContext)
            loadingSessions[key] = session
        }

        if session.window.contentViewController == nil {
            let hosting = NSHostingController(rootView: PromptRewriteLoadingView())
            session.window.contentViewController = hosting
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.view.frame = NSRect(origin: .zero, size: PromptRewriteHUDLayout.loadingSize)
        }

        let frame = loadingFrame(for: session.insertionContext)
        session.window.alphaValue = 1
        session.window.setFrame(frame, display: true)
        session.window.orderFrontRegardless()
    }

    func hideLoadingIndicator(insertionContext: PromptRewriteInsertionHUDContext) {
        let key = sessionKey(for: insertionContext)
        hideLoadingSession(for: key)
    }

    func captureCurrentInsertionContext(fallbackApp: NSRunningApplication?) -> PromptRewriteInsertionHUDContext {
        let rawAnchorRect = insertionAnchorRect()
        let validatedAnchorRect = usableAnchorRect(from: rawAnchorRect)
        let anchorRect = validatedAnchorRect ?? mouseAnchorRect()
        let usedInsertionAnchor = validatedAnchorRect != nil
        let fallbackScreen = screenContaining(point: NSPoint(x: anchorRect.midX, y: anchorRect.midY))
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let screenName = fallbackScreen?.localizedName ?? "Current Screen"
        let screenNumber = screenNumber(for: fallbackScreen)
        let processIdentifier = captureTargetProcessID(fallbackApp: fallbackApp)
        CrashReporter.logInfo(
            "HUD anchor selected: \(anchorRect) source=\(usedInsertionAnchor ? "insertion" : "mouse-fallback")"
        )

        return PromptRewriteInsertionHUDContext(
            anchorRect: anchorRect,
            screenNumber: screenNumber,
            screenName: screenName,
            targetProcessIdentifier: processIdentifier
        )
    }

    func present(
        originalText: String,
        suggestion: PromptRewriteSuggestion,
        insertionContext: PromptRewriteInsertionHUDContext
    ) async -> PromptRewritePreviewChoice {
        let key = sessionKey(for: insertionContext)
        hideLoadingSession(for: key)
        let session: PromptRewriteHUDSession
        if let existing = sessions[key] {
            session = existing
            session.insertionContext = insertionContext
        } else {
            let newSession = PromptRewriteHUDSession(key: key, insertionContext: insertionContext)
            sessions[key] = newSession
            session = newSession
        }

        let result = await withCheckedContinuation { continuation in
            session.pendingSuggestions.append(
                PendingSuggestion(
                    id: UUID(),
                    originalText: originalText,
                    suggestion: suggestion,
                    continuation: continuation
                )
            )
            session.selectedSuggestionIndex = max(0, session.pendingSuggestions.count - 1)
            touchSession(key)
            render(session: session, animateIn: true)
        }

        return result
    }

    private func sessionKey(for insertionContext: PromptRewriteInsertionHUDContext) -> PromptRewriteHUDSessionKey {
        PromptRewriteHUDSessionKey(
            screenNumber: insertionContext.screenNumber,
            processIdentifier: insertionContext.targetProcessIdentifier.map { Int($0) }
        )
    }

    private func touchSession(_ key: PromptRewriteHUDSessionKey) {
        activeSessionOrder.removeAll(where: { $0 == key })
        activeSessionOrder.append(key)
    }

    private func removeSessionFromOrder(_ key: PromptRewriteHUDSessionKey) {
        activeSessionOrder.removeAll(where: { $0 == key })
    }

    private func captureTargetProcessID(fallbackApp: NSRunningApplication?) -> pid_t? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != selfPID {
            return frontmost.processIdentifier
        }
        if let fallback = fallbackApp,
           fallback.processIdentifier != selfPID,
           !fallback.isTerminated {
            return fallback.processIdentifier
        }
        return nil
    }

    private func render(session: PromptRewriteHUDSession, animateIn: Bool = false) {
        guard !session.pendingSuggestions.isEmpty else {
            removeSession(session.key)
            session.selectedSuggestionIndex = 0
            return
        }

        let boundedIndex = min(max(0, session.selectedSuggestionIndex), session.pendingSuggestions.count - 1)

        let pages = session.pendingSuggestions.map { pending in
            PromptRewriteDiscussionPage(
                id: pending.id,
                originalText: pending.originalText,
                suggestion: pending.suggestion
            )
        }

        let hosting = NSHostingController(
            rootView: makeView(
                pages: pages,
                selectedIndex: boundedIndex,
                bubbleEdge: .bottom,
                bubbleOffsetX: 0,
                sessionKey: session.key
            )
        )
        session.window.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let targetSize = hosting.sizeThatFits(
            in: NSSize(width: PromptRewriteHUDLayout.panelWidth, height: PromptRewriteHUDLayout.maxPanelHeight)
        )
        let frame = NSRect(
            x: 0,
            y: 0,
            width: PromptRewriteHUDLayout.panelWidth,
            height: min(
                PromptRewriteHUDLayout.maxPanelHeight,
                max(PromptRewriteHUDLayout.minPanelHeight, targetSize.height)
            )
        )
        hosting.view.frame = frame

        let placement = resolvedPlacement(
            for: frame.size,
            context: session.insertionContext,
            manualOffset: session.manualOffset
        )
        hosting.rootView = makeView(
            pages: pages,
            selectedIndex: boundedIndex,
            bubbleEdge: placement.bubbleEdge,
            bubbleOffsetX: placement.bubbleOffsetX,
            sessionKey: session.key
        )
        session.window.orderFrontRegardless()
        show(window: session.window, at: placement.frame, bubbleEdge: placement.bubbleEdge, animated: animateIn || !session.window.isVisible)
    }

    private func makeView(
        pages: [PromptRewriteDiscussionPage],
        selectedIndex: Int,
        bubbleEdge: PromptRewriteBubbleEdge,
        bubbleOffsetX: CGFloat,
        sessionKey: PromptRewriteHUDSessionKey
    ) -> PromptRewriteHUDView {
        PromptRewriteHUDView(
            pages: pages,
            selectedIndex: selectedIndex,
            bubbleEdge: bubbleEdge,
            bubbleOffsetX: bubbleOffsetX,
            onSelectPage: { [weak self] newIndex in
                guard let self else { return }
                self.selectPage(newIndex, for: sessionKey)
            },
            onChoice: { [weak self] choice in
                guard let self else { return }
                self.finishSelected(sessionKey, with: choice)
            },
            onDragChanged: { [weak self] translation in
                guard let self else { return }
                self.updateDrag(translation, for: sessionKey, ended: false)
            },
            onDragEnded: { [weak self] translation in
                guard let self else { return }
                self.updateDrag(translation, for: sessionKey, ended: true)
            }
        )
    }

    private func selectPage(_ index: Int, for key: PromptRewriteHUDSessionKey) {
        guard let session = sessions[key], !session.pendingSuggestions.isEmpty else { return }
        session.selectedSuggestionIndex = min(max(0, index), session.pendingSuggestions.count - 1)
        touchSession(key)
        render(session: session)
    }

    private func finishSelected(_ sessionKey: PromptRewriteHUDSessionKey, with choice: PromptRewritePreviewChoice) {
        guard let session = sessions[sessionKey], !session.pendingSuggestions.isEmpty else { return }

        let index = min(max(0, session.selectedSuggestionIndex), session.pendingSuggestions.count - 1)
        let pending = session.pendingSuggestions.remove(at: index)

        guard !session.pendingSuggestions.isEmpty else {
            hide(session: session)
            pending.continuation.resume(returning: choice)
            return
        }

        session.selectedSuggestionIndex = min(index, session.pendingSuggestions.count - 1)
        pending.continuation.resume(returning: choice)
        render(session: session)
    }

    private func resolvedPlacement(for panelSize: NSSize, context: PromptRewriteInsertionHUDContext) -> PromptRewriteHUDPlacement {
        let anchorRect = context.anchorRect
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenForDisplayNumber(context.screenNumber)
            ?? screenContaining(point: anchorPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let pidString = context.targetProcessIdentifier.map { String($0) } ?? ""
        CrashReporter.logInfo("HUD placement: screen=\(context.screenName) anchorRect=\(anchorRect) appPID=\(pidString)")

        let preferredX = anchorRect.midX - (panelSize.width * 0.5)
        let minX = visibleFrame.minX + PromptRewriteHUDLayout.screenMargin
        let maxX = visibleFrame.maxX - panelSize.width - PromptRewriteHUDLayout.screenMargin
        let x = min(max(preferredX, minX), maxX)

        let gap = PromptRewriteHUDLayout.anchorGap
        let aboveY = anchorRect.maxY + gap
        let belowY = anchorRect.minY - panelSize.height - gap
        let minY = visibleFrame.minY + PromptRewriteHUDLayout.screenMargin
        let maxY = visibleFrame.maxY - panelSize.height - PromptRewriteHUDLayout.screenMargin

        let fitsAbove = aboveY >= minY && aboveY <= maxY
        let fitsBelow = belowY >= minY && belowY <= maxY

        let y: CGFloat
        let bubbleEdge: PromptRewriteBubbleEdge

        // Prefer placing above the anchor (higher Y in macOS coords).
        // If anchor is in the lower third of the screen, the "above" direction
        // gives more visible room. Fall back to below if it doesn't fit.
        if fitsAbove {
            y = aboveY
            bubbleEdge = .bottom
        } else if fitsBelow {
            y = belowY
            bubbleEdge = .top
        } else {
            // Neither fits perfectly — pick whichever has more room
            let aboveClamped = min(max(aboveY, minY), maxY)
            let belowClamped = min(max(belowY, minY), maxY)
            let aboveSpace = maxY - aboveClamped
            let belowSpace = belowClamped - minY
            if aboveSpace >= belowSpace {
                y = aboveClamped
                bubbleEdge = .bottom
            } else {
                y = belowClamped
                bubbleEdge = .top
            }
        }

        let maxBubbleOffset = (panelSize.width * 0.5) - 28
        let rawBubbleOffset = anchorRect.midX - (x + panelSize.width * 0.5)
        let bubbleOffsetX = min(max(rawBubbleOffset, -maxBubbleOffset), maxBubbleOffset)

        CrashReporter.logInfo("HUD placement: y=\(y) aboveY=\(aboveY) belowY=\(belowY) fitsAbove=\(fitsAbove) fitsBelow=\(fitsBelow) visibleFrame=\(visibleFrame)")
        return PromptRewriteHUDPlacement(
            frame: NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            bubbleEdge: bubbleEdge,
            bubbleOffsetX: bubbleOffsetX
        )
    }

    private func resolvedPlacement(
        for panelSize: NSSize,
        context: PromptRewriteInsertionHUDContext,
        manualOffset: CGSize
    ) -> PromptRewriteHUDPlacement {
        let basePlacement = resolvedPlacement(for: panelSize, context: context)
        guard manualOffset != .zero else { return basePlacement }

        let anchorRect = context.anchorRect
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenForDisplayNumber(context.screenNumber)
            ?? screenContaining(point: anchorPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)

        let minX = visibleFrame.minX + PromptRewriteHUDLayout.screenMargin
        let maxX = visibleFrame.maxX - panelSize.width - PromptRewriteHUDLayout.screenMargin
        let minY = visibleFrame.minY + PromptRewriteHUDLayout.screenMargin
        let maxY = visibleFrame.maxY - panelSize.height - PromptRewriteHUDLayout.screenMargin

        let translatedX = basePlacement.frame.origin.x + manualOffset.width
        let translatedY = basePlacement.frame.origin.y + manualOffset.height
        let clampedX = min(max(translatedX, minX), maxX)
        let clampedY = min(max(translatedY, minY), maxY)
        let frame = NSRect(x: clampedX, y: clampedY, width: panelSize.width, height: panelSize.height)

        let bubbleEdge: PromptRewriteBubbleEdge = frame.midY >= anchorRect.midY ? .bottom : .top
        let maxBubbleOffset = (panelSize.width * 0.5) - 28
        let rawBubbleOffset = anchorRect.midX - frame.midX
        let bubbleOffsetX = min(max(rawBubbleOffset, -maxBubbleOffset), maxBubbleOffset)

        return PromptRewriteHUDPlacement(
            frame: frame,
            bubbleEdge: bubbleEdge,
            bubbleOffsetX: bubbleOffsetX
        )
    }

    private func updateDrag(
        _ translation: CGSize,
        for key: PromptRewriteHUDSessionKey,
        ended: Bool
    ) {
        guard let session = sessions[key], session.window.isVisible else { return }

        if session.dragBaseManualOffset == nil {
            session.dragBaseManualOffset = session.manualOffset
        }
        let baseOffset = session.dragBaseManualOffset ?? .zero
        // SwiftUI drag translation is in top-left coordinates. NSWindow uses bottom-left.
        let windowDelta = CGSize(width: translation.width, height: -translation.height)
        session.manualOffset = CGSize(
            width: baseOffset.width + windowDelta.width,
            height: baseOffset.height + windowDelta.height
        )

        let placement = resolvedPlacement(
            for: session.window.frame.size,
            context: session.insertionContext,
            manualOffset: session.manualOffset
        )
        session.window.setFrame(placement.frame, display: true)

        if ended {
            session.dragBaseManualOffset = nil
            render(session: session)
        }
    }

    private func hideLoadingSession(for key: PromptRewriteHUDSessionKey) {
        guard let loading = loadingSessions.removeValue(forKey: key) else { return }
        loading.window.contentViewController = nil
        loading.window.orderOut(nil)
        loading.window.alphaValue = 1
    }

    private func loadingFrame(for context: PromptRewriteInsertionHUDContext) -> NSRect {
        let size = PromptRewriteHUDLayout.loadingSize
        let anchorRect = context.anchorRect
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenForDisplayNumber(context.screenNumber)
            ?? screenContaining(point: anchorPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)

        let proposedX = anchorRect.midX - (size.width * 0.5)
        let proposedY = anchorRect.midY + PromptRewriteHUDLayout.loadingOffsetY
        let minX = visibleFrame.minX + PromptRewriteHUDLayout.screenMargin
        let maxX = visibleFrame.maxX - size.width - PromptRewriteHUDLayout.screenMargin
        let minY = visibleFrame.minY + PromptRewriteHUDLayout.screenMargin
        let maxY = visibleFrame.maxY - size.height - PromptRewriteHUDLayout.screenMargin
        let clampedX = min(max(proposedX, minX), maxX)
        let clampedY = min(max(proposedY, minY), maxY)
        return NSRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }

    private func show(window: NSPanel, at frame: NSRect, bubbleEdge: PromptRewriteBubbleEdge, animated: Bool) {
        installKeyMonitor()

        if !animated {
            window.alphaValue = 1
            window.setFrame(frame, display: true)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            return
        }

        let startYOffset: CGFloat = bubbleEdge == .bottom ? -10 : 10
        let startFrame = frame.offsetBy(dx: 0, dy: startYOffset)
        window.alphaValue = 0
        window.setFrame(startFrame, display: false)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    private func removeSession(_ key: PromptRewriteHUDSessionKey) {
        guard let session = sessions.removeValue(forKey: key) else {
            return
        }
        removeSessionFromOrder(key)
        hide(session: session)
        hideLoadingSession(for: key)
        if sessions.isEmpty {
            removeKeyMonitor()
        }
    }

    private func hide(session: PromptRewriteHUDSession) {
        session.window.contentViewController = nil
        session.window.orderOut(nil)
        session.window.alphaValue = 1
        removeSessionFromOrder(session.key)
        if sessions.values.allSatisfy({ !$0.window.isVisible }) {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }

        // Use both monitors: global handles when another app is focused,
        // local handles cases where KeyScribe is active.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleMonitoredKeyDown(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = self.handleMonitoredKeyDown(event)
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    @discardableResult
    private func handleMonitoredKeyDown(_ event: NSEvent) -> Bool {
        // Ignore only explicit shortcut modifiers; do not gate on .function
        // because some keyboards set it for Esc/Enter variants.
        let blockingModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard blockingModifiers.isEmpty else { return false }

        switch event.keyCode {
        case HUDKeyCodes.escape:
            cancelMostRecentSession()
            return true
        case HUDKeyCodes.returnKey, HUDKeyCodes.keypadEnter:
            acceptMostRecentSession()
            return true
        default:
            return false
        }
    }

    private func cancelMostRecentSession() {
        guard let key = latestVisibleSessionKey() else { return }
        finishSelected(key, with: .insertOriginal)
    }

    private func acceptMostRecentSession() {
        guard let key = latestVisibleSessionKey() else { return }
        finishSelected(key, with: .useSuggested)
    }

    private func latestVisibleSessionKey() -> PromptRewriteHUDSessionKey? {
        for key in activeSessionOrder.reversed() {
            guard let session = sessions[key], session.window.isVisible else { continue }
            return key
        }
        // Fallback for edge cases where visibility state lags while a session is still active.
        for key in activeSessionOrder.reversed() where sessions[key] != nil {
            return key
        }
        return nil
    }

    private func screenForDisplayNumber(_ screenNumber: UInt32?) -> NSScreen? {
        guard let screenNumber else { return nil }
        return NSScreen.screens.first { screen in
            self.screenNumber(for: screen) == screenNumber
        }
    }

    private func screenNumber(for screen: NSScreen?) -> UInt32? {
        guard let screen else { return nil }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func insertionAnchorRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focusedElement = focusedElement() else { return nil }

        if let editableAnchor = editableAnchorElement(startingAt: focusedElement) {
            let editableBounds = focusedElementBounds(for: editableAnchor)
            if let focusedBounds = editableBounds {
                return anchorRect(fromFocusedBounds: focusedBounds)
            }
            if let insertionBounds = insertionBounds(for: editableAnchor),
               isUsableInsertionBounds(insertionBounds, within: editableBounds) {
                return insertionBounds
            }
        }

        if let windowBounds = focusedWindowBounds(from: focusedElement) {
            return anchorRect(fromFocusedWindowBounds: windowBounds)
        }

        return nil
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private func insertionBounds(for focusedElement: AXUIElement) -> NSRect? {
        var selectedRangeRef: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard selectedRangeResult == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let selectedRangeAXValue = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(selectedRangeAXValue) == .cfRange else {
            return nil
        }

        var boundsRef: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeAXValue,
            &boundsRef
        )
        guard boundsResult == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsAXValue = unsafeBitCast(boundsRef, to: AXValue.self)
        guard AXValueGetType(boundsAXValue) == .cgRect else {
            return nil
        }

        var cgRect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &cgRect) else {
            return nil
        }

        if let normalized = normalizeAccessibilityRectToScreen(cgRect) {
            return normalized
        }
        return nil
    }

    private func isUsableInsertionBounds(_ bounds: NSRect, within focusedBounds: NSRect?) -> Bool {
        guard bounds.minX.isFinite,
              bounds.minY.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite else {
            return false
        }

        if bounds.width <= 0.5 && bounds.height <= 0.5 {
            return false
        }

        let point = NSPoint(x: bounds.midX, y: bounds.midY)
        guard screenContaining(point: point) != nil else {
            return false
        }

        if let focusedBounds {
            let expandedBounds = focusedBounds.insetBy(dx: -24, dy: -24)
            return expandedBounds.contains(point)
        }

        return true
    }

    private func focusedElementBounds(for focusedElement: AXUIElement) -> NSRect? {
        guard
            let position = pointAttribute(kAXPositionAttribute as CFString, on: focusedElement),
            let size = sizeAttribute(kAXSizeAttribute as CFString, on: focusedElement),
            size.width > 0,
            size.height > 0
        else {
            return nil
        }

        let candidate = CGRect(origin: position, size: size)
        return normalizeAccessibilityRectToScreen(candidate)
    }

    private func focusedWindowBounds(from focusedElement: AXUIElement) -> NSRect? {
        guard let windowElement = elementAttribute(kAXWindowAttribute as CFString, on: focusedElement) else {
            return nil
        }
        return focusedElementBounds(for: windowElement)
    }

    private func editableAnchorElement(startingAt focusedElement: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = focusedElement
        var depth = 0

        while let element = current, depth < 8 {
            if isEditableTextElement(element) {
                return element
            }
            current = elementAttribute(kAXParentAttribute as CFString, on: element)
            depth += 1
        }

        return nil
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        if boolAttribute("AXEditable" as CFString, on: element) == true {
            return true
        }

        let role = (stringAttribute(kAXRoleAttribute as CFString, on: element) ?? "").lowercased()
        if role == "axtextfield" || role == "axtextarea" || role == "axsearchfield" || role == "axcombobox" {
            return true
        }

        let hasTextRange = hasAttribute(kAXSelectedTextRangeAttribute as CFString, on: element)
        let hasTextValue = hasAttribute(kAXValueAttribute as CFString, on: element)
        return hasTextRange && hasTextValue
    }

    private func anchorRect(fromFocusedBounds bounds: NSRect) -> NSRect {
        // Center the HUD over the text area and place it just above the field.
        let anchorX = bounds.midX
        let anchorY = bounds.maxY
        return NSRect(x: anchorX, y: anchorY, width: 1, height: 1)
    }

    private func anchorRect(fromFocusedWindowBounds bounds: NSRect) -> NSRect {
        let anchorX = bounds.midX
        let anchorY = bounds.minY + min(180, max(68, bounds.height * 0.18))
        return NSRect(x: anchorX, y: anchorY, width: 1, height: 1)
    }

    private func elementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success, let number = valueRef as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private func hasAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID() else {
            return nil
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func normalizeAccessibilityRectToScreen(_ rect: CGRect) -> NSRect? {
        // Accessibility API always uses top-left screen origin; NSScreen uses
        // bottom-left. Always flip Y to convert correctly, regardless of where
        // the mouse happens to be.
        if let flipped = normalizedFlippedRect(for: rect) {
            return flipped
        }
        // Fallback: use the raw rect if flipping lands off-screen (shouldn't
        // happen in practice, but keeps the path safe).
        let direct = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        let directPoint = NSPoint(x: direct.midX, y: direct.midY)
        return screenContaining(point: directPoint) != nil ? direct : nil
    }

    private func normalizedFlippedRect(for rect: CGRect) -> NSRect? {
        // AX coordinates use the primary display's top-left as origin.
        // The primary screen is always screens[0] and has frame.origin == .zero.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = primaryHeight - rect.origin.y - rect.height
        let flipped = NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        let flippedPoint = NSPoint(x: flipped.midX, y: flipped.midY)
        return screenContaining(point: flippedPoint) == nil ? nil : flipped
    }

    private func mouseAnchorRect() -> NSRect {
        let point = NSEvent.mouseLocation
        return NSRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private func usableAnchorRect(from candidate: NSRect?) -> NSRect? {
        guard var candidate else { return nil }
        guard candidate.minX.isFinite,
              candidate.minY.isFinite,
              candidate.width.isFinite,
              candidate.height.isFinite else {
            return nil
        }

        if candidate.width <= 0 {
            candidate.size.width = 1
        }
        if candidate.height <= 0 {
            candidate.size.height = 1
        }

        let point = NSPoint(x: candidate.midX, y: candidate.midY)
        guard screenContaining(point: point) != nil else {
            return nil
        }

        if abs(candidate.minX) < 0.5 && abs(candidate.minY) < 0.5 {
            return nil
        }

        return candidate
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }
}

private struct PromptRewriteDiscussionPage: Identifiable, Equatable {
    let id: UUID
    let originalText: String
    let suggestion: PromptRewriteSuggestion
}

private struct PromptRewriteLoadingView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(AppVisualTheme.accentTint)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            PromptRewriteGlassSurface(cornerRadius: 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.clear, lineWidth: 0)
        )
        .shadow(
            color: tokens.cardShadowColor.opacity(0.78),
            radius: max(7, tokens.cardShadowRadius * 0.62),
            x: 0,
            y: max(3, tokens.cardShadowYOffset * 0.72)
        )
        .frame(
            width: PromptRewriteHUDLayout.loadingSize.width,
            height: PromptRewriteHUDLayout.loadingSize.height,
            alignment: .center
        )
    }
}

private struct PromptRewriteHUDView: View {
    let pages: [PromptRewriteDiscussionPage]
    let selectedIndex: Int
    let bubbleEdge: PromptRewriteBubbleEdge
    let bubbleOffsetX: CGFloat
    let onSelectPage: (Int) -> Void
    let onChoice: (PromptRewritePreviewChoice) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isPresented = false

    private var safeSelectedIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(0, selectedIndex), pages.count - 1)
    }

    private var selectedPage: PromptRewriteDiscussionPage? {
        guard !pages.isEmpty else { return nil }
        return pages[safeSelectedIndex]
    }

    var body: some View {
        Group {
            if let selectedPage {
                compactSuggestion(for: selectedPage)
            } else {
                Text("No suggestion available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .appThemedSurface(
                        cornerRadius: 14,
                        tint: AppVisualTheme.panelTint,
                        strokeOpacity: 0.12,
                        tintOpacity: 0.03
                    )
            }
        }
        .frame(width: PromptRewriteHUDLayout.panelWidth)
        .tint(AppVisualTheme.accentTint)
        .scaleEffect(isPresented ? 1 : 0.985, anchor: bubbleEdge == .bottom ? .bottom : .top)
        .offset(y: isPresented ? 0 : (bubbleEdge == .bottom ? 8 : -8))
        .opacity(isPresented ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84, blendDuration: 0.08)) {
                isPresented = true
            }
        }
    }

    @ViewBuilder
    private func compactSuggestion(for page: PromptRewriteDiscussionPage) -> some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        HStack(alignment: .top, spacing: 11) {
            HStack(spacing: 9) {
                AppIconBadge(
                    symbol: "sparkles",
                    tint: AppVisualTheme.accentTint,
                    size: 20,
                    symbolSize: 9,
                    isEmphasized: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI suggestion")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.95))
                    if pages.count > 1 {
                        Text("\(safeSelectedIndex + 1)/\(pages.count) queued")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                }
            }
            .frame(width: 112, alignment: .leading)

            Capsule(style: .continuous)
                .fill(
                        LinearGradient(
                            colors: [
                                tokens.strokeTop.opacity(0.54),
                                tokens.strokeMid.opacity(0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                    )
                )
                .frame(width: 1, height: 26)

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(page.suggestion.suggestedText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.90))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 62)

                HStack {
                    Text("Enter inserts • Esc keeps original")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.66))

                    Spacer()

                    Button("Insert") {
                        onChoice(.useSuggested)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppVisualTheme.accentTint.opacity(0.26))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tokens.strokeTop.opacity(0.26), lineWidth: 0.6)
                    )
                    .controlSize(.small)
                        .foregroundStyle(Color.white.opacity(0.95))
                }

                if let duration = page.suggestion.refinementDurationSeconds {
                    Text("Refined in \(formattedDuration(duration))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PromptRewriteGlassSurface(cornerRadius: PromptRewriteHUDLayout.cornerRadius)
        }
        .clipShape(RoundedRectangle(cornerRadius: PromptRewriteHUDLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PromptRewriteHUDLayout.cornerRadius, style: .continuous)
                .stroke(.clear, lineWidth: 0)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            onDragChanged(value.translation)
                        }
                        .onEnded { value in
                            onDragEnded(value.translation)
                        }
                )
        }
        .overlay(alignment: bubbleEdge == .bottom ? .bottom : .top) {
            bubbleTail
                .offset(x: bubbleOffsetX, y: bubbleEdge == .bottom ? 6 : -6)
        }
        .shadow(
            color: tokens.cardShadowColor,
            radius: max(10, tokens.cardShadowRadius),
            x: 0,
            y: max(4, tokens.cardShadowYOffset)
        )
        .onExitCommand {
            onChoice(.insertOriginal)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 {
            return String(format: "%.0f ms", clamped * 1000)
        }
        if clamped < 10 {
            return String(format: "%.1f s", clamped)
        }
        return String(format: "%.0f s", clamped)
    }

    private var bubbleTail: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )

        return Circle()
            .fill(
                LinearGradient(
                    colors: [
                        tokens.surfaceTop.opacity(0.96),
                        tokens.surfaceBottom.opacity(0.98)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 12, height: 12)
    }
}

private struct PromptRewriteMaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: .zero)
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

private struct PromptRewriteGlassSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let tokens = AppVisualTheme.glassTokens(
            style: SettingsStore.shared.appChromeStyle,
            reduceTransparency: reduceTransparency
        )
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if tokens.useMaterial {
                PromptRewriteMaterialView(
                    material: tokens.surfaceMaterial,
                    blendingMode: tokens.surfaceBlendingMode
                )
                .opacity(tokens.materialOpacity * 0.48)
            } else {
                tokens.surfaceBottom.opacity(0.96)
            }
            LinearGradient(
                colors: [
                    tokens.surfaceTop.opacity(0.86),
                    AppVisualTheme.baseTint.opacity(0.20),
                    tokens.surfaceBottom.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        tokens.glowRed.opacity(0.22),
                        tokens.glowBlue.opacity(0.20),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: max(56, cornerRadius * 2.4))
                Spacer(minLength: 0)
            }
            RadialGradient(
                colors: [
                    tokens.glowRed.opacity(0.34),
                    Color.clear
                ],
                center: .bottomLeading,
                startRadius: 18,
                endRadius: 320
            )
            RadialGradient(
                colors: [
                    tokens.glowBlue.opacity(0.32),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 340
            )
            LinearGradient(
                colors: [
                    Color.black.opacity(tokens.useMaterial ? 0.12 : 0.16),
                    Color.black.opacity(tokens.useMaterial ? 0.22 : 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(shape)
    }
}
