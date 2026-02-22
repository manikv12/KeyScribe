import AppKit
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
    private let transcriber = SpeechTranscriber()
    private let settings = SettingsStore.shared
    private let waveform = WaveformHUDManager()
    private var hotkeyManager: HoldToTalkManager?
    private let transcriptHistory = TranscriptHistoryStore.shared
    private var windowCoordinator: AppWindowCoordinator?

    private var statusItem: NSStatusItem?
    private var statusLabelItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var lastTargetApplication: NSRunningApplication?
    private var currentAudioLevel: Float = 0
    private var isDictating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        windowCoordinator = AppWindowCoordinator(
            settings: settings,
            transcriptHistory: transcriptHistory,
            onStatusUpdate: { [weak self] status in
                self?.setUIStatus(status)
            },
            onInsertText: { [weak self] text in
                self?.insertText(text, forceCopyToClipboard: true)
            }
        )

        settings.refreshMicrophones(notifyChange: false)
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            preferOnDeviceRecognition: settings.preferOnDeviceRecognition,
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
                    self?.setUIStatus(.ready)
                } else {
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

        transcriber.requestPermissions()
        applyHotkeyMode()
        if !AXIsProcessTrusted() {
            setUIStatus(.accessibilityHint)
        }
        updateMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
        transcriber.stopRecording()
        waveform.hide()
        windowCoordinator?.closeAllWindows()
        windowCoordinator = nil
        isDictating = false
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

        startStopMenuItem = NSMenuItem(title: "Transcribe", action: #selector(toggleDictation), keyEquivalent: "")
        startStopMenuItem?.target = self
        menu.addItem(startStopMenuItem!)

        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistoryMenuItem(_:)), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenuItem(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
            preferOnDeviceRecognition: settings.preferOnDeviceRecognition,
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

        guard !settings.continuousMode else {
            return
        }

        hotkeyManager = HoldToTalkManager(
            keyCode: settings.shortcutKeyCode,
            modifiers: settings.shortcutModifierFlags,
            onStart: { [weak self] in self?.startRecording() },
            onStop: { [weak self] in self?.stopRecording() }
        )
        hotkeyManager?.start()
        updateMenuState()
    }

    @objc private func openSettingsMenuItem(_ sender: Any?) {
        windowCoordinator?.openSettingsWindow()
    }

    @objc private func openHistoryMenuItem(_ sender: Any?) {
        windowCoordinator?.openHistoryWindow()
    }

    @objc private func toggleDictation() {
        if isDictating {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isDictating else { return }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastTargetApplication = frontmost
        }

        currentAudioLevel = 0
        setUIStatus(.listening)
        waveform.show()

        let started = transcriber.startRecording()
        isDictating = started
        updateMenuState()

        if !started {
            setUIStatus(.ready)
        }
    }

    private func stopRecording() {
        guard isDictating else {
            waveform.hide()
            updateMenuState()
            return
        }

        setUIStatus(.finalizing)
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        waveform.hide()
        updateMenuState()
    }

    private func insertText(_ text: String, forceCopyToClipboard: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        attemptInsertText(text, copyToClipboard: settings.copyToClipboard || forceCopyToClipboard, attemptsRemaining: 5)
    }

    private func attemptInsertText(_ text: String, copyToClipboard: Bool, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            setUIStatus(.pasteUnavailable)
            lastTargetApplication = nil
            return
        }

        if let target = lastTargetApplication,
           !target.isTerminated,
           !target.isActive {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            if attemptsRemaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
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
            applyInsertionStatusMessage(statusMessage)
            lastTargetApplication = nil
        }
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
            currentAudioLevel = 0
            waveform.hide()
        }

        updateMenuState()
    }

    private func updateMenuState() {
        startStopMenuItem?.title = isDictating ? "Stop Transcribing" : "Transcribe"
        statusItem?.button?.image = makeStatusIcon(isRecording: isDictating, level: currentAudioLevel)
        statusItem?.button?.contentTintColor = nil
    }

    private func makeStatusIcon(isRecording: Bool, level: Float) -> NSImage? {
        let normalizedLevel = max(0, min(1, level))

        let symbol: NSImage?
        if #available(macOS 13.0, *) {
            let variableValue = isRecording ? max(0.12, Double(normalizedLevel)) : 0
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
                NSColor(calibratedRed: 0.73, green: 0.31, blue: 0.85, alpha: 1.0),
                NSColor(calibratedRed: 0.42, green: 0.56, blue: 0.96, alpha: 1.0),
                NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.96, alpha: 1.0)
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
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case shortcut = "Shortcut"
        case microphone = "Microphone"
        case recognition = "Recognition"

        var id: Self { self }
    }

    @EnvironmentObject private var settings: SettingsStore
    @State private var selectedSection: SettingsSection = .general
    @State private var isCapturingShortcut = false
    @State private var shortcutCaptureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("KeyScribe")
                .font(.title2)

            Picker("Section", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 4)

            ShortcutCaptureMonitor(
                isCapturing: $isCapturingShortcut,
                onCapture: { keyCode, modifiers in
                    let filteredModifiers = ShortcutValidation.filteredModifierRawValue(from: modifiers)
                    guard ShortcutValidation.isValid(keyCode: keyCode, modifiersRaw: filteredModifiers) else {
                        shortcutCaptureMessage = "Shortcut must use 2 or 3 keys. Try again."
                        return
                    }
                    settings.shortcutKeyCode = keyCode
                    settings.shortcutModifiers = filteredModifiers
                    if settings.continuousMode {
                        settings.continuousMode = false
                    }
                    shortcutCaptureMessage = nil
                    isCapturingShortcut = false
                },
                onCancel: {
                    shortcutCaptureMessage = nil
                    isCapturingShortcut = false
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)

            Divider()
            Text("Permission: Microphone + Speech Recognition")
                .foregroundStyle(.secondary)

            Text("Built to use Apple Speech + on-device recognition when available.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 450)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .general:
            Toggle("Use continuous mode", isOn: $settings.continuousMode)
                .help("Use the menu bar button to start/stop dictation until you stop it manually.")

            Toggle("Copy transcript to clipboard", isOn: $settings.copyToClipboard)
                .help("Disable to avoid filling clipboard history. If disabled, dictation is only pasted directly when possible.")

            if settings.continuousMode {
                Text("Continuous mode is enabled. Use the menu bar action to start/stop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hold-to-talk mode is active with your selected shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .shortcut:
            Text("Keyboard shortcut (hold-to-talk mode)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(shortcutSegments, id: \.self) { segment in
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

                HStack(alignment: .center, spacing: 10) {
                    Button(action: {
                        shortcutCaptureMessage = nil
                        isCapturingShortcut = true
                    }) {
                        Text(isCapturingShortcut ? "Listening..." : "Choose shortcut")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Use 2 or 3 keys, like ⌘+Space, ⌃+⌥+K, or ⌘+⌥.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isCapturingShortcut {
                    Text("Press your shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let shortcutCaptureMessage {
                    Text(shortcutCaptureMessage)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )

            if !isCurrentShortcutValid {
                Text("Shortcut must include exactly 2 or 3 keys. Choose a new shortcut.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if settings.continuousMode {
                Text("Continuous mode is enabled. This shortcut is saved for hold-to-talk mode.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hold your shortcut to talk.")
                    .foregroundStyle(.secondary)
            }
        case .microphone:
            Toggle("Auto-detect microphone", isOn: $settings.autoDetectMicrophone)

            Picker("Microphone", selection: $settings.selectedMicrophoneUID) {
                ForEach(settings.availableMicrophones) { mic in
                    Text(mic.name).tag(mic.uid)
                }
            }
            .disabled(settings.autoDetectMicrophone)

            Button("Refresh microphones") {
                settings.refreshMicrophones()
            }
            .disabled(settings.autoDetectMicrophone)

            if settings.availableMicrophones.isEmpty {
                Text("No microphones detected")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .recognition:
            Toggle("Use contextual language bias", isOn: $settings.enableContextualBias)
                .help("Boost likely words/phrases for better recognition.")

            Toggle("Preserve words across short pauses", isOn: $settings.keepTextAcrossPauses)
                .help("Helps avoid dropping earlier words when you pause briefly mid-sentence.")

            Toggle("Prefer on-device recognition (faster/private)", isOn: $settings.preferOnDeviceRecognition)
                .help("Turn off to allow Apple hybrid fallback for tougher speech cases.")

            Toggle("Enable Apple automatic punctuation", isOn: $settings.autoPunctuation)
                .help("Uses Apple Speech punctuation generation during recognition.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Finalize delay: \(Int(settings.finalizeDelaySeconds * 1000)) ms")
                    .font(.callout)
                Slider(value: $settings.finalizeDelaySeconds, in: 0.15...1.2, step: 0.05)
                Text("Lower = faster paste, higher = fewer cut-offs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Cleanup mode", selection: $settings.textCleanupModeRawValue) {
                ForEach(TextCleanupMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .help("Light keeps original phrasing; Aggressive normalizes punctuation/casing more strongly.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom phrases (comma or new line separated)")
                    .font(.callout)
                TextEditor(text: $settings.customContextPhrases)
                    .frame(height: 96)
                    .font(.callout)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                Text("Examples: names, products, acronyms, slang")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutSegments: [String] {
        ShortcutValidation.displaySegments(
            keyCode: settings.shortcutKeyCode,
            modifiersRaw: settings.shortcutModifiers
        )
    }

    private var isCurrentShortcutValid: Bool {
        ShortcutValidation.isValid(keyCode: settings.shortcutKeyCode, modifiersRaw: settings.shortcutModifiers)
    }

}

struct TranscriptHistoryView: View {
    @EnvironmentObject private var history: TranscriptHistoryStore
    let onCopy: (String) -> Void
    let onReinsert: (String) -> Void

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent dictations")
                .font(.headline)

            if history.entries.isEmpty {
                Text("No transcripts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(formatter.string(from: entry.createdAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") { onCopy(entry.text) }
                            Button("Re-insert") { onReinsert(entry.text) }
                        }
                        Text(entry.text)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding()
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
