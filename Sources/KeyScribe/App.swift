import AppKit
import AVFoundation
import Speech
import SwiftUI

@main
struct KeyScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PermissionPromptKeys {
        static let autoRestartAfterAccessibilityGrant = "KeyScribe.autoRestartAfterAccessibilityGrant"
    }

    private enum PasteLastTranscriptShortcut {
        static let keyCode: UInt16 = 9 // V
        static let modifiers: NSEvent.ModifierFlags = [.command, .option]
    }

    private let transcriber = SpeechTranscriber()
    private let settings = SettingsStore.shared
    private let waveform = WaveformHUDManager()
    private var hotkeyManager: HoldToTalkManager?
    private var continuousToggleHotkeyManager: OneShotHotkeyManager?
    private var pasteLastTranscriptHotkeyManager: OneShotHotkeyManager?
    private let transcriptHistory = TranscriptHistoryStore.shared
    private var windowCoordinator: AppWindowCoordinator?

    private var statusItem: NSStatusItem?
    private var statusLabelItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var accessibilityTrustObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var isRelaunchingForAccessibility = false
    private var awaitingAccessibilityGrant = false
    private var accessibilityGrantMonitorTimer: DispatchSourceTimer?
    private var accessibilityGrantMonitorDeadline: Date?
    private var lastExternalApplication: NSRunningApplication?
    private var lastTargetApplication: NSRunningApplication?
    private var currentAudioLevel: Float = 0
    private var isDictating = false
    private var dictationInputMode: DictationInputMode = .idle
    private var statusIconAnimationTimer: DispatchSourceTimer?
    private var statusIconAnimationPhase: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.install()
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()

        windowCoordinator = AppWindowCoordinator(
            settings: settings,
            transcriptHistory: transcriptHistory,
            onStatusUpdate: { [weak self] status in
                self?.setUIStatus(status)
            },
            onInsertText: { [weak self] text in
                self?.insertText(text)
            }
        )

        settings.refreshMicrophones(notifyChange: false)
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            recognitionMode: settings.recognitionMode,
            autoPunctuation: settings.autoPunctuation,
            finalizeDelaySeconds: settings.finalizeDelaySeconds,
            customContextPhrases: settings.customContextPhrases
        )

        transcriber.onStatusUpdate = { [weak self] message in
            Task { @MainActor in
                self?.setUIStatus(DictationUIStatus.fromTranscriberMessage(message))
            }
        }

        transcriber.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.currentAudioLevel = max(0, min(1, level))
                self?.waveform.updateLevel(level)
                self?.updateMenuState()
            }
        }

        transcriber.onRecordingStateChange = { [weak self] isRecording in
            Task { @MainActor in
                self?.isDictating = isRecording
                if !isRecording {
                    if let currentMode = self?.dictationInputMode {
                        self?.dictationInputMode = DictationInputModeStateMachine.onRecordingEnded(currentMode)
                    }
                    self?.stopStatusIconAnimation()
                    self?.setUIStatus(.ready)
                } else {
                    self?.startStatusIconAnimation()
                    self?.updateMenuState()
                }
            }
        }

        transcriber.onFinalText = { [weak self] text in
            guard let self else { return }
            let cleaned = TextCleanup.process(text, mode: self.settings.textCleanupMode)
            guard !cleaned.isEmpty else { return }

            self.transcriptHistory.add(cleaned)
            self.insertText(cleaned)
            Task { @MainActor in
                self.setUIStatus(.ready)
            }
        }

        settings.onChange = { [weak self] in
            Task { @MainActor in
                self?.applySettingsChanges()
            }
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                return
            }
            Task { @MainActor in
                self?.lastExternalApplication = app
            }
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
        }

        accessibilityTrustObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.accessibilityTrustDidBecomeGrantedNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.awaitingAccessibilityGrant {
                    self.setUIStatus(.message("Accessibility updated. Verifying access…"))
                    self.checkAccessibilityGrantProgress()
                }
            }
        }

        // Safe to call every launch; system prompts only appear when status is undecided.
        transcriber.requestPermissions(promptIfNeeded: true)
        maybeAutoPromptAccessibilityOnce()
        applyHotkeyMode()
        configurePasteLastTranscriptHotkey()
        updateMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let accessibilityTrustObserver {
            NotificationCenter.default.removeObserver(accessibilityTrustObserver)
            self.accessibilityTrustObserver = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        pasteLastTranscriptHotkeyManager?.stop()
        pasteLastTranscriptHotkeyManager = nil
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        stopAccessibilityGrantMonitor()
        stopStatusIconAnimation()
        transcriber.stopRecording()
        waveform.hide()
        windowCoordinator?.closeAllWindows()
        windowCoordinator = nil
        isDictating = false
        dictationInputMode = .idle
    }

    private func requestAccessibilityIfNeeded(prompt: Bool) {
        settings.refreshAccessibilityStatus(prompt: prompt)
        if !settings.accessibilityTrusted {
            setUIStatus(.accessibilityHint)
        }
    }

    private func maybeAutoPromptAccessibilityOnce() {
        settings.refreshAccessibilityStatus(prompt: false)
        guard !settings.accessibilityTrusted else { return }
        promptForAccessibilityAccessAtLaunch()
    }

    private var shouldAutoRestartAfterAccessibilityGrant: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PermissionPromptKeys.autoRestartAfterAccessibilityGrant) == nil {
            defaults.set(true, forKey: PermissionPromptKeys.autoRestartAfterAccessibilityGrant)
            return true
        }
        return defaults.bool(forKey: PermissionPromptKeys.autoRestartAfterAccessibilityGrant)
    }

    private func promptForAccessibilityAccessAtLaunch() {
        guard !settings.accessibilityTrusted else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Access Needed"
        alert.informativeText = "KeyScribe needs Accessibility access to paste text into other apps. Grant access in System Settings."
        alert.addButton(withTitle: "Grant Access")
        alert.addButton(withTitle: "Not Now")

        let autoRestartCheckbox = NSButton(
            checkboxWithTitle: "Restart KeyScribe automatically after access is granted",
            target: nil,
            action: nil
        )
        autoRestartCheckbox.state = shouldAutoRestartAfterAccessibilityGrant ? .on : .off
        alert.accessoryView = autoRestartCheckbox

        let response = alert.runModal()
        let autoRestartEnabled = autoRestartCheckbox.state == .on
        UserDefaults.standard.set(autoRestartEnabled, forKey: PermissionPromptKeys.autoRestartAfterAccessibilityGrant)

        if response == .alertFirstButtonReturn {
            beginAccessibilityGrantFlow()
        } else {
            setUIStatus(.accessibilityHint)
        }
    }

    private func beginAccessibilityGrantFlow() {
        awaitingAccessibilityGrant = true
        startAccessibilityGrantMonitor()
        requestAccessibilityIfNeeded(prompt: true)

        if settings.accessibilityTrusted {
            completeAccessibilityGrantFlow()
            return
        }

        setUIStatus(.message("Grant Accessibility in System Settings, then return to KeyScribe"))
        openAccessibilitySettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard awaitingAccessibilityGrant else { return }
        checkAccessibilityGrantProgress()
    }

    private func promptToRestartAfterAccessibilityGrant() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility Granted"
        alert.informativeText = "Restart KeyScribe now to apply Accessibility access for reliable paste and hotkeys."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            relaunchAfterAccessibilityGrant()
        } else {
            setUIStatus(.message("Accessibility granted. Restart KeyScribe to apply it."))
        }
    }

    private func relaunchAfterAccessibilityGrant() {
        guard !isRelaunchingForAccessibility else { return }
        isRelaunchingForAccessibility = true

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            isRelaunchingForAccessibility = false
            setUIStatus(.message("Accessibility granted. Please restart KeyScribe once."))
            return
        }

        setUIStatus(.message("Accessibility granted — restarting KeyScribe…"))

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.isRelaunchingForAccessibility = false
                    self.setUIStatus(.message("Accessibility granted. Restart KeyScribe manually."))
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startAccessibilityGrantMonitor() {
        stopAccessibilityGrantMonitor()
        accessibilityGrantMonitorDeadline = Date().addingTimeInterval(120)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.6)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkAccessibilityGrantProgress()
        }
        accessibilityGrantMonitorTimer = timer
        timer.resume()
    }

    private func stopAccessibilityGrantMonitor() {
        accessibilityGrantMonitorTimer?.cancel()
        accessibilityGrantMonitorTimer = nil
        accessibilityGrantMonitorDeadline = nil
    }

    private func checkAccessibilityGrantProgress() {
        guard awaitingAccessibilityGrant else {
            stopAccessibilityGrantMonitor()
            return
        }

        settings.refreshAccessibilityStatus(prompt: false)
        if settings.accessibilityTrusted {
            completeAccessibilityGrantFlow()
            return
        }

        if let deadline = accessibilityGrantMonitorDeadline, Date() >= deadline {
            stopAccessibilityGrantMonitor()
            setUIStatus(.accessibilityHint)
        }
    }

    private func completeAccessibilityGrantFlow() {
        guard awaitingAccessibilityGrant else { return }
        awaitingAccessibilityGrant = false
        stopAccessibilityGrantMonitor()

        if shouldAutoRestartAfterAccessibilityGrant {
            relaunchAfterAccessibilityGrant()
            return
        }

        if NSApp.isActive {
            promptToRestartAfterAccessibilityGrant()
        } else {
            setUIStatus(.message("Accessibility granted. Open KeyScribe to restart and apply it."))
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.image = makeStatusIcon(isRecording: false, level: 0)
        statusItem?.button?.toolTip = "KeyScribe"

        let menu = NSMenu()
        statusItem?.menu = menu

        menu.addItem(NSMenuItem(title: "KeyScribe", action: nil, keyEquivalent: ""))

        statusLabelItem = NSMenuItem(title: DictationUIStatus.ready.menuText, action: nil, keyEquivalent: "")
        menu.addItem(statusLabelItem!)

        menu.addItem(NSMenuItem.separator())

        startStopMenuItem = NSMenuItem(title: "Start Continuous Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        startStopMenuItem?.target = self
        menu.addItem(startStopMenuItem!)

        let pasteLastItem = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLastTranscriptMenuItem(_:)), keyEquivalent: "v")
        pasteLastItem.keyEquivalentModifierMask = [.command, .option]
        pasteLastItem.target = self
        menu.addItem(pasteLastItem)

        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistoryMenuItem(_:)), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenuItem(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(requestAccessibilityMenuItem(_:)), keyEquivalent: "")
        accessibilityItem.target = self
        accessibilityItem.isHidden = settings.accessibilityTrusted
        menu.addItem(accessibilityItem)
        self.accessibilityMenuItem = accessibilityItem

        if CrashReporter.hasLogs {
            let crashLogsItem = NSMenuItem(title: "View Crash Logs…", action: #selector(viewCrashLogs(_:)), keyEquivalent: "")
            crashLogsItem.target = self
            menu.addItem(crashLogsItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        if statusItem?.button != nil {
            statusItem?.button?.appearsDisabled = false
        }
    }

    private func applySettingsChanges() {
        settings.refreshMicrophones(notifyChange: false)
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            recognitionMode: settings.recognitionMode,
            autoPunctuation: settings.autoPunctuation,
            finalizeDelaySeconds: settings.finalizeDelaySeconds,
            customContextPhrases: settings.customContextPhrases
        )
        applyHotkeyMode()
        updateMenuState()
    }

    private func applyHotkeyMode() {
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil

        hotkeyManager = HoldToTalkManager(
            keyCode: settings.shortcutKeyCode,
            modifiers: settings.shortcutModifierFlags,
            onStart: { [weak self] in self?.startHoldToTalkDictation() },
            onStop: { [weak self] in self?.stopHoldToTalkDictation() }
        )
        hotkeyManager?.start()
        configureContinuousToggleHotkey()
        updateMenuState()
    }

    private func configureContinuousToggleHotkey() {
        if shortcutsConflict(
            lhsKeyCode: settings.continuousToggleShortcutKeyCode,
            lhsModifiers: settings.continuousToggleShortcutModifierFlags,
            rhsKeyCode: settings.shortcutKeyCode,
            rhsModifiers: settings.shortcutModifierFlags
        ) || shortcutsConflict(
            lhsKeyCode: settings.continuousToggleShortcutKeyCode,
            lhsModifiers: settings.continuousToggleShortcutModifierFlags,
            rhsKeyCode: PasteLastTranscriptShortcut.keyCode,
            rhsModifiers: PasteLastTranscriptShortcut.modifiers
        ) {
            setUIStatus(.message("Fix shortcut conflicts in Settings to enable continuous toggle hotkey"))
            return
        }

        continuousToggleHotkeyManager = OneShotHotkeyManager(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiers: settings.continuousToggleShortcutModifierFlags
        ) { [weak self] in
            self?.toggleContinuousDictation()
        }
        continuousToggleHotkeyManager?.start()
    }

    private func shortcutsConflict(
        lhsKeyCode: UInt16,
        lhsModifiers: NSEvent.ModifierFlags,
        rhsKeyCode: UInt16,
        rhsModifiers: NSEvent.ModifierFlags
    ) -> Bool {
        lhsKeyCode == rhsKeyCode && lhsModifiers == rhsModifiers
    }

    private func configurePasteLastTranscriptHotkey() {
        pasteLastTranscriptHotkeyManager?.stop()
        pasteLastTranscriptHotkeyManager = OneShotHotkeyManager(
            keyCode: PasteLastTranscriptShortcut.keyCode,
            modifiers: PasteLastTranscriptShortcut.modifiers
        ) { [weak self] in
            self?.pasteLastTranscriptFromHistory()
        }
        pasteLastTranscriptHotkeyManager?.start()
    }

    @objc private func openSettingsMenuItem(_ sender: Any?) {
        windowCoordinator?.openSettingsWindow()
    }

    @objc private func openHistoryMenuItem(_ sender: Any?) {
        windowCoordinator?.openHistoryWindow()
    }

    @objc private func viewCrashLogs(_ sender: Any?) {
        CrashReporter.revealInFinder()
    }

    @objc private func requestAccessibilityMenuItem(_ sender: Any?) {
        beginAccessibilityGrantFlow()
    }

    @objc private func pasteLastTranscriptMenuItem(_ sender: Any?) {
        pasteLastTranscriptFromHistory()
    }

    @objc private func toggleDictation() {
        toggleContinuousDictation()
    }

    private func startHoldToTalkDictation() {
        guard DictationInputModeStateMachine.onHoldStart(dictationInputMode) == .holdToTalk else {
            return
        }
        guard dictationInputMode == .idle else {
            return
        }

        startRecording()
        if isDictating {
            dictationInputMode = .holdToTalk
        }
    }

    private func stopHoldToTalkDictation() {
        guard DictationInputModeStateMachine.onHoldStop(dictationInputMode) == .idle else {
            return
        }
        stopRecording()
        dictationInputMode = .idle
    }

    private func toggleContinuousDictation() {
        let nextMode = DictationInputModeStateMachine.onContinuousToggle(dictationInputMode)
        guard nextMode != dictationInputMode else {
            // Hold-to-talk active: ignore continuous toggle until hold cycle ends.
            return
        }

        switch nextMode {
        case .continuous:
            startRecording()
            if isDictating {
                dictationInputMode = nextMode
                updateMenuState()
            }
        case .idle:
            dictationInputMode = nextMode
            stopRecording()
        case .holdToTalk:
            break
        }
    }

    private func startRecording() {
        guard !isDictating else { return }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
            lastTargetApplication = frontmost
        } else if let fallback = lastExternalApplication, !fallback.isTerminated {
            lastTargetApplication = fallback
        }

        currentAudioLevel = 0
        let started = transcriber.startRecording()
        isDictating = started

        if started {
            setUIStatus(.listening)
            waveform.show()
            startStatusIconAnimation()
        } else {
            waveform.hide()
            stopStatusIconAnimation()
            // If permissions are missing/undetermined, trigger the request path right away.
            transcriber.requestPermissions(promptIfNeeded: true)
        }

        updateMenuState()
    }

    private func stopRecording() {
        guard isDictating else {
            waveform.hide()
            stopStatusIconAnimation()
            updateMenuState()
            return
        }

        setUIStatus(.finalizing)
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        waveform.hide()
        stopStatusIconAnimation()
        updateMenuState()
    }

    private func insertText(_ text: String, forceCopyToClipboard: Bool = false, overrideCopyToClipboard: Bool? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard ensureAccessibilityReadyForInsertion() else { return }
        let copyToClipboard = overrideCopyToClipboard ?? (settings.copyToClipboard || forceCopyToClipboard)
        attemptInsertText(text, copyToClipboard: copyToClipboard, attemptsRemaining: 5)
    }

    private func pasteLastTranscriptFromHistory() {
        if isDictating {
            setUIStatus(.message("Stop transcribing before pasting last transcript"))
            return
        }

        guard let latest = transcriptHistory.entries.first?.text,
              !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setUIStatus(.message("No transcript in KeyScribe History"))
            return
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = frontmost
            lastTargetApplication = frontmost
        } else if let fallback = lastExternalApplication, !fallback.isTerminated {
            lastTargetApplication = fallback
        }

        // Privacy-first quick paste: always insert from KeyScribe history without copying to system clipboard.
        insertText(latest, overrideCopyToClipboard: false)
    }

    private func ensureAccessibilityReadyForInsertion() -> Bool {
        settings.refreshAccessibilityStatus(prompt: false)
        guard settings.accessibilityTrusted else {
            setUIStatus(.message("Enable Accessibility via menu: Grant Accessibility Access…"))
            return false
        }
        return true
    }

    private func attemptInsertText(_ text: String, copyToClipboard: Bool, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            if copyToClipboard {
                ensureClipboardFallback(text)
                setUIStatus(.message("Paste unavailable — copied to clipboard"))
            } else {
                setUIStatus(.message("Paste unavailable — transcript is in KeyScribe History"))
            }
            lastTargetApplication = nil
            return
        }

        if lastTargetApplication == nil,
           let fallback = lastExternalApplication,
           !fallback.isTerminated {
            lastTargetApplication = fallback
        }

        if let target = lastTargetApplication,
           !target.isTerminated,
           !target.isActive {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            if attemptsRemaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                    self?.attemptInsertText(text, copyToClipboard: copyToClipboard, attemptsRemaining: attemptsRemaining - 1)
                }
                return
            }

            // Activation failed repeatedly; fall back to best-effort insertion/copy behavior.
            lastTargetApplication = nil
        }

        let result = TextInserter.insert(text, copyToClipboard: copyToClipboard)
        let retryPlan = InsertionRetryPolicy.plan(
            for: result,
            retriesRemaining: attemptsRemaining - 1,
            debugStatus: TextInserter.lastDebugStatus
        )

        switch retryPlan {
        case let .retry(delay, nextRetriesRemaining):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptInsertText(text, copyToClipboard: copyToClipboard, attemptsRemaining: nextRetriesRemaining + 1)
            }

        case let .complete(statusMessage):
            if let statusMessage, statusMessage.hasPrefix("Paste unavailable") {
                if copyToClipboard {
                    ensureClipboardFallback(text)
                    let clipboardStatus = statusMessage.replacingOccurrences(
                        of: "Paste unavailable",
                        with: "Paste unavailable — copied to clipboard"
                    )
                    applyInsertionStatusMessage(clipboardStatus)
                } else {
                    let historyStatus = statusMessage.replacingOccurrences(
                        of: "Paste unavailable",
                        with: "Paste unavailable — transcript is in KeyScribe History"
                    )
                    applyInsertionStatusMessage(historyStatus)
                }
            } else {
                applyInsertionStatusMessage(statusMessage)
            }
            lastTargetApplication = nil
        }
    }

    private func ensureClipboardFallback(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(trimmed, forType: .string)
    }

    private func applyInsertionStatusMessage(_ statusMessage: String?) {
        guard let statusMessage else {
            return
        }

        if statusMessage == "Ready" {
            setUIStatus(.ready)
            return
        }

        if statusMessage.hasPrefix("Copied to clipboard") {
            if statusMessage == "Copied to clipboard" {
                setUIStatus(.copiedToClipboard)
            } else {
                setUIStatus(.message(statusMessage))
            }
            return
        }

        if statusMessage.hasPrefix("Paste unavailable") {
            if statusMessage == "Paste unavailable" {
                setUIStatus(.pasteUnavailable)
            } else {
                setUIStatus(.message(statusMessage))
            }
            return
        }

        setUIStatus(.message(statusMessage))
    }

    private func setUIStatus(_ status: DictationUIStatus) {
        statusLabelItem?.title = status.menuText

        if status.resetsDictationIndicators {
            isDictating = false
            dictationInputMode = .idle
            currentAudioLevel = 0
            waveform.hide()
            stopStatusIconAnimation()
        }

        updateMenuState()
    }

    private func updateMenuState() {
        startStopMenuItem?.title = dictationInputMode == .continuous
            ? "Stop Continuous Dictation"
            : "Start Continuous Dictation"
        accessibilityMenuItem?.isHidden = settings.accessibilityTrusted
        statusItem?.button?.image = makeStatusIcon(isRecording: isDictating, level: currentAudioLevel)
        statusItem?.button?.contentTintColor = nil
    }

    private func startStatusIconAnimation() {
        guard statusIconAnimationTimer == nil else { return }

        statusIconAnimationPhase = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.04, repeating: 0.08)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isDictating else {
                self.stopStatusIconAnimation()
                return
            }

            self.statusIconAnimationPhase += 0.38
            if self.statusIconAnimationPhase > (.pi * 2) {
                self.statusIconAnimationPhase -= (.pi * 2)
            }
            self.updateMenuState()
        }
        statusIconAnimationTimer = timer
        timer.resume()
    }

    private func stopStatusIconAnimation() {
        statusIconAnimationTimer?.cancel()
        statusIconAnimationTimer = nil
        statusIconAnimationPhase = 0
    }

    private func makeStatusIcon(isRecording: Bool, level: Float) -> NSImage? {
        let normalizedLevel = max(0, min(1, level))
        let waveMotion = Float((sin(statusIconAnimationPhase) + 1) * 0.5)
        let idlePulse = isRecording ? 0.10 + (0.07 * waveMotion) : 0
        let animatedLevel = isRecording ? max(normalizedLevel, idlePulse) : normalizedLevel

        let symbol: NSImage?
        if #available(macOS 13.0, *) {
            let variableValue = isRecording ? max(0.12, Double(animatedLevel)) : 0
            symbol = NSImage(systemSymbolName: "waveform", variableValue: variableValue, accessibilityDescription: "KeyScribe")
        } else {
            symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "KeyScribe")
        }

        guard let symbol else {
            return nil
        }

        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if isRecording {
            let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [
                NSColor.white,
                NSColor(calibratedWhite: 0.85, alpha: 1.0),
                NSColor(calibratedWhite: 0.70, alpha: 1.0)
            ])
            let combined = baseConfig.applying(paletteConfig)
            let configured = symbol.withSymbolConfiguration(combined)
            configured?.isTemplate = false
            return configured
        }

        let configured = symbol.withSymbolConfiguration(baseConfig)
        configured?.isTemplate = true
        return configured
    }
}

struct SettingsView: View {
    private enum SettingsSection: CaseIterable, Identifiable {
        case general
        case shortcuts
        case microphone
        case recognition
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .microphone: return "Microphone"
            case .recognition: return "Recognition"
            case .about: return "About & Permissions"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "Output, clipboard, and appearance"
            case .shortcuts: return "Hold-to-talk and continuous toggle keys"
            case .microphone: return "Input device selection and refresh"
            case .recognition: return "Accuracy, cleanup, and timing controls"
            case .about: return "Permission health, diagnostics, and uninstall"
            }
        }

        var iconName: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .microphone: return "mic.fill"
            case .recognition: return "waveform"
            case .about: return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .blue
            case .shortcuts: return .indigo
            case .microphone: return .red
            case .recognition: return .green
            case .about: return .orange
            }
        }

        var searchTerms: [String] {
            switch self {
            case .general:
                return ["general", "clipboard", "waveform", "accessibility", "output"]
            case .shortcuts:
                return ["shortcut", "keyboard", "hold to talk", "continuous", "hotkey"]
            case .microphone:
                return ["microphone", "input", "device", "audio"]
            case .recognition:
                return ["recognition", "punctuation", "context", "cleanup", "delay"]
            case .about:
                return ["about", "permission", "uninstall", "version", "crash logs"]
            }
        }
    }

    private enum ShortcutCaptureTarget {
        case holdToTalk
        case continuousToggle
    }

    private struct ShortcutBinding: Equatable {
        let keyCode: UInt16
        let modifiersRaw: UInt
    }

    private struct SettingSearchEntry: Identifiable {
        let section: SettingsSection
        let title: String
        let detail: String
        let keywords: [String]

        var id: String {
            "\(section.title)-\(title)"
        }
    }

    private enum ReservedShortcut {
        static let pasteLastKeyCode: UInt16 = 9 // V
        static let pasteLastModifiersRaw: UInt = NSEvent.ModifierFlags([.command, .option]).rawValue
    }

    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedSection: SettingsSection = .general
    @State private var searchQuery = ""
    @State private var isCapturingShortcut = false
    @State private var shortcutCaptureTarget: ShortcutCaptureTarget?
    @State private var shortcutCaptureMessage: String?
    @State private var showUninstallConfirmation = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.80)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                settingsHeader
                Divider()
                HStack(spacing: 0) {
                    settingsSidebar
                    Divider()
                    settingsDetailPane
                }
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))

            ShortcutCaptureMonitor(
                isCapturing: $isCapturingShortcut,
                onCapture: { keyCode, modifiers in
                    let filteredModifiers = ShortcutValidation.filteredModifierRawValue(from: modifiers)
                    guard ShortcutValidation.isValid(keyCode: keyCode, modifiersRaw: filteredModifiers) else {
                        shortcutCaptureMessage = "Shortcut must use 2 or 3 keys. Try again."
                        return
                    }

                    guard let target = shortcutCaptureTarget else {
                        return
                    }

                    if let conflictMessage = shortcutConflictMessage(
                        for: target,
                        keyCode: keyCode,
                        modifiersRaw: filteredModifiers
                    ) {
                        shortcutCaptureMessage = conflictMessage
                        return
                    }

                    switch target {
                    case .holdToTalk:
                        settings.shortcutKeyCode = keyCode
                        settings.shortcutModifiers = filteredModifiers
                    case .continuousToggle:
                        settings.continuousToggleShortcutKeyCode = keyCode
                        settings.continuousToggleShortcutModifiers = filteredModifiers
                    }

                    shortcutCaptureMessage = nil
                    shortcutCaptureTarget = nil
                    isCapturingShortcut = false
                },
                onCancel: {
                    shortcutCaptureMessage = nil
                    shortcutCaptureTarget = nil
                    isCapturingShortcut = false
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
        }
        .frame(minWidth: 860, idealWidth: 900, minHeight: 620, idealHeight: 680)
        .onChange(of: searchQuery) { _ in
            guard !trimmedSearchQuery.isEmpty else { return }
            if let firstMatch = filteredSearchEntries.first {
                selectedSection = firstMatch.section
            } else if let firstSection = filteredSections.first {
                selectedSection = firstSection
            }
        }
    }

    @ViewBuilder
    private var settingsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KeyScribe Settings")
                    .font(.title2.weight(.semibold))
                Text("Use search or the sidebar to quickly find any setting.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !trimmedSearchQuery.isEmpty {
                Button("Clear Search") {
                    searchQuery = ""
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search settings…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)

            VStack(spacing: 6) {
                ForEach(filteredSections) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        sidebarSectionRow(for: section)
                    }
                    .buttonStyle(.plain)
                }
            }

            if filteredSections.isEmpty {
                Text("No matching sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 260, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebarSectionRow(for section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        let matchCount = matchCount(for: section)

        HStack(spacing: 10) {
            Image(systemName: section.iconName)
                .foregroundStyle(isSelected ? section.tint : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(section.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !trimmedSearchQuery.isEmpty && matchCount > 0 {
                Text("\(matchCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(section.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(section.tint.opacity(0.14))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? section.tint.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? section.tint.opacity(0.40) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var settingsDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !trimmedSearchQuery.isEmpty {
                    searchHighlightsCard
                }

                HStack(spacing: 10) {
                    Image(systemName: selectedSection.iconName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(selectedSection.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedSection.title)
                            .font(.title3.weight(.semibold))
                        Text(selectedSection.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                sectionContent(for: selectedSection)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var searchHighlightsCard: some View {
        settingsCard(
            title: "Search Results",
            subtitle: "Matching controls for \"\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\""
        ) {
            if filteredSearchEntries.isEmpty {
                Text("No exact setting name matched. Try another keyword or use the section list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(filteredSearchEntries.prefix(7))) { entry in
                    Button {
                        selectedSection = entry.section
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.section.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(entry.section.tint)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(entry.section.tint.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionContent(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            generalSection
        case .shortcuts:
            shortcutsSection
        case .microphone:
            microphoneSection
        case .recognition:
            recognitionSection
        case .about:
            aboutSection
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            accessibilityCard

            settingsCard(title: "Dictation Output") {
                Toggle("Also copy transcript to system clipboard", isOn: $settings.copyToClipboard)
                    .help("Turn off to keep dictations out of clipboard history. Explicit Copy actions from History still copy as expected.")
            }

            settingsCard(title: "Waveform Appearance") {
                Picker("Waveform Theme", selection: $settings.waveformThemeRawValue) {
                    ForEach(WaveformTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose the color scheme for the recording waveform.")
            }

            settingsCard(title: "Quick Reference") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste last transcript shortcut: ⌥⌘V")
                    Text("Hold-to-talk: hold your shortcut while speaking.")
                    Text("Continuous mode: press your toggle shortcut to start/stop.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(
                title: "Hold-to-Talk Shortcut",
                subtitle: "Hold this shortcut while speaking."
            ) {
                shortcutSegmentRow(holdToTalkShortcutSegments)

                HStack(alignment: .center, spacing: 10) {
                    Button(action: {
                        beginShortcutCapture(for: .holdToTalk)
                    }) {
                        Text(isCapturingShortcut && shortcutCaptureTarget == .holdToTalk ? "Listening..." : "Choose Shortcut")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Use 2 or 3 keys, like ⌘+Space or ⌃+⌥+K.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isCapturingShortcut && shortcutCaptureTarget == .holdToTalk {
                    Text("Press hold-to-talk shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isHoldToTalkShortcutValid {
                    Text("Hold-to-talk shortcut must include exactly 2 or 3 keys.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            settingsCard(
                title: "Continuous Toggle Shortcut",
                subtitle: "Press once to start, press again to stop."
            ) {
                shortcutSegmentRow(continuousToggleShortcutSegments)

                HStack(alignment: .center, spacing: 10) {
                    Button(action: {
                        beginShortcutCapture(for: .continuousToggle)
                    }) {
                        Text(isCapturingShortcut && shortcutCaptureTarget == .continuousToggle ? "Listening..." : "Choose Shortcut")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Use 2 or 3 keys. Keep this different from hold-to-talk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isCapturingShortcut && shortcutCaptureTarget == .continuousToggle {
                    Text("Press continuous toggle shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isContinuousToggleShortcutValid {
                    Text("Continuous toggle shortcut must include 2 or 3 keys.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            settingsCard(title: "Reserved Shortcut") {
                Text("⌥⌘V is reserved for Paste Last Transcript and cannot be reassigned.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let shortcutCaptureMessage {
                Text(shortcutCaptureMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var microphoneSection: some View {
        settingsCard(title: "Input Device") {
            Toggle("Auto-detect microphone", isOn: $settings.autoDetectMicrophone)

            HStack {
                Picker("Microphone", selection: $settings.selectedMicrophoneUID) {
                    ForEach(settings.availableMicrophones) { mic in
                        Text(mic.name).tag(mic.uid)
                    }
                }
                .disabled(settings.autoDetectMicrophone)

                Button("Refresh") {
                    settings.refreshMicrophones()
                }
                .disabled(settings.autoDetectMicrophone)
            }

            if settings.availableMicrophones.isEmpty {
                Text("No microphones detected.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "Recognition Behavior") {
                Toggle("Use contextual language bias", isOn: $settings.enableContextualBias)
                    .help("Boost likely words/phrases for better recognition.")

                Toggle("Preserve words across short pauses", isOn: $settings.keepTextAcrossPauses)
                    .help("Helps avoid dropping earlier words when you pause briefly mid-sentence.")

                HStack {
                    Text("Recognition mode")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("", selection: $settings.recognitionModeRawValue) {
                        ForEach(RecognitionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .help(settings.recognitionMode.helpText)

                Text(settings.recognitionMode.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable Apple automatic punctuation", isOn: $settings.autoPunctuation)
                    .help("Uses Apple Speech punctuation generation during recognition.")
            }

            settingsCard(title: "Finalize Delay") {
                Text("Finalize delay: \(Int(settings.finalizeDelaySeconds * 1000)) ms")
                    .font(.callout.weight(.medium))
                Slider(value: $settings.finalizeDelaySeconds, in: 0.15...1.2, step: 0.05)
                Text("Lower = faster paste, higher = fewer cut-offs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsCard(title: "Cleanup & Vocabulary") {
                HStack {
                    Text("Cleanup mode")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("", selection: $settings.textCleanupModeRawValue) {
                        ForEach(TextCleanupMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                .help("Light keeps original phrasing; Aggressive normalizes punctuation/casing more strongly.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom phrases (comma or new line separated)")
                        .font(.callout.weight(.medium))
                    TextEditor(text: $settings.customContextPhrases)
                        .frame(height: 120)
                        .font(.callout)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                    Text("Examples: names, products, acronyms, slang")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func shortcutSegmentRow(_ segments: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(segments, id: \.self) { segment in
                Text(segment)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                    )
            }
        }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var searchEntries: [SettingSearchEntry] {
        [
            .init(section: .general, title: "Accessibility access", detail: "Grant or verify accessibility permission", keywords: ["accessibility", "permission", "grant"]),
            .init(section: .general, title: "Copy transcript to clipboard", detail: "Automatically copy dictation results", keywords: ["clipboard", "copy", "output"]),
            .init(section: .general, title: "Waveform theme", detail: "Choose visual waveform style", keywords: ["waveform", "theme", "appearance"]),
            .init(section: .shortcuts, title: "Hold-to-talk shortcut", detail: "Set keys for press-and-hold dictation", keywords: ["hold", "shortcut", "keyboard"]),
            .init(section: .shortcuts, title: "Continuous toggle shortcut", detail: "Set keys for start/stop dictation mode", keywords: ["continuous", "toggle", "shortcut"]),
            .init(section: .shortcuts, title: "Paste last transcript", detail: "Reserved shortcut: ⌥⌘V", keywords: ["paste", "last transcript", "reserved"]),
            .init(section: .microphone, title: "Auto-detect microphone", detail: "Automatically use best available input", keywords: ["microphone", "input", "auto"]),
            .init(section: .microphone, title: "Microphone device picker", detail: "Choose a specific microphone manually", keywords: ["microphone", "device", "picker"]),
            .init(section: .recognition, title: "Contextual language bias", detail: "Improve recognition with likely words", keywords: ["context", "bias", "recognition"]),
            .init(section: .recognition, title: "Preserve words across pauses", detail: "Prevent dropped words in short pauses", keywords: ["pause", "preserve", "recognition"]),
            .init(section: .recognition, title: "Prefer on-device recognition", detail: "Favor local/private speech processing", keywords: ["on-device", "privacy", "recognition"]),
            .init(section: .recognition, title: "Automatic punctuation", detail: "Enable punctuation from Apple Speech", keywords: ["punctuation", "speech"]),
            .init(section: .recognition, title: "Finalize delay", detail: "Control speed vs stability before insertion", keywords: ["delay", "finalize", "timing"]),
            .init(section: .recognition, title: "Cleanup mode", detail: "Light or aggressive text cleanup", keywords: ["cleanup", "mode"]),
            .init(section: .recognition, title: "Custom phrases", detail: "Add names, acronyms, and domain language", keywords: ["phrases", "vocabulary", "context"]),
            .init(section: .about, title: "Permission overview", detail: "See accessibility, mic, and speech status", keywords: ["permissions", "accessibility", "microphone", "speech"]),
            .init(section: .about, title: "Crash logs", detail: "Open existing crash logs in Finder", keywords: ["crash", "logs", "diagnostics"]),
            .init(section: .about, title: "Uninstall KeyScribe", detail: "Remove app and clear saved settings", keywords: ["uninstall", "remove", "reset"])
        ]
    }

    private var filteredSearchEntries: [SettingSearchEntry] {
        guard !trimmedSearchQuery.isEmpty else { return [] }
        return searchEntries.filter { entry in
            let haystack = ([entry.title, entry.detail] + entry.keywords).joined(separator: " ").lowercased()
            return haystack.contains(trimmedSearchQuery)
        }
    }

    private var filteredSections: [SettingsSection] {
        guard !trimmedSearchQuery.isEmpty else {
            return SettingsSection.allCases
        }

        let query = trimmedSearchQuery
        let fromSectionTerms = SettingsSection.allCases.filter { section in
            let sectionHaystack = ([section.title, section.subtitle] + section.searchTerms)
                .joined(separator: " ")
                .lowercased()
            return sectionHaystack.contains(query)
        }
        let fromEntries = Set(filteredSearchEntries.map(\.section))

        let combined = SettingsSection.allCases.filter { section in
            fromSectionTerms.contains(section) || fromEntries.contains(section)
        }
        return combined
    }

    private func matchCount(for section: SettingsSection) -> Int {
        filteredSearchEntries.filter { $0.section == section }.count
    }

    @ViewBuilder
    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: settings.accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.accessibilityTrusted ? .green : .orange)
                Text(settings.accessibilityTrusted ? "Accessibility access granted" : "Accessibility access required")
                    .font(.callout.weight(.semibold))
            }

            Text(settings.accessibilityTrusted
                 ? "KeyScribe can control paste and insertion reliably."
                 : "Enable KeyScribe in Privacy & Security → Accessibility so paste and text insertion work across apps.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Check again") {
                    settings.refreshAccessibilityStatus(prompt: false)
                }
                .buttonStyle(.bordered)

                if !settings.accessibilityTrusted {
                    Button("Grant Accessibility Access…") {
                        settings.refreshAccessibilityStatus(prompt: true)
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            settings.refreshAccessibilityStatus(prompt: false)
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private var holdToTalkShortcutSegments: [String] {
        ShortcutValidation.displaySegments(
            keyCode: settings.shortcutKeyCode,
            modifiersRaw: settings.shortcutModifiers
        )
    }

    private var continuousToggleShortcutSegments: [String] {
        ShortcutValidation.displaySegments(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiersRaw: settings.continuousToggleShortcutModifiers
        )
    }

    private var isHoldToTalkShortcutValid: Bool {
        ShortcutValidation.isValid(keyCode: settings.shortcutKeyCode, modifiersRaw: settings.shortcutModifiers)
    }

    private var isContinuousToggleShortcutValid: Bool {
        ShortcutValidation.isValid(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiersRaw: settings.continuousToggleShortcutModifiers
        )
    }

    private func beginShortcutCapture(for target: ShortcutCaptureTarget) {
        shortcutCaptureTarget = target
        shortcutCaptureMessage = nil
        isCapturingShortcut = true
    }

    private func shortcutConflictMessage(
        for target: ShortcutCaptureTarget,
        keyCode: UInt16,
        modifiersRaw: UInt
    ) -> String? {
        let candidate = ShortcutBinding(
            keyCode: keyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: modifiersRaw)
        )
        let holdToTalk = ShortcutBinding(
            keyCode: settings.shortcutKeyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: settings.shortcutModifiers)
        )
        let continuousToggle = ShortcutBinding(
            keyCode: settings.continuousToggleShortcutKeyCode,
            modifiersRaw: ShortcutValidation.filteredModifierRawValue(from: settings.continuousToggleShortcutModifiers)
        )
        let pasteLast = ShortcutBinding(
            keyCode: ReservedShortcut.pasteLastKeyCode,
            modifiersRaw: ReservedShortcut.pasteLastModifiersRaw
        )

        switch target {
        case .holdToTalk:
            if candidate == continuousToggle {
                return "Hold-to-talk shortcut cannot match continuous toggle shortcut."
            }
        case .continuousToggle:
            if candidate == holdToTalk {
                return "Continuous toggle shortcut cannot match hold-to-talk shortcut."
            }
        }

        if candidate == pasteLast {
            return "Shortcut cannot match Paste Last Transcript (⌥⌘V)."
        }

        return nil
    }

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Version info
            HStack(spacing: 10) {
                Image(systemName: "app.badge.checkmark.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KeyScribe")
                        .font(.headline)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Permissions status
            Text("Permissions")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    name: "Accessibility",
                    granted: settings.accessibilityTrusted,
                    hint: "Required for text insertion and global hotkeys",
                    action: {
                        settings.refreshAccessibilityStatus(prompt: true)
                        openAccessibilitySettings()
                    }
                )

                permissionRow(
                    name: "Microphone",
                    granted: microphoneAuthorized,
                    hint: "Required to capture speech",
                    action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )

                permissionRow(
                    name: "Speech Recognition",
                    granted: speechRecognitionAuthorized,
                    hint: "Required to transcribe speech to text",
                    action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )

            if CrashReporter.hasLogs {
                Divider()
                HStack {
                    Text("Crash logs available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal in Finder") {
                        CrashReporter.revealInFinder()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // Uninstall
            VStack(alignment: .leading, spacing: 6) {
                Text("Uninstall")
                    .font(.headline)
                Text("Remove KeyScribe, reset all permissions (Accessibility, Microphone, Speech Recognition), and delete saved settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive, action: {
                    showUninstallConfirmation = true
                }) {
                    Label("Uninstall KeyScribe…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .alert("Uninstall KeyScribe?", isPresented: $showUninstallConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Uninstall", role: .destructive) {
                        SettingsStore.resetAndUninstall()
                    }
                } message: {
                    Text("This will reset all permissions, delete your settings, and remove the app. You will be prompted for your admin password.")
                }
            }

            Text("Built with Apple Speech framework · on-device recognition when available")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func permissionRow(name: String, granted: Bool, hint: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout.weight(.medium))
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var microphoneAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } else {
            // Pre-Sonoma: if the app has been able to record, it's authorized
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    private var speechRecognitionAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

}


struct TranscriptHistoryView: View {
    @EnvironmentObject private var history: TranscriptHistoryStore
    let onCopy: (String) -> Void
    let onReinsert: (String) -> Void

    @State private var query = ""

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var filteredEntries: [TranscriptHistoryStore.Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcript History")
                            .font(.title3.weight(.semibold))
                        Text("Re-use recent dictation without recording again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(filteredEntries.count) of \(history.entries.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    TextField("Search transcripts", text: $query)
                        .textFieldStyle(.roundedBorder)

                    Button("Clear All", role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            history.clear()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(history.entries.isEmpty)
                }

                if history.entries.isEmpty {
                    emptyState(
                        title: "No transcripts yet",
                        message: "Your recent dictation will appear here automatically.",
                        systemImage: "text.bubble"
                    )
                } else if filteredEntries.isEmpty {
                    emptyState(
                        title: "No matches found",
                        message: "Try a different search phrase.",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredEntries) { entry in
                                TranscriptHistoryEntryCard(
                                    entry: entry,
                                    timestampText: timestampFormatter.string(from: entry.createdAt),
                                    relativeText: relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()),
                                    onCopy: { onCopy(entry.text) },
                                    onReinsert: {
                                        onReinsert(entry.text)
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            history.remove(id: entry.id)
                                        }
                                    },
                                    onDelete: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            history.remove(id: entry.id)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(1)
                    }
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct TranscriptHistoryEntryCard: View {
    let entry: TranscriptHistoryStore.Entry
    let timestampText: String
    let relativeText: String
    let onCopy: () -> Void
    let onReinsert: () -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false

    private var showsExpandButton: Bool {
        entry.text.count > 220 || entry.text.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(relativeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(timestampText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy transcript")

                    Button(action: onReinsert) {
                        Label("Re-insert", systemImage: "arrow.uturn.backward.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Insert transcript in the focused app")

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete transcript from history")
                }
            }

            Text(entry.text)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .lineSpacing(2)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 3)
                .foregroundStyle(.primary)

            if showsExpandButton {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct ShortcutCaptureMonitor: NSViewRepresentable {
    @Binding var isCapturing: Bool
    let onCapture: (UInt16, UInt) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isCapturing {
            context.coordinator.start()
        } else {
            context.coordinator.stop()
        }
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var parent: ShortcutCaptureMonitor
        private var globalKeyMonitor: Any?
        private var localKeyMonitor: Any?
        private var globalFlagsMonitor: Any?
        private var localFlagsMonitor: Any?
        private var didCapture = false

        init(parent: ShortcutCaptureMonitor) {
            self.parent = parent
        }

        func start() {
            guard globalKeyMonitor == nil, localKeyMonitor == nil, globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }
            didCapture = false

            let mask = ShortcutValidation.supportedModifierFlags

            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                _ = self?.handleKeyDown(event, mask: mask)
            }

            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let handled = self.handleKeyDown(event, mask: mask)
                return handled ? nil : event
            }

            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                _ = self?.handleFlagsChanged(event, mask: mask)
            }

            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let handled = self.handleFlagsChanged(event, mask: mask)
                return handled ? nil : event
            }
        }

        @discardableResult
        private func handleKeyDown(_ event: NSEvent, mask: NSEvent.ModifierFlags) -> Bool {
            guard !didCapture else { return true }

            if event.keyCode == 53 { // Escape
                didCapture = true
                DispatchQueue.main.async {
                    self.parent.isCapturing = false
                    self.parent.onCancel()
                    self.stop()
                }
                return true
            }

            let capturedCode = event.keyCode
            if ShortcutValidation.isModifierOnlyKeyCode(capturedCode) {
                return false
            }

            let capturedMods = ShortcutValidation.filteredModifierRawValue(from: event.modifierFlags.intersection(mask).rawValue)
            guard capturedMods != 0 else { return false }
            didCapture = true
            DispatchQueue.main.async {
                self.parent.onCapture(capturedCode, capturedMods)
            }
            return true
        }

        @discardableResult
        private func handleFlagsChanged(_ event: NSEvent, mask: NSEvent.ModifierFlags) -> Bool {
            guard !didCapture else { return true }

            let capturedFlags = event.modifierFlags.intersection(mask)
            let count = ShortcutValidation.modifierCount(in: capturedFlags)
            guard (2...3).contains(count) else { return false }

            didCapture = true
            DispatchQueue.main.async {
                self.parent.onCapture(UInt16.max, capturedFlags.rawValue)
            }
            return true
        }

        func stop() {
            if let globalKeyMonitor {
                NSEvent.removeMonitor(globalKeyMonitor)
                self.globalKeyMonitor = nil
            }
            if let localKeyMonitor {
                NSEvent.removeMonitor(localKeyMonitor)
                self.localKeyMonitor = nil
            }
            if let globalFlagsMonitor {
                NSEvent.removeMonitor(globalFlagsMonitor)
                self.globalFlagsMonitor = nil
            }
            if let localFlagsMonitor {
                NSEvent.removeMonitor(localFlagsMonitor)
                self.localFlagsMonitor = nil
            }
            didCapture = false
        }

        deinit {
            stop()
        }
    }
}
