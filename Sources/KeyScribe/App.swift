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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let transcriber = SpeechTranscriber()
    private let settings = SettingsStore.shared
    private let waveform = WaveformHUDManager()
    private var hotkeyManager: HoldToTalkManager?
    private var settingsWindowController: NSWindowController?

    private var statusItem: NSStatusItem?
    private var statusLabelItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var lastTargetApplication: NSRunningApplication?
    private var currentAudioLevel: Float = 0
    private var isDictating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        settings.refreshMicrophones()
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            preferOnDeviceRecognition: settings.preferOnDeviceRecognition,
            finalizeDelaySeconds: settings.finalizeDelaySeconds,
            customContextPhrases: settings.customContextPhrases
        )

        transcriber.onStatusUpdate = { [weak self] message in
            DispatchQueue.main.async {
                self?.statusLabelItem?.title = message
                if message == "Ready" {
                    self?.isDictating = false
                    self?.currentAudioLevel = 0
                    self?.waveform.hide()
                }
                self?.updateMenuState()
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
                self?.updateMenuState()
                if !isRecording {
                    self?.currentAudioLevel = 0
                    self?.waveform.hide()
                    self?.statusLabelItem?.title = "Ready"
                }
            }
        }

        transcriber.onFinalText = { [weak self] text in
            self?.insertText(text)
            Task { @MainActor in
                self?.statusLabelItem?.title = "Ready"
                self?.isDictating = false
                self?.currentAudioLevel = 0
                self?.waveform.hide()
                self?.updateMenuState()
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
            statusLabelItem?.title = "Enable Accessibility for reliable hotkeys"
        }
        updateMenuState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
        transcriber.stopRecording()
        waveform.hide()
        settingsWindowController?.close()
        settingsWindowController = nil
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

        statusLabelItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        menu.addItem(statusLabelItem!)

        menu.addItem(NSMenuItem.separator())

        startStopMenuItem = NSMenuItem(title: "Transcribe", action: #selector(toggleDictation), keyEquivalent: "")
        startStopMenuItem?.target = self
        menu.addItem(startStopMenuItem!)

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
        settings.refreshMicrophones()
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            preferOnDeviceRecognition: settings.preferOnDeviceRecognition,
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
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        statusLabelItem?.title = "Opening settings…"

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
            statusLabelItem?.title = "Could not open settings"
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        statusLabelItem?.title = "Ready"
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
        statusLabelItem?.title = "Listening…"
        waveform.show()
        updateMenuState()

        let started = transcriber.startRecording()
        isDictating = started

        if !started {
            statusLabelItem?.title = "Ready"
            isDictating = false
            currentAudioLevel = 0
            waveform.hide()
            updateMenuState()
        }
    }

    private func stopRecording() {
        guard isDictating else {
            waveform.hide()
            updateMenuState()
            return
        }

        statusLabelItem?.title = "Finalizing…"
        updateMenuState()
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        waveform.hide()
    }

    private func insertText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        attemptInsertText(text, retriesRemaining: 2)
    }

    private func attemptInsertText(_ text: String, retriesRemaining: Int) {
        if let target = lastTargetApplication,
           !target.isTerminated,
           !target.isActive {
            _ = target.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.attemptInsertText(text, retriesRemaining: retriesRemaining)
            }
            return
        }

        let result = TextInserter.insert(text, copyToClipboard: settings.copyToClipboard)
        switch result {
        case .pasted:
            statusLabelItem?.title = "Ready"
            lastTargetApplication = nil
        case .copiedOnly:
            if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.attemptInsertText(text, retriesRemaining: retriesRemaining - 1)
                }
            } else {
                statusLabelItem?.title = "Copied to clipboard"
                lastTargetApplication = nil
            }
        case .notInserted:
            if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.attemptInsertText(text, retriesRemaining: retriesRemaining - 1)
                }
            } else {
                statusLabelItem?.title = "Paste unavailable"
                lastTargetApplication = nil
            }
        case .empty:
            lastTargetApplication = nil
        }
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

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === settingsWindowController?.window {
            settingsWindowController = nil
        }
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
                    let filteredModifiers = NSEvent.ModifierFlags(rawValue: modifiers).intersection(shortcutModifierMask).rawValue
                    guard isValidShortcut(keyCode: keyCode, modifiers: filteredModifiers) else {
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Finalize delay: \(Int(settings.finalizeDelaySeconds * 1000)) ms")
                    .font(.callout)
                Slider(value: $settings.finalizeDelaySeconds, in: 0.15...1.2, step: 0.05)
                Text("Lower = faster paste, higher = fewer cut-offs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private var shortcutModifierMask: NSEvent.ModifierFlags {
        [.command, .option, .control, .shift, .function]
    }

    private var modifierOnlyKeyCodes: Set<UInt16> {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    }

    private var shortcutSegments: [String] {
        let flags = settings.shortcutModifierFlags.intersection(shortcutModifierMask)
        var segments: [String] = []

        if flags.contains(.function) { segments.append("Fn") }
        if flags.contains(.control) { segments.append("⌃") }
        if flags.contains(.option) { segments.append("⌥") }
        if flags.contains(.shift) { segments.append("⇧") }
        if flags.contains(.command) { segments.append("⌘") }

        if settings.shortcutKeyCode != UInt16.max {
            segments.append(keyName(for: settings.shortcutKeyCode))
        }

        return segments.isEmpty ? ["Not set"] : segments
    }

    private var isCurrentShortcutValid: Bool {
        isValidShortcut(keyCode: settings.shortcutKeyCode, modifiers: settings.shortcutModifiers)
    }

    private func isValidShortcut(keyCode: UInt16, modifiers: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers).intersection(shortcutModifierMask)
        let modifierCount = countModifiers(in: flags)

        if keyCode == UInt16.max {
            return (2...3).contains(modifierCount)
        }

        guard !modifierOnlyKeyCodes.contains(keyCode) else { return false }
        return (1...2).contains(modifierCount)
    }

    private func countModifiers(in flags: NSEvent.ModifierFlags) -> Int {
        var count = 0
        if flags.contains(.function) { count += 1 }
        if flags.contains(.control) { count += 1 }
        if flags.contains(.option) { count += 1 }
        if flags.contains(.shift) { count += 1 }
        if flags.contains(.command) { count += 1 }
        return count
    }

    private func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A",
            1: "S",
            2: "D",
            3: "F",
            4: "H",
            5: "G",
            6: "Z",
            7: "X",
            8: "C",
            9: "V",
            11: "B",
            12: "Q",
            13: "W",
            14: "E",
            15: "R",
            16: "Y",
            17: "T",
            18: "1",
            19: "2",
            20: "3",
            21: "4",
            22: "6",
            23: "5",
            24: "=",
            25: "9",
            26: "7",
            27: "-",
            28: "8",
            29: "0",
            30: "]",
            31: "O",
            32: "U",
            33: "[",
            34: "I",
            35: "P",
            36: "Return",
            37: "L",
            38: "J",
            39: "'",
            40: "K",
            41: ";",
            42: "\\\\",
            43: ",",
            44: "/",
            45: "N",
            46: "M",
            47: ".",
            48: "`",
            49: "Space",
            50: "`",
            51: "Delete",
            53: "Esc",
            122: "F1",
            120: "F2",
            99: "F3",
            118: "F4",
            96: "F5",
            97: "F6",
            98: "F7",
            100: "F8",
            101: "F9",
            109: "F10",
            103: "F11",
            111: "F12",
            105: "F13",
            107: "F14",
            113: "F15",
            106: "F16",
            64: "F17",
            79: "F18",
            80: "F19",
            90: "F20",
            63: "Fn"
        ]

        return names[code] ?? "Key \(code)"
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
        private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

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

            let mask = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function])

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
            if Self.modifierOnlyKeyCodes.contains(capturedCode) {
                return false
            }

            let capturedMods = event.modifierFlags.intersection(mask).rawValue
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
            let count = Self.countModifiers(in: capturedFlags)
            guard (2...3).contains(count) else { return false }

            didCapture = true
            DispatchQueue.main.async {
                self.parent.onCapture(UInt16.max, capturedFlags.rawValue)
            }
            return true
        }

        private static func countModifiers(in flags: NSEvent.ModifierFlags) -> Int {
            var count = 0
            if flags.contains(.function) { count += 1 }
            if flags.contains(.control) { count += 1 }
            if flags.contains(.option) { count += 1 }
            if flags.contains(.shift) { count += 1 }
            if flags.contains(.command) { count += 1 }
            return count
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
