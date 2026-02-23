import AppKit
import SwiftUI

@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    private let settingsDefaultSize = NSSize(width: 900, height: 680)
    private let settingsMinimumSize = NSSize(width: 820, height: 560)
    private let historyDefaultSize = NSSize(width: 620, height: 500)
    private let historyMinimumSize = NSSize(width: 520, height: 360)
    private let onboardingDefaultSize = NSSize(width: 620, height: 460)
    private let onboardingMinimumSize = NSSize(width: 560, height: 420)

    private let settings: SettingsStore
    private let transcriptHistory: TranscriptHistoryStore
    private let onStatusUpdate: (DictationUIStatus) -> Void
    private let onInsertText: (String) -> Void

    private var settingsWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var historyTargetApplication: NSRunningApplication?
    private var onboardingCompletion: (() -> Void)?

    init(
        settings: SettingsStore,
        transcriptHistory: TranscriptHistoryStore,
        onStatusUpdate: @escaping (DictationUIStatus) -> Void,
        onInsertText: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.transcriptHistory = transcriptHistory
        self.onStatusUpdate = onStatusUpdate
        self.onInsertText = onInsertText
        super.init()
    }

    func openSettingsWindow() {
        onStatusUpdate(.openingSettings)

        if settingsWindowController == nil {
            let hostingController = NSHostingController(rootView: SettingsView().environmentObject(settings))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: settingsDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = "KeyScribe Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.minSize = settingsMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            settingsWindowController = NSWindowController(window: window)
        }

        guard let window = settingsWindowController?.window else {
            onStatusUpdate(.message("Could not open settings"))
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < settingsMinimumSize.width || window.frame.height < settingsMinimumSize.height {
            window.setContentSize(settingsDefaultSize)
        }
        centerWindowOnActiveScreen(window)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        onStatusUpdate(.ready)
    }

    func openPermissionOnboardingWindow(onComplete: @escaping () -> Void) {
        onboardingCompletion = onComplete

        if onboardingWindowController == nil {
            let onboardingView = PermissionOnboardingView(onComplete: { [weak self] in
                guard let self else { return }
                self.onboardingCompletion?()
            })
            .environmentObject(settings)

            let hostingController = NSHostingController(rootView: onboardingView)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: onboardingDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = "KeyScribe Permission Setup"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.contentViewController = hostingController
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.minSize = onboardingMinimumSize
            centerWindowOnActiveScreen(window)
            window.delegate = self

            onboardingWindowController = NSWindowController(window: window)
        }

        guard let window = onboardingWindowController?.window else {
            onStatusUpdate(.message("Could not open permission setup"))
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < onboardingMinimumSize.width || window.frame.height < onboardingMinimumSize.height {
            window.setContentSize(onboardingDefaultSize)
        }
        centerWindowOnActiveScreen(window)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func closePermissionOnboardingWindow() {
        onboardingWindowController?.close()
        onboardingWindowController = nil
    }

    func openHistoryWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            historyTargetApplication = frontmost
        }

        if historyWindowController == nil {
            let historyView = TranscriptHistoryView(
                onCopy: { [weak self] text in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    self?.onStatusUpdate(.copiedFromHistory)
                },
                onReinsert: { [weak self] text in
                    self?.reinsertFromHistory(text)
                }
            )
            .environmentObject(transcriptHistory)

            let hostingController = NSHostingController(rootView: historyView)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: historyDefaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Transcript History"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.toolbarStyle = .unifiedCompact
            panel.contentViewController = hostingController
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.minSize = historyMinimumSize
            panel.center()
            panel.delegate = self

            historyWindowController = NSWindowController(window: panel)
        }

        guard let window = historyWindowController?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        historyWindowController?.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if window.frame.width < historyMinimumSize.width || window.frame.height < historyMinimumSize.height {
            window.setContentSize(historyDefaultSize)
            window.center()
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func closeAllWindows() {
        onboardingWindowController?.close()
        onboardingWindowController = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        historyWindowController?.close()
        historyWindowController = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow {
            if closingWindow === settingsWindowController?.window {
                settingsWindowController = nil
            } else if closingWindow === historyWindowController?.window {
                historyWindowController = nil
            } else if closingWindow === onboardingWindowController?.window {
                onboardingWindowController = nil
            }
        }
    }

    private func reinsertFromHistory(_ text: String) {
        guard !text.isEmpty else { return }

        if let target = historyTargetApplication, !target.isTerminated {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.onInsertText(text)
            }
        } else {
            onInsertText(text)
        }
    }

    private func centerWindowOnActiveScreen(_ window: NSWindow) {
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            window.center()
            return
        }

        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2)
        )
        window.setFrameOrigin(origin)
    }
}
