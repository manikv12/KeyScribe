import AppKit
import SwiftUI

@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let transcriptHistory: TranscriptHistoryStore
    private let onStatusUpdate: (DictationUIStatus) -> Void
    private let onInsertText: (String) -> Void

    private var settingsWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private var historyTargetApplication: NSRunningApplication?

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
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )

            panel.title = "KeyScribe Settings"
            panel.contentViewController = hostingController
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.delegate = self

            settingsWindowController = NSWindowController(window: panel)
        }

        guard let window = settingsWindowController?.window else {
            onStatusUpdate(.message("Could not open settings"))
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        onStatusUpdate(.ready)
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
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                styleMask: [.titled, .closable, .utilityWindow, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Transcript History"
            panel.contentViewController = hostingController
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.delegate = self

            historyWindowController = NSWindowController(window: panel)
        }

        guard let window = historyWindowController?.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        historyWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func closeAllWindows() {
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
}
