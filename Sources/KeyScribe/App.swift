import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI

extension Notification.Name {
    static let keyScribeOpenAIMemoryStudio = Notification.Name("KeyScribe.openAIMemoryStudio")
}

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
    private enum PasteLastTranscriptShortcut {
        static let keyCode: UInt16 = 9 // V
        static let modifiers: NSEvent.ModifierFlags = [.command, .option]
    }

    private let transcriber = SpeechTranscriber()
    private let whisperModelManager = WhisperModelManager.shared
    private let settings = SettingsStore.shared
    private let adaptiveCorrectionStore = AdaptiveCorrectionStore.shared
    private let promptRewriteService = PromptRewriteService.shared
    private let postInsertCorrectionMonitor = PostInsertCorrectionMonitor()
    private let waveform = WaveformHUDManager()
    private var hotkeyManager: HoldToTalkManager?
    private var continuousToggleHotkeyManager: OneShotHotkeyManager?
    private var pasteLastTranscriptHotkeyManager: OneShotHotkeyManager?
    private let transcriptHistory = TranscriptHistoryStore.shared
    private var windowCoordinator: AppWindowCoordinator?

    private var statusItem: NSStatusItem?
    private let statusBarViewModel = StatusBarViewModel()
    private var popover: NSPopover?
    private var accessibilityTrustObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var aiStudioRequestObserver: NSObjectProtocol?
    private var adaptiveCorrectionObserver: AnyCancellable?
    private var permissionsReady = false
    private var didRequestStartupPermissionPrompt = false
    private var lastExternalApplication: NSRunningApplication?
    private var lastTargetApplication: NSRunningApplication?
    private var currentAudioLevel: Float = 0
    private var isDictating = false
    private var dictationInputMode: DictationInputMode = .idle
    private var statusIconAnimationTimer: DispatchSourceTimer?
    private var statusIconAnimationPhase: Double = 0
    private var hasScheduledPermissionRestart = false

    private enum PromptRewriteFailureChoice {
        case retry
        case insertOriginal
        case cancel
    }
    private enum DictationFeedbackCue: CaseIterable {
        case startListening
        case stopListening
        case processing
        case pasted
        case correctionLearned

        // Keep nonisolated defaults local so this enum can be used from non-main contexts
        // without reading @MainActor-isolated state from SettingsStore.
        private static let defaultStartSoundName = "Ping"
        private static let defaultStopSoundName = "Glass"
        private static let defaultProcessingSoundName = "Ping"
        private static let defaultPastedSoundName = "Pop"
        private static let defaultCorrectionLearnedSoundName = "Purr"

        var systemSoundName: String {
            switch self {
            case .startListening, .processing:
                return Self.defaultStartSoundName
            case .stopListening:
                return Self.defaultStopSoundName
            case .pasted:
                return Self.defaultPastedSoundName
            case .correctionLearned:
                return Self.defaultCorrectionLearnedSoundName
            }
        }

        @MainActor func resolvedSystemSoundName(settings: SettingsStore) -> String {
            switch self {
            case .startListening:
                return Self.resolveSoundName(settings.dictationStartSoundName, fallback: Self.startingFallback)
            case .stopListening:
                return Self.resolveSoundName(settings.dictationStopSoundName, fallback: Self.stopFallback)
            case .processing:
                return Self.resolveSoundName(settings.dictationProcessingSoundName, fallback: Self.processingFallback)
            case .pasted:
                return Self.resolveSoundName(settings.dictationPastedSoundName, fallback: Self.pastedFallback)
            case .correctionLearned:
                return Self.resolveSoundName(settings.dictationCorrectionLearnedSoundName, fallback: Self.correctionLearnedFallback)
            }
        }

        @MainActor static func resolveSoundName(_ selected: String, fallback: String) -> String {
            if selected == SettingsStore.noDictationSoundName {
                return ""
            }
            return SettingsStore.dictationStartSoundOptions.contains(selected)
                ? selected
                : fallback
        }

        private static var startingFallback: String {
            Self.defaultStartSoundName
        }

        private static var stopFallback: String {
            Self.defaultStopSoundName
        }

        private static var processingFallback: String {
            Self.defaultProcessingSoundName
        }

        private static var pastedFallback: String {
            Self.defaultPastedSoundName
        }

        private static var correctionLearnedFallback: String {
            Self.defaultCorrectionLearnedSoundName
        }

        var volumeMultiplier: Float {
            switch self {
            case .startListening:
                return 0.7
            default:
                return 1
            }
        }
    }

    private var dictationFeedbackSounds: [DictationFeedbackCue: NSSound] {
        var sounds: [DictationFeedbackCue: NSSound] = [:]
        for cue in DictationFeedbackCue.allCases {
            let soundName = cue.resolvedSystemSoundName(settings: settings)
            guard !soundName.isEmpty else { continue }
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sounds[cue] = sound
            }
        }
        return sounds
    }

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
        syncWhisperModelSelectionIfNeeded()
        observeAdaptiveCorrectionChanges()
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        applyRecognitionSettingsToTranscriber()
        transcriber.applyWhisperSettings(
            selectedModelID: settings.selectedWhisperModelID,
            useCoreML: settings.whisperUseCoreML
        )
        transcriber.setTranscriptionEngine(settings.transcriptionEngine)

        postInsertCorrectionMonitor.onCorrectionDetected = { [weak self] result in
            Task { @MainActor in
                self?.handleLearnedCorrection(
                    from: result.originalText,
                    correctedText: result.correctedText,
                    insertedText: result.insertedText
                )
            }
        }

        transcriber.onStatusUpdate = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                let status = DictationUIStatus.fromTranscriberMessage(message)
                self.showHUDAlertIfNeeded(forTranscriberMessage: message)
                if status == .finalizing {
                    self.playDictationFeedbackSound(.processing)
                }
                self.setUIStatus(status)
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
            Task { @MainActor in
                await self.handleFinalTranscript(text)
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
                self?.schedulePermissionRestartIfNeeded()
                self?.updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)
            }
        }

        aiStudioRequestObserver = NotificationCenter.default.addObserver(
            forName: .keyScribeOpenAIMemoryStudio,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowCoordinator?.openAIMemoryStudioWindow()
            }
        }

        updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)
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
        if let aiStudioRequestObserver {
            NotificationCenter.default.removeObserver(aiStudioRequestObserver)
            self.aiStudioRequestObserver = nil
        }
        adaptiveCorrectionObserver?.cancel()
        adaptiveCorrectionObserver = nil
        pasteLastTranscriptHotkeyManager?.stop()
        pasteLastTranscriptHotkeyManager = nil
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        stopStatusIconAnimation()
        transcriber.stopRecording()
        postInsertCorrectionMonitor.stopMonitoring(commitSession: false)
        waveform.hide()
        windowCoordinator?.closeAllWindows()
        windowCoordinator = nil
        isDictating = false
        dictationInputMode = .idle
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updatePermissionGate(openOnboardingIfNeeded: true)
    }

    private func currentPermissionSnapshot() -> PermissionCenter.Snapshot {
        PermissionCenter.snapshot(using: settings)
    }

    private func updatePermissionGate(openOnboardingIfNeeded: Bool, reconfigureHotkeysIfReady: Bool = false) {
        let hadAccessibilityPermission = settings.accessibilityTrusted
        let snapshot = currentPermissionSnapshot()
        let wasReady = permissionsReady
        permissionsReady = snapshot.allRequiredGranted

        if permissionsReady {
            transcriber.requestPermissions(promptIfNeeded: false)
            if !hadAccessibilityPermission && snapshot.accessibilityGranted {
                schedulePermissionRestartIfNeeded()
            }
            windowCoordinator?.closePermissionOnboardingWindow()
            if !wasReady || reconfigureHotkeysIfReady {
                applyHotkeyMode()
                configurePasteLastTranscriptHotkey()
            }
            if !isDictating {
                setUIStatus(.ready)
            }
        } else {
            stopPermissionDependentFeatures()
            setUIStatus(.message(permissionGateMessage(for: snapshot)))
            if openOnboardingIfNeeded {
                windowCoordinator?.openPermissionOnboardingWindow(onComplete: { [weak self] in
                    Task { @MainActor in
                        self?.updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)
                    }
                })
                requestStartupPermissionPromptIfNeeded()
            }
        }

        updateMenuState()
    }

    private func schedulePermissionRestartIfNeeded() {
        guard !hasScheduledPermissionRestart else { return }
        hasScheduledPermissionRestart = true

        let appURL = Bundle.main.bundleURL

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.promptsUserIfNeeded = false

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                CrashReporter.logError("Restart after permission grant failed: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func stopPermissionDependentFeatures() {
        if isDictating {
            transcriber.stopRecording(emitFinalText: false)
        }
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        pasteLastTranscriptHotkeyManager?.stop()
        pasteLastTranscriptHotkeyManager = nil
        isDictating = false
        dictationInputMode = .idle
        currentAudioLevel = 0
        waveform.hide()
        stopStatusIconAnimation()
    }

    private func permissionGateMessage(for snapshot: PermissionCenter.Snapshot) -> String {
        var missingPermissions: [String] = []
        if !snapshot.accessibilityGranted {
            missingPermissions.append("Accessibility")
        }
        if !snapshot.microphoneGranted {
            missingPermissions.append("Microphone")
        }
        if snapshot.speechRecognitionRequired && !snapshot.speechRecognitionGranted {
            missingPermissions.append("Speech Recognition")
        }

        guard !missingPermissions.isEmpty else {
            return "Complete permission setup to start KeyScribe"
        }

        if missingPermissions.count == 1, let permission = missingPermissions.first {
            return "Grant \(permission) permission to start KeyScribe"
        }

        let permissionList = missingPermissions.joined(separator: ", ")
        return "Grant required permissions (\(permissionList)) to start KeyScribe"
    }

    private func requestStartupPermissionPromptIfNeeded() {
        guard !didRequestStartupPermissionPrompt else { return }
        didRequestStartupPermissionPrompt = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard !self.permissionsReady else { return }
            self.transcriber.requestPermissions(promptIfNeeded: true)
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.image = makeStatusIcon(isRecording: false, level: 0)
        statusItem?.button?.toolTip = "KeyScribe"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Wire view model actions
        statusBarViewModel.onToggleDictation = { [weak self] in
            self?.popover?.performClose(nil)
            self?.toggleContinuousDictation()
        }
        statusBarViewModel.onPasteLastTranscript = { [weak self] in
            self?.popover?.performClose(nil)
            self?.pasteLastTranscriptFromHistory()
        }
        statusBarViewModel.onOpenHistory = { [weak self] in
            self?.popover?.performClose(nil)
            self?.windowCoordinator?.openHistoryWindow()
        }
        statusBarViewModel.onOpenAIMemoryStudio = { [weak self] in
            self?.popover?.performClose(nil)
            self?.windowCoordinator?.openAIMemoryStudioWindow()
        }
        statusBarViewModel.onOpenSettings = { [weak self] in
            self?.popover?.performClose(nil)
            self?.windowCoordinator?.openSettingsWindow()
        }
        statusBarViewModel.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 10)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: StatusBarPopoverView(viewModel: statusBarViewModel)
        )
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func applySettingsChanges() {
        settings.refreshMicrophones(notifyChange: false)
        syncWhisperModelSelectionIfNeeded()
        transcriber.applyMicrophoneSettings(autoDetect: settings.autoDetectMicrophone, microphoneUID: settings.selectedMicrophoneUID)
        applyRecognitionSettingsToTranscriber()
        transcriber.applyWhisperSettings(
            selectedModelID: settings.selectedWhisperModelID,
            useCoreML: settings.whisperUseCoreML
        )
        transcriber.setTranscriptionEngine(settings.transcriptionEngine)
        if !settings.adaptiveCorrectionsEnabled {
            postInsertCorrectionMonitor.stopMonitoring(commitSession: false)
        }
        updatePermissionGate(openOnboardingIfNeeded: true, reconfigureHotkeysIfReady: true)
    }

    private func observeAdaptiveCorrectionChanges() {
        adaptiveCorrectionObserver = adaptiveCorrectionStore.$learnedCorrections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyRecognitionSettingsToTranscriber()
            }
    }

    private func applyRecognitionSettingsToTranscriber() {
        let adaptiveBiasPhrases: [String]
        if settings.adaptiveCorrectionsEnabled {
            adaptiveBiasPhrases = adaptiveCorrectionStore.preferredRecognitionPhrases()
        } else {
            adaptiveBiasPhrases = []
        }

        transcriber.applyRecognitionSettings(
            enableContextualBias: settings.enableContextualBias,
            keepTextAcrossPauses: settings.keepTextAcrossPauses,
            recognitionMode: settings.recognitionMode,
            autoPunctuation: settings.autoPunctuation,
            finalizeDelaySeconds: settings.finalizeDelaySeconds,
            customContextPhrases: settings.customContextPhrases,
            adaptiveBiasPhrases: adaptiveBiasPhrases
        )
    }

    private func syncWhisperModelSelectionIfNeeded() {
        guard settings.transcriptionEngine == .whisperCpp else { return }

        whisperModelManager.refreshInstallStates()
        if whisperModelManager.hasInstalledModel(id: settings.selectedWhisperModelID) {
            return
        }

        if let fallbackModel = WhisperModelCatalog.curatedModels.first(where: { whisperModelManager.hasInstalledModel(id: $0.id) }) {
            settings.selectedWhisperModelID = fallbackModel.id
        } else {
            settings.selectedWhisperModelID = ""
        }
    }

    private func applyHotkeyMode() {
        hotkeyManager?.stop()
        hotkeyManager = nil
        continuousToggleHotkeyManager?.stop()
        continuousToggleHotkeyManager = nil
        guard permissionsReady else { return }

        hotkeyManager = HoldToTalkManager(
            keyCode: settings.shortcutKeyCode,
            modifiers: settings.shortcutModifierFlags,
            suppressSystemShortcutSounds: settings.muteSystemSoundsWhileHoldingShortcut,
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
        guard permissionsReady else {
            pasteLastTranscriptHotkeyManager = nil
            return
        }
        pasteLastTranscriptHotkeyManager = OneShotHotkeyManager(
            keyCode: PasteLastTranscriptShortcut.keyCode,
            modifiers: PasteLastTranscriptShortcut.modifiers
        ) { [weak self] in
            self?.pasteLastTranscriptFromHistory()
        }
        pasteLastTranscriptHotkeyManager?.start()
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
        guard permissionsReady else {
            updatePermissionGate(openOnboardingIfNeeded: true)
            return
        }
        postInsertCorrectionMonitor.stopMonitoring(commitSession: false)

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
            playDictationFeedbackSound(.startListening)
            setUIStatus(.listening)
            waveform.show()
            startStatusIconAnimation()
        } else {
            waveform.hide()
            stopStatusIconAnimation()
            updatePermissionGate(openOnboardingIfNeeded: true)
            if settings.transcriptionEngine == .whisperCpp,
               !whisperModelManager.hasInstalledModel(id: settings.selectedWhisperModelID) {
                setUIStatus(.message("Install a whisper model in Settings > Recognition to start dictation"))
                windowCoordinator?.openSettingsWindow()
            }
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
        playDictationFeedbackSound(.stopListening)
        transcriber.stopRecording()
        isDictating = false
        currentAudioLevel = 0
        waveform.hide()
        stopStatusIconAnimation()
        updateMenuState()
    }

    private func handleFinalTranscript(_ text: String) async {
        let cleaned = TextCleanup.process(text, mode: settings.textCleanupMode)
        guard !cleaned.isEmpty else {
            setUIStatus(.ready)
            return
        }

        let rewriteResolved: String
        if settings.memoryIndexingEnabled {
            guard let resolved = await resolvePromptRewriteInsertionText(for: cleaned) else {
                setUIStatus(.ready)
                return
            }
            rewriteResolved = resolved
        } else {
            rewriteResolved = cleaned
        }

        let readyForInsert = applyAdaptiveCorrectionsIfNeeded(to: rewriteResolved)
        transcriptHistory.add(readyForInsert)
        insertText(readyForInsert, trackCorrections: settings.adaptiveCorrectionsEnabled)
        setUIStatus(.ready)
    }

    private func resolvePromptRewriteInsertionText(for cleanedTranscript: String) async -> String? {
        guard settings.memoryIndexingEnabled else {
            return cleanedTranscript
        }

        while true {
            do {
                guard let rawSuggestion = try await promptRewriteService.retrieveSuggestion(for: cleanedTranscript) else {
                    return cleanedTranscript
                }
                let suggestion = formatPromptRewriteSuggestion(rawSuggestion, originalText: cleanedTranscript)

                while true {
                    switch await presentPromptRewritePreviewDialog(
                        originalText: cleanedTranscript,
                        suggestion: suggestion
                    ) {
                    case .useSuggested:
                        await recordPromptRewriteFeedback(
                            action: .usedSuggested,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText,
                            finalInsertedText: suggestion.suggestedText
                        )
                        return suggestion.suggestedText
                    case .editThenInsert:
                        guard let edited = presentPromptRewriteEditDialog(initialText: suggestion.suggestedText) else {
                            continue
                        }
                        let normalizedEdited = PromptRewriteFormatting.prepareEditedTextForInsertion(
                            edited,
                            forceMarkdown: settings.promptRewriteAlwaysConvertToMarkdown
                        )
                        let finalEdited = normalizedEdited.isEmpty ? edited : normalizedEdited
                        await recordPromptRewriteFeedback(
                            action: .editedThenInserted,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText,
                            finalInsertedText: finalEdited
                        )
                        return finalEdited
                    case .insertOriginal:
                        await recordPromptRewriteFeedback(
                            action: .insertedOriginal,
                            originalText: cleanedTranscript,
                            suggestedText: suggestion.suggestedText,
                            finalInsertedText: cleanedTranscript
                        )
                        return cleanedTranscript
                    }
                }
            } catch {
                let failureDetail = promptRewriteFailureDetail(for: error)
                switch presentPromptRewriteFailureDialog(failureDetail: failureDetail) {
                case .retry:
                    await recordPromptRewriteFeedback(
                        action: .retriedAfterFailure,
                        originalText: cleanedTranscript,
                        failureDetail: failureDetail
                    )
                    continue
                case .insertOriginal:
                    await recordPromptRewriteFeedback(
                        action: .insertedOriginalAfterFailure,
                        originalText: cleanedTranscript,
                        finalInsertedText: cleanedTranscript,
                        failureDetail: failureDetail
                    )
                    return cleanedTranscript
                case .cancel:
                    await recordPromptRewriteFeedback(
                        action: .canceledAfterFailure,
                        originalText: cleanedTranscript,
                        failureDetail: failureDetail
                    )
                    return nil
                }
            }
        }
    }

    private func applyAdaptiveCorrectionsIfNeeded(to text: String) -> String {
        let readyForInsert: String
        let appliedEvents: [AdaptiveCorrectionStore.AppliedEvent]
        if settings.adaptiveCorrectionsEnabled {
            let applyResult = adaptiveCorrectionStore.applyWithEvents(to: text)
            readyForInsert = applyResult.text
            appliedEvents = applyResult.appliedEvents
        } else {
            readyForInsert = text
            appliedEvents = []
        }

        if !appliedEvents.isEmpty {
            let applyMessage: String
            if appliedEvents.count == 1, let first = appliedEvents.first {
                applyMessage = "Applied learned: \(first.source) -> \(first.replacement)"
            } else {
                applyMessage = "Applied \(appliedEvents.count) learned corrections"
            }
            waveform.flashEvent(
                message: applyMessage,
                symbolName: "arrow.triangle.2.circlepath.circle.fill",
                duration: 1.2
            )
        }

        return readyForInsert
    }

    private func presentPromptRewritePreviewDialog(
        originalText: String,
        suggestion: PromptRewriteSuggestion
    ) async -> PromptRewritePreviewChoice {
        await PromptRewriteHUDManager.shared.present(originalText: originalText, suggestion: suggestion)
    }

    private func presentPromptRewriteEditDialog(initialText: String) -> String? {
        var draft = initialText
        while true {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
            textView.string = draft
            textView.font = NSFont.systemFont(ofSize: 13)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.textContainerInset = NSSize(width: 8, height: 8)

            let scrollView = NSScrollView(frame: textView.frame)
            scrollView.borderType = .bezelBorder
            scrollView.hasVerticalScroller = true
            scrollView.documentView = textView

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Edit Suggested Rewrite"
            alert.informativeText = "Update the text below, then choose Insert Edited."
            alert.accessoryView = scrollView
            alert.addButton(withTitle: "Insert Edited")
            alert.addButton(withTitle: "Back")

            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                return nil
            }

            let edited = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !edited.isEmpty {
                return edited
            }

            draft = textView.string
            let emptyAlert = NSAlert()
            emptyAlert.alertStyle = .warning
            emptyAlert.messageText = "Edited text is empty"
            emptyAlert.informativeText = "Enter text before inserting, or go back and choose a different action."
            emptyAlert.addButton(withTitle: "Continue Editing")
            _ = emptyAlert.runModal()
        }
    }

    private func presentPromptRewriteFailureDialog(failureDetail: String) -> PromptRewriteFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rewrite Provider Unavailable"
        alert.informativeText = "Could not get a rewrite suggestion.\n\(failureDetail)"
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Insert Original")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .retry
        case .alertSecondButtonReturn:
            return .insertOriginal
        default:
            return .cancel
        }
    }

    private func promptRewritePreviewBody(
        originalText: String,
        suggestion: PromptRewriteSuggestion
    ) -> String {
        let suggestedSnippet = promptRewriteSnippet(for: suggestion.suggestedText)
        let originalSnippet = promptRewriteSnippet(for: originalText)
        if let memoryContext = suggestion.memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines),
           !memoryContext.isEmpty {
            let memorySnippet = promptRewriteSnippet(for: memoryContext, maxLength: 160)
            return """
            Memory context:
            \(memorySnippet)

            Suggested:
            \(suggestedSnippet)

            Original:
            \(originalSnippet)
            """
        }

        return """
        Suggested:
        \(suggestedSnippet)

        Original:
        \(originalSnippet)
        """
    }

    private func promptRewriteSnippet(for text: String, maxLength: Int = 320) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else {
            return normalized
        }
        let prefix = normalized.prefix(maxLength)
        return "\(prefix)..."
    }

    private func promptRewriteFailureDetail(for error: Error) -> String {
        if let serviceError = error as? PromptRewriteServiceError {
            switch serviceError {
            case let .timedOut(timeoutSeconds):
                return "Timed out after \(String(format: "%.1f", timeoutSeconds))s."
            case let .providerUnavailable(reason):
                return reason
            }
        }

        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "unknown-provider-error"
        }
        return raw
    }

    private func formatPromptRewriteSuggestion(
        _ suggestion: PromptRewriteSuggestion,
        originalText: String
    ) -> PromptRewriteSuggestion {
        let formatted = PromptRewriteFormatting.prepareSuggestedTextForInsertion(
            suggestion.suggestedText,
            originalText: originalText,
            forceMarkdown: settings.promptRewriteAlwaysConvertToMarkdown
        )
        let resolvedText = formatted.isEmpty ? suggestion.suggestedText : formatted
        return PromptRewriteSuggestion(
            suggestedText: resolvedText,
            memoryContext: suggestion.memoryContext
        )
    }

    private func recordPromptRewriteFeedback(
        action: PromptRewriteFeedbackAction,
        originalText: String,
        suggestedText: String? = nil,
        finalInsertedText: String? = nil,
        failureDetail: String? = nil
    ) async {
        let event = PromptRewriteFeedbackEvent(
            action: action,
            originalText: originalText,
            suggestedText: suggestedText,
            finalInsertedText: finalInsertedText,
            failureDetail: failureDetail
        )
        await promptRewriteService.recordFeedback(event)
    }

    private func insertText(
        _ text: String,
        forceCopyToClipboard: Bool = false,
        overrideCopyToClipboard: Bool? = nil,
        trackCorrections: Bool = false
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard ensureAccessibilityReadyForInsertion() else { return }
        let copyToClipboard = overrideCopyToClipboard ?? (settings.copyToClipboard || forceCopyToClipboard)
        attemptInsertText(
            text,
            copyToClipboard: copyToClipboard,
            attemptsRemaining: 5
        ) { [weak self] didInsert in
            guard let self else { return }
            if didInsert {
                self.playDictationFeedbackSound(.pasted)
            }
            guard trackCorrections else { return }
            if didInsert {
                self.postInsertCorrectionMonitor.startMonitoring(insertedText: text)
            }
        }
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
            setUIStatus(.message("Enable Accessibility via menu: Complete Permission Setup…"))
            updatePermissionGate(openOnboardingIfNeeded: true)
            return false
        }
        return true
    }

    private func attemptInsertText(
        _ text: String,
        copyToClipboard: Bool,
        attemptsRemaining: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard attemptsRemaining > 0 else {
            if copyToClipboard {
                ensureClipboardFallback(text)
                setUIStatus(.message("Paste unavailable — copied to clipboard"))
            } else {
                setUIStatus(.message("Paste unavailable — transcript is in KeyScribe History"))
            }
            lastTargetApplication = nil
            completion?(false)
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
                    self?.attemptInsertText(
                        text,
                        copyToClipboard: copyToClipboard,
                        attemptsRemaining: attemptsRemaining - 1,
                        completion: completion
                    )
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
                self?.attemptInsertText(
                    text,
                    copyToClipboard: copyToClipboard,
                    attemptsRemaining: nextRetriesRemaining + 1,
                    completion: completion
                )
            }

        case let .complete(statusMessage):
            let didInsert = result == .pasted
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
            completion?(didInsert)
        }
    }

    private func handleLearnedCorrection(from originalText: String, correctedText: String, insertedText: String) {
        guard settings.adaptiveCorrectionsEnabled else { return }

        guard let proposedEvent = adaptiveCorrectionStore.proposedLearningEvent(
            from: originalText,
            correctedText: correctedText,
            insertionHint: insertedText
        ) else { return }

        let source = proposedEvent.source
        let replacement = proposedEvent.replacement
        waveform.presentCorrectionDecision(
            source: source,
            replacement: replacement,
            onAccept: { [weak self] in
                self?.acceptLearnedCorrection(source: source, replacement: replacement)
            },
            onReject: { [weak self] in
                self?.setUIStatus(.message("Skipped correction: \(source) -> \(replacement)"))
            }
        )
    }

    private func acceptLearnedCorrection(source: String, replacement: String) {
        guard let event = adaptiveCorrectionStore.acceptProposedLearning(
            source: source,
            replacement: replacement
        ) else {
            return
        }

        let hudMessage = "Learned correction: \(event.source) -> \(event.replacement)"

        waveform.flashEvent(
            message: hudMessage,
            symbolName: "arrow.triangle.2.circlepath.circle.fill",
            duration: 1.2
        )
        if settings.playCorrectionLearnedSound {
            playDictationFeedbackSound(.correctionLearned)
        }
        setUIStatus(.message(hudMessage))
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

    private func showHUDAlertIfNeeded(forTranscriberMessage message: String) {
        if message.hasPrefix("Whisper finalize timed out and was reset") {
            waveform.flashEvent(
                message: "Whisper stalled and was reset. Retry now.",
                symbolName: "exclamationmark.triangle.fill",
                duration: 3.0
            )
            return
        }

        if message.hasPrefix("Whisper error:") {
            waveform.flashEvent(
                message: "Whisper failed. Check model and Core ML settings.",
                symbolName: "xmark.octagon.fill",
                duration: 2.4
            )
        }
    }

    private func setUIStatus(_ status: DictationUIStatus) {
        statusBarViewModel.uiStatus = status

        if status.resetsDictationIndicators {
            isDictating = false
            dictationInputMode = .idle
            currentAudioLevel = 0
            waveform.hide()
            stopStatusIconAnimation()
        }

        updateMenuState()
    }

    private func playDictationFeedbackSound(_ cue: DictationFeedbackCue) {
        guard let sound = dictationFeedbackSounds[cue] else { return }
        sound.stop()
        sound.currentTime = 0
        let baseVolume = min(1, max(0, Float(settings.dictationFeedbackVolume)))
        sound.volume = baseVolume * cue.volumeMultiplier
        sound.play()
    }

    private func updateMenuState() {
        statusBarViewModel.isContinuousMode = (dictationInputMode == .continuous)
        statusBarViewModel.permissionsReady = permissionsReady
        statusBarViewModel.isDictating = isDictating
        statusBarViewModel.currentAudioLevel = currentAudioLevel
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
        // Idle pulse sweeps from 0.3 to 0.7 so bars animate from center outward
        let idlePulse = isRecording ? 0.30 + (0.40 * waveMotion) : 0
        let animatedLevel = isRecording ? max(normalizedLevel, idlePulse) : normalizedLevel

        let symbol: NSImage?
        if #available(macOS 13.3, *) {
            let variableValue = isRecording ? max(0.30, Double(animatedLevel)) : 0.45
            symbol = NSImage(systemSymbolName: "waveform.circle", variableValue: variableValue, accessibilityDescription: "KeyScribe")
        } else {
            symbol = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "KeyScribe")
        }

        guard let symbol else {
            return nil
        }

        let pointSize: CGFloat = 18
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        guard let configured = symbol.withSymbolConfiguration(config) else { return nil }
        configured.isTemplate = true

        // Flip horizontally so the variable fill runs left-to-right
        let size = configured.size
        let flipped = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: size.width, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
            configured.draw(in: rect)
            return true
        }
        flipped.isTemplate = true
        return flipped
    }
}

struct SettingsView: View {
    private enum SettingsSection: CaseIterable, Identifiable {
        case general
        case shortcuts
        case microphone
        case recognition
        case models
        case corrections
        case memorySources
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .microphone: return "Microphone"
            case .recognition: return "Recognition"
            case .models: return "Models"
            case .corrections: return "Corrections"
            case .memorySources: return "Memory & Sources"
            case .about: return "About & Permissions"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "Output, clipboard, and appearance"
            case .shortcuts: return "Hold-to-talk and continuous toggle keys"
            case .microphone: return "Input device selection and refresh"
            case .recognition: return "Speech behavior and text quality"
            case .models: return "Install and select whisper models"
            case .corrections: return "Learn from and manage text fixes"
            case .memorySources: return "AI memory toggle and provider status"
            case .about: return "Permission health, diagnostics, and uninstall"
            }
        }

        var iconName: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .microphone: return "mic.fill"
            case .recognition: return "waveform"
            case .models: return "shippingbox.fill"
            case .corrections: return "text.badge.checkmark"
            case .memorySources: return "tray.full.fill"
            case .about: return "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .blue
            case .shortcuts: return .indigo
            case .microphone: return .red
            case .recognition: return .green
            case .models: return .teal
            case .corrections: return .mint
            case .memorySources: return .cyan
            case .about: return .orange
            }
        }

        var searchTerms: [String] {
            switch self {
            case .general:
                return ["general", "clipboard", "waveform", "accessibility", "output", "sound", "feedback"]
            case .shortcuts:
                return ["shortcut", "keyboard", "hold to talk", "continuous", "hotkey"]
            case .microphone:
                return ["microphone", "input", "device", "audio"]
            case .recognition:
                return ["recognition", "engine", "punctuation", "context", "cleanup", "delay", "text quality", "speech"]
            case .models:
                return ["whisper", "model", "download", "install", "core ml", "tiny", "base", "small", "medium", "large"]
            case .corrections:
                return ["adaptive", "learned", "correction", "replacement", "sound", "edit", "remove", "clear"]
            case .memorySources:
                return ["memory", "ai", "provider", "oauth", "status", "studio", "enable"]
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

    private struct ShortcutModifierOption: Identifiable {
        let id: String
        let label: String
        let flag: NSEvent.ModifierFlags
    }

    private struct ShortcutKeyOption: Identifiable {
        let keyCode: UInt16
        let label: String

        var id: UInt16 {
            keyCode
        }
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

    private static let manualModifierOnlyKeyCode: UInt16 = UInt16.max
    private static let shortcutModifierOptions: [ShortcutModifierOption] = [
        .init(id: "fn", label: "Fn", flag: .function),
        .init(id: "control", label: "⌃", flag: .control),
        .init(id: "option", label: "⌥", flag: .option),
        .init(id: "shift", label: "⇧", flag: .shift),
        .init(id: "command", label: "⌘", flag: .command)
    ]

    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var whisperModelManager = WhisperModelManager.shared
    @StateObject private var adaptiveCorrectionStore = AdaptiveCorrectionStore.shared
    @State private var selectedSection: SettingsSection = .general
    @State private var searchQuery = ""
    @State private var isCapturingShortcut = false
    @State private var shortcutCaptureTarget: ShortcutCaptureTarget?
    @State private var shortcutCaptureMessage: String?
    @State private var showHoldManualMap = false
    @State private var showContinuousManualMap = false
    @State private var showDictationOutputSettings = false
    @State private var showDictationSoundSettings = false
    @State private var whisperModelSearchQuery = ""
    @State private var whisperFamilyFilter = "all"
    @State private var whisperShowInstalledOnly = false
    @State private var whisperBrowserModelID = ""
    @State private var showUninstallSheet = false
    @State private var showUninstallConfirmation = false
    @State private var uninstallDeleteDownloadedModels = false
    @State private var uninstallDeleteLearnedCorrections = false
    @State private var uninstallDeleteMemories = false
    @State private var uninstallDeleteProviderCredentials = false
    @State private var isCorrectionEditorPresented = false
    @State private var correctionSourceDraft = ""
    @State private var correctionReplacementDraft = ""
    @State private var correctionEditingSource: String?
    @State private var correctionDialogMessage: String?
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
    @State private var memoryActionMessage: String?
    @State private var showingProvidersSheet = false
    @State private var showingSourceFoldersSheet = false
    @State private var showingCorrectionsListSheet = false
    @State private var correctionsSearchQuery = ""
    private let memoryIndexingSettingsService = MemoryIndexingSettingsService.shared
    private let settingsSidebarWidth: CGFloat = 278
    private let manualShortcutKeyOptions: [ShortcutKeyOption] = ShortcutValidation.manualAssignableKeyCodes.map {
        ShortcutKeyOption(keyCode: $0, label: ShortcutValidation.keyName(for: $0))
    }

    var body: some View {
        ZStack {
            AppChromeBackground()

            HStack(spacing: 0) {
                settingsSidebar
                Divider()
                settingsDetailPane
            }
            .appThemedSurface(cornerRadius: 16, strokeOpacity: 0.18)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(10)

            ShortcutCaptureMonitor(
                isCapturing: $isCapturingShortcut,
                onCapture: { keyCode, modifiers in
                    guard let target = shortcutCaptureTarget else {
                        return false
                    }

                    let didApply = applyShortcutSelection(
                        for: target,
                        keyCode: keyCode,
                        modifiersRaw: modifiers,
                        validationMessage: "Shortcut must use 2 to 4 keys. Try again."
                    )
                    guard didApply else { return false }
                    shortcutCaptureTarget = nil
                    isCapturingShortcut = false
                    return true
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
        .appScrollbars()
        .frame(minWidth: 860, idealWidth: 900, minHeight: 620, idealHeight: 680)
        .onChange(of: searchQuery) { _ in
            guard !trimmedSearchQuery.isEmpty else { return }
            if let firstMatch = filteredSearchEntries.first {
                selectedSection = firstMatch.section
            } else if let firstSection = filteredSections.first {
                selectedSection = firstSection
            }
        }
        .onChange(of: selectedSection) { _ in
            cancelShortcutCapture()
        }
        .sheet(isPresented: $isCorrectionEditorPresented) {
            correctionEditorSheet
        }
        .sheet(isPresented: $showingCorrectionsListSheet) {
            correctionsListSheet
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                TextField("Search settings…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.bottom, 4)

            VStack(spacing: 2) {
                ForEach(filteredSections) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        sidebarSectionRow(for: section)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }

            if filteredSections.isEmpty {
                Text("No matching sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 34)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: settingsSidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func sidebarSectionRow(for section: SettingsSection) -> some View {
        let isSelected = selectedSection == section
        let matchCount = matchCount(for: section)

        HStack(spacing: 10) {
            Image(systemName: section.iconName)
                .foregroundStyle(isSelected ? .white : section.tint)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? section.tint : section.tint.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                Text(section.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !trimmedSearchQuery.isEmpty && matchCount > 0 {
                Text("\(matchCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
        )
    }

    @ViewBuilder
    private var settingsDetailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !trimmedSearchQuery.isEmpty {
                    searchHighlightsCard
                }
                sectionContent(for: selectedSection)
            }
            .padding(.top, 34)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func settingsSectionHeader(for section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                                .fill(.regularMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(entry.section.tint.opacity(0.15))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(entry.section.tint.opacity(0.25), lineWidth: 0.6)
                                )
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
        case .models:
            modelsSection
        case .corrections:
            correctionsSection
        case .memorySources:
            memorySourcesSection
        case .about:
            aboutSection
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .general)
            accessibilityCard

            settingsDisclosureCard(
                title: "Dictation Output",
                isExpanded: $showDictationOutputSettings
            ) {
                Toggle("Also copy transcript to system clipboard", isOn: $settings.copyToClipboard)
                    .help("Turn off to keep dictations out of clipboard history. Explicit Copy actions from History still copy as expected.")
            }

            settingsDisclosureCard(
                title: "Dictation Sounds",
                subtitle: "Choose the sounds for each dictation event.",
                isExpanded: $showDictationSoundSettings
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    dictationSoundRow(
                        title: "Start listening",
                        selection: $settings.dictationStartSoundName
                    )

                    dictationSoundRow(
                        title: "Stop/Finalize",
                        selection: $settings.dictationStopSoundName
                    )

                    dictationSoundRow(
                        title: "Processing (finalize)",
                        selection: $settings.dictationProcessingSoundName
                    )

                    dictationSoundRow(
                        title: "Pasted",
                        selection: $settings.dictationPastedSoundName
                    )

                    VStack(spacing: 6) {
                        HStack {
                            Text("Feedback volume")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int(settings.dictationFeedbackVolume * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        Slider(value: $settings.dictationFeedbackVolume, in: 0...1, step: 0.01)
                            .help("Reduce this value to lower all dictation feedback sounds.")
                    }
                }
            }

            settingsCard(title: "Waveform Appearance") {
                Picker("Waveform Theme", selection: $settings.waveformThemeRawValue) {
                    ForEach(WaveformTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose the color scheme for the recording waveform.")

                Divider()
                    .padding(.vertical, 6)

                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                WaveformThemePreview(theme: settings.waveformTheme)
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
        .onAppear {
            showDictationOutputSettings = false
            showDictationSoundSettings = false
        }
    }

    @ViewBuilder
    private func dictationSoundRow(title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.medium))
            Spacer()
            Picker("", selection: selection) {
                ForEach(SettingsStore.dictationStartSoundOptions, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        }
        .help(selection.wrappedValue == SettingsStore.noDictationSoundName
            ? "No sound for this event."
            : "Play this sound when: \(title.lowercased())")
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .shortcuts)
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

                    Text("Use 2 to 4 keys, like ⌘+Space or ⌃+⌥+⌘+Space.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Mute system sounds while this shortcut is held", isOn: $settings.muteSystemSoundsWhileHoldingShortcut)
                    .help("Suppresses this hold-to-talk key chord in other apps to avoid system alert beeps.")

                DisclosureGroup("Manual map (advanced)", isExpanded: $showHoldManualMap) {
                    manualShortcutBuilder(for: .holdToTalk)
                        .padding(.top, 6)
                }

                if isCapturingShortcut && shortcutCaptureTarget == .holdToTalk {
                    Text("Press hold-to-talk shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isHoldToTalkShortcutValid {
                    Text("Hold-to-talk shortcut must include 2 to 4 keys.")
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

                    Text("Use 2 to 4 keys. Keep this different from hold-to-talk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Manual map (advanced)", isExpanded: $showContinuousManualMap) {
                    manualShortcutBuilder(for: .continuousToggle)
                        .padding(.top, 6)
                }

                if isCapturingShortcut && shortcutCaptureTarget == .continuousToggle {
                    Text("Press continuous toggle shortcut now. Press Esc to cancel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !isContinuousToggleShortcutValid {
                    Text("Continuous toggle shortcut must include 2 to 4 keys.")
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
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .microphone)
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
    }

    @ViewBuilder
    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .recognition)
            settingsCard(title: "Transcription Engine") {
                HStack {
                    Text("Engine")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("", selection: $settings.transcriptionEngineRawValue) {
                        ForEach(TranscriptionEngineType.allCases) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }

                Text(settings.transcriptionEngine.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.transcriptionEngine == .appleSpeech {
                settingsCard(
                    title: "Apple Speech Behavior",
                    subtitle: "Tune recognition behavior and punctuation for Apple Speech."
                ) {
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
            } else {
                settingsCard(
                    title: "whisper.cpp",
                    subtitle: "Model install and selection are managed in the Models section."
                ) {
                    Text("Open Models to install, delete, and switch whisper models.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Open Models") {
                            selectedSection = .models
                        }
                        .buttonStyle(.borderedProminent)

                        Spacer()
                    }
                }
            }

            settingsCard(
                title: "Text Quality & Timing",
                subtitle: "Control finalize speed, cleanup, and custom vocabulary."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Finalize delay: \(Int(settings.finalizeDelaySeconds * 1000)) ms")
                        .font(.callout.weight(.medium))
                    Slider(value: $settings.finalizeDelaySeconds, in: 0.15...1.2, step: 0.05)
                    Text("Lower = faster paste, higher = fewer cut-offs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

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

            settingsCard(
                title: "Adaptive Corrections",
                subtitle: "Learning controls and correction management moved to a dedicated section."
            ) {
                Text("Open Corrections to review learned fixes, add custom replacements, and tune correction sound.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Open Corrections") {
                        selectedSection = .corrections
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .models)

            if settings.transcriptionEngine != .whisperCpp {
                settingsCard(
                    title: "whisper.cpp Required",
                    subtitle: "Model install and selection are only used with whisper.cpp."
                ) {
                    Text("Switch the transcription engine to whisper.cpp to manage local models.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Switch to whisper.cpp") {
                        settings.transcriptionEngine = .whisperCpp
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                settingsCard(title: "Model Runtime") {
                    Toggle("Use Core ML encoder when available", isOn: $settings.whisperUseCoreML)
                        .help("If installed for the selected model, Core ML can improve whisper speed on Apple Silicon.")

                    if settings.selectedWhisperModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No model selected yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Current model: \(settings.selectedWhisperModelID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard(
                    title: "Model Library",
                    subtitle: "Browse, filter, install, and choose whisper models."
                ) {
                    if WhisperModelCatalog.curatedModels.isEmpty {
                        Text("No curated whisper models are configured.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                TextField("Search model ID (e.g. medium, large-v3, q5)", text: $whisperModelSearchQuery)
                                    .textFieldStyle(.roundedBorder)

                                Toggle("Installed only", isOn: $whisperShowInstalledOnly)
                                    .toggleStyle(.switch)
                                    .fixedSize()
                            }

                            HStack(spacing: 10) {
                                Picker("Family", selection: $whisperFamilyFilter) {
                                    ForEach(whisperFamilyFilterOptions, id: \.self) { family in
                                        Text(family == "all" ? "All families" : family.capitalized)
                                            .tag(family)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 180)

                                Spacer()

                                Picker("Model", selection: $whisperBrowserModelID) {
                                    ForEach(filteredWhisperModels) { model in
                                        Text(model.displayName).tag(model.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 290)
                            }

                            if let browsingModel = activeWhisperBrowserModel {
                                whisperModelRow(for: browsingModel)
                            } else {
                                Text("No models match the current filters.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            refreshWhisperModelBrowserState()
        }
        .onChange(of: settings.transcriptionEngineRawValue) { _ in
            if settings.transcriptionEngine == .whisperCpp {
                refreshWhisperModelBrowserState()
            }
        }
        .onChange(of: whisperModelSearchQuery) { _ in
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: whisperFamilyFilter) { _ in
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: whisperShowInstalledOnly) { _ in
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: whisperModelManager.installStateByModelID) { _ in
            ensureSelectedWhisperModelIsValid()
            ensureWhisperBrowserModelSelectionIsValid()
        }
        .onChange(of: settings.selectedWhisperModelID) { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if filteredWhisperModels.contains(where: { $0.id == trimmed }) {
                whisperBrowserModelID = trimmed
            }
        }
    }

    @ViewBuilder
    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .corrections)

            settingsCard(
                title: "Adaptive Corrections",
                subtitle: "Learn from quick edits and manage learned replacements."
            ) {
                Text("Learned corrections are used as recognition hints for Apple Speech and whisper.cpp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Learn from quick post-insert corrections", isOn: $settings.adaptiveCorrectionsEnabled)

                Toggle("Play sound when a correction is learned", isOn: $settings.playCorrectionLearnedSound)
                    .disabled(!settings.adaptiveCorrectionsEnabled)

                if settings.playCorrectionLearnedSound {
                    dictationSoundRow(
                        title: "Learned correction sound",
                        selection: $settings.dictationCorrectionLearnedSoundName
                    )
                        .disabled(!settings.adaptiveCorrectionsEnabled)
                } else {
                    Text("Enable this option to play a custom sound when a correction is learned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Add Custom Correction…") {
                        openCreateCorrectionDialog()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }

                if adaptiveCorrectionStore.learnedCorrections.isEmpty {
                    Text("No learned corrections yet. Fix a mistaken word once and KeyScribe can learn it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(adaptiveCorrectionStore.learnedCorrections.prefix(12)), id: \.id) { correction in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(correction.source)
                                    .font(.callout.monospaced())
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(correction.replacement)
                                    .font(.callout.monospaced())
                                Spacer()
                                Button("Edit") {
                                    beginEditingCorrection(correction)
                                }
                                .buttonStyle(.borderless)
                                Button("Remove") {
                                    adaptiveCorrectionStore.removeCorrection(source: correction.source)
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        if adaptiveCorrectionStore.learnedCorrections.count > 12 {
                            HStack {
                                Button("View All \\(adaptiveCorrectionStore.learnedCorrections.count) Corrections...") {
                                    showingCorrectionsListSheet = true
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                            }
                            .padding(.top, 4)
                        }

                        HStack {
                            Spacer()
                            Button("Clear Learned Corrections", role: .destructive) {
                                adaptiveCorrectionStore.clearAll()
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredCorrections: [AdaptiveCorrectionStore.LearnedCorrection] {
        let all = adaptiveCorrectionStore.learnedCorrections
        let query = correctionsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return all }
        return all.filter {
            $0.source.lowercased().contains(query) || $0.replacement.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var correctionsListSheet: some View {
        ZStack {
            AppChromeBackground()

            VStack(spacing: 0) {
                HStack {
                    Text("Learned Corrections")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        showingCorrectionsListSheet = false
                    }
                }
                .padding()
                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    if adaptiveCorrectionStore.learnedCorrections.isEmpty {
                        Text("No learned corrections yet. Fix a mistaken word once and KeyScribe can learn it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        TextField("Search corrections", text: $correctionsSearchQuery)
                            .textFieldStyle(.roundedBorder)

                        if filteredCorrections.isEmpty {
                            Text("No corrections match \"\\(correctionsSearchQuery)\".")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(filteredCorrections, id: \.id) { correction in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(correction.source)
                                                .font(.callout.monospaced())
                                            Image(systemName: "arrow.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Text(correction.replacement)
                                                .font(.callout.monospaced())
                                            Spacer()
                                            Button("Edit") {
                                                beginEditingCorrection(correction)
                                            }
                                            .buttonStyle(.borderless)
                                            Button("Remove") {
                                                adaptiveCorrectionStore.removeCorrection(source: correction.source)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                                .padding(.trailing)
                            }
                        }
                    }
                }
                .padding()
            }
            .padding(10)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
            .padding(8)
        }
        .frame(width: 500, height: 500)
    }

    @ViewBuilder
    private var memorySourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSectionHeader(for: .memorySources)

            settingsCard(
                title: "AI Memory Assistant",
                subtitle: "Use this toggle to enable or disable AI memory-based prompt rewriting."
            ) {
                Toggle("Enable AI memory assistant", isOn: $settings.memoryIndexingEnabled)
                Toggle("Always convert AI suggestion to Markdown", isOn: $settings.promptRewriteAlwaysConvertToMarkdown)
                    .disabled(!settings.memoryIndexingEnabled)
                Text("Current rewrite provider: \(settings.promptRewriteProviderMode.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Structured suggestions keep their formatting when inserted, including bullets and question lists.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            settingsCard(
                title: "Provider Connection Status",
                subtitle: "Open AI Memory Studio for full provider setup, indexing controls, and memory browser."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("OpenAI")
                        Spacer()
                        Text(settings.hasPromptRewriteOAuthSession(for: .openAI) ? "Connected" : "Not connected")
                            .foregroundStyle(settings.hasPromptRewriteOAuthSession(for: .openAI) ? .green : .secondary)
                    }
                    HStack {
                        Text("Anthropic")
                        Spacer()
                        Text(settings.hasPromptRewriteOAuthSession(for: .anthropic) ? "Connected" : "Not connected")
                            .foregroundStyle(settings.hasPromptRewriteOAuthSession(for: .anthropic) ? .green : .secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Open AI Memory Studio…") {
                            cancelShortcutCapture()
                            NotificationCenter.default.post(name: .keyScribeOpenAIMemoryStudio, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var providersSelectionSheet: some View {
        ZStack {
            AppChromeBackground()

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
            .padding(10)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
            .padding(8)
        }
        .frame(width: 450, height: 500)
    }

    @ViewBuilder
    private var sourceFoldersSelectionSheet: some View {
        ZStack {
            AppChromeBackground()

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
                                .help("Only enabled source providers")
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
            .padding(10)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
            .padding(8)
        }
        .frame(width: 550, height: 500)
    }

    private func prepareMemorySourcesSection() {
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

    private func setMemoryProvidersEnabled(
        _ providers: [MemoryIndexingSettingsService.Provider],
        enabled: Bool
    ) {
        for provider in providers {
            settings.setMemoryProviderEnabled(provider.id, enabled: enabled)
        }
    }

    private func setMemorySourceFoldersEnabled(
        _ folders: [MemoryIndexingSettingsService.SourceFolder],
        enabled: Bool
    ) {
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

        guard showMessage else { return }
        if result.indexQueued {
            memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Queued \(result.queuedSourceCount) selected source(s) for indexing in the background."
        } else {
            memoryActionMessage = "Rescan finished. Detected \(result.providers.count) source providers and \(result.sourceFolders.count) source folders. Queued 0 selected sources for indexing."
        }
    }

    private func handleMemoryIndexingCompletion(_ notification: Notification) {
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
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards. First issue: \(firstFailure)"
            } else {
                memoryActionMessage = "\(actionLabel) finished with \(failureCount) issue(s). Indexed \(indexedFiles) files, skipped \(skippedFiles), and produced \(indexedCards) cards."
            }
            refreshMemoryBrowser()
            return
        }

        memoryActionMessage = "\(actionLabel) finished. Indexed \(indexedFiles) files, skipped \(skippedFiles), produced \(indexedCards) cards, and generated \(indexedRewrites) rewrite suggestion(s)."
        refreshMemoryBrowser()
    }

    private func refreshWhisperModelBrowserState() {
        whisperModelManager.refreshInstallStates()
        ensureSelectedWhisperModelIsValid()
        ensureWhisperBrowserModelSelectionIsValid()
    }

    @ViewBuilder
    private func whisperModelRow(for model: WhisperModelCatalog.Model) -> some View {
        let installState = whisperModelManager.installStateByModelID[model.id] ?? .notInstalled
        let isSelected = settings.selectedWhisperModelID == model.id

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.displayName)
                    .font(.callout.weight(.semibold))

                if model.isEnglishOnly {
                    whisperModelBadge("EN")
                }
                if model.isQuantized {
                    whisperModelBadge("Quantized")
                }
                if model.isDiarization {
                    whisperModelBadge("Diarize")
                }

                if isSelected {
                    Text("Selected")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                }
                Spacer()
                Text(model.diskSizeText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(model.memoryFootprintText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(model.useCaseDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch installState {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            case .installing:
                Text("Installing model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)

            case .installed:
                Text("Installed")
                    .font(.caption)
                    .foregroundStyle(.green)

            case .notInstalled:
                Text("Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(isSelected ? "Using" : "Use Model") {
                    settings.selectedWhisperModelID = model.id
                }
                .buttonStyle(.bordered)
                .disabled(installState != .installed || isSelected)

                switch installState {
                case .downloading:
                    Button("Cancel") {
                        whisperModelManager.cancelDownload(modelID: model.id)
                    }
                    .buttonStyle(.bordered)

                case .installing:
                    Button("Installing…") {}
                        .buttonStyle(.bordered)
                        .disabled(true)

                case .installed:
                    Button("Delete") {
                        whisperModelManager.deleteModel(modelID: model.id)
                        if settings.selectedWhisperModelID == model.id {
                            settings.selectedWhisperModelID = ""
                        }
                    }
                    .buttonStyle(.bordered)

                case .notInstalled, .failed:
                    Button(installState.installButtonTitle) {
                        whisperModelManager.installModel(
                            modelID: model.id,
                            includeCoreML: settings.whisperUseCoreML
                        )
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
    }

    @ViewBuilder
    private func whisperModelBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.10))
            )
    }

    private var whisperFamilyFilterOptions: [String] {
        let defaultOrder = ["tiny", "base", "small", "medium", "large"]
        let availableFamilies = Set(WhisperModelCatalog.curatedModels.map(\.family))

        var options: [String] = ["all"]
        for family in defaultOrder where availableFamilies.contains(family) {
            options.append(family)
        }
        for family in availableFamilies.sorted() where !defaultOrder.contains(family) {
            options.append(family)
        }
        return options
    }

    private var filteredWhisperModels: [WhisperModelCatalog.Model] {
        var models = WhisperModelCatalog.curatedModels

        if whisperFamilyFilter != "all" {
            models = models.filter { $0.family == whisperFamilyFilter }
        }

        if whisperShowInstalledOnly {
            models = models.filter { whisperModelManager.hasInstalledModel(id: $0.id) }
        }

        let query = whisperModelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            models = models.filter { model in
                model.id.lowercased().contains(query) ||
                    model.useCaseDescription.lowercased().contains(query)
            }
        }

        return models.sorted { lhs, rhs in
            let rankByFamily: [String: Int] = [
                "tiny": 0,
                "base": 1,
                "small": 2,
                "medium": 3,
                "large": 4
            ]
            let lhsRank = rankByFamily[lhs.family] ?? 99
            let rhsRank = rankByFamily[rhs.family] ?? 99
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.id < rhs.id
        }
    }

    private var activeWhisperBrowserModel: WhisperModelCatalog.Model? {
        guard !whisperBrowserModelID.isEmpty else { return nil }
        guard filteredWhisperModels.contains(where: { $0.id == whisperBrowserModelID }) else {
            return nil
        }
        return WhisperModelCatalog.model(withID: whisperBrowserModelID)
    }

    private func ensureWhisperBrowserModelSelectionIsValid() {
        guard settings.transcriptionEngine == .whisperCpp else { return }

        if filteredWhisperModels.isEmpty {
            whisperBrowserModelID = ""
            return
        }

        if filteredWhisperModels.contains(where: { $0.id == whisperBrowserModelID }) {
            return
        }

        let preferredID = settings.selectedWhisperModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredID.isEmpty,
           filteredWhisperModels.contains(where: { $0.id == preferredID }) {
            whisperBrowserModelID = preferredID
            return
        }

        whisperBrowserModelID = filteredWhisperModels[0].id
    }

    private func ensureSelectedWhisperModelIsValid() {
        if settings.transcriptionEngine != .whisperCpp {
            return
        }

        if whisperModelManager.hasInstalledModel(id: settings.selectedWhisperModelID) {
            return
        }

        if let firstInstalled = WhisperModelCatalog.curatedModels.first(where: { whisperModelManager.hasInstalledModel(id: $0.id) }) {
            settings.selectedWhisperModelID = firstInstalled.id
        } else {
            settings.selectedWhisperModelID = ""
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            content()
        }
        .padding(14)
        .appThemedSurface(cornerRadius: 10, strokeOpacity: 0.17)
    }

    @ViewBuilder
    private func settingsDisclosureCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 6)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .appThemedSurface(cornerRadius: 10, strokeOpacity: 0.17)
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

    @ViewBuilder
    private func manualShortcutBuilder(for target: ShortcutCaptureTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual map")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Self.shortcutModifierOptions) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { manualShortcutHasModifier(option.flag, for: target) },
                        set: { isEnabled in
                            setManualShortcutModifier(option.flag, enabled: isEnabled, for: target)
                        }
                    ))
                    .toggleStyle(.button)
                }
            }

            HStack(spacing: 10) {
                Text("Primary key")
                    .font(.callout.weight(.medium))
                Picker("Primary key", selection: manualShortcutKeyBinding(for: target)) {
                    Text("Modifier only")
                        .tag(Self.manualModifierOnlyKeyCode)
                    ForEach(manualShortcutKeyOptions) { option in
                        Text(option.label)
                            .tag(option.keyCode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 210)
                .labelsHidden()
            }

            Text("For modifier-only shortcuts, choose 2 to 4 modifiers and select \"Modifier only\".")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func manualShortcutHasModifier(_ modifier: NSEvent.ModifierFlags, for target: ShortcutCaptureTarget) -> Bool {
        ShortcutValidation.filteredModifierFlags(from: shortcutModifiersRaw(for: target)).contains(modifier)
    }

    private func setManualShortcutModifier(
        _ modifier: NSEvent.ModifierFlags,
        enabled: Bool,
        for target: ShortcutCaptureTarget
    ) {
        var flags = ShortcutValidation.filteredModifierFlags(from: shortcutModifiersRaw(for: target))
        if enabled {
            flags.insert(modifier)
        } else {
            flags.remove(modifier)
        }

        _ = applyShortcutSelection(
            for: target,
            keyCode: shortcutKeyCode(for: target),
            modifiersRaw: flags.rawValue,
            validationMessage: "Shortcut must use 2 to 4 keys. Use 1-3 modifiers with a key, or 2-4 modifiers with \"Modifier only\"."
        )
    }

    private func manualShortcutKeyBinding(for target: ShortcutCaptureTarget) -> Binding<UInt16> {
        Binding(
            get: { shortcutKeyCode(for: target) },
            set: { newKeyCode in
                _ = applyShortcutSelection(
                    for: target,
                    keyCode: newKeyCode,
                    modifiersRaw: shortcutModifiersRaw(for: target),
                    validationMessage: "Shortcut must use 2 to 4 keys. Use 1-3 modifiers with a key, or 2-4 modifiers with \"Modifier only\"."
                )
            }
        )
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var searchEntries: [SettingSearchEntry] {
        [
            .init(section: .general, title: "Accessibility access", detail: "Grant or verify accessibility permission", keywords: ["accessibility", "permission", "grant"]),
            .init(section: .general, title: "Copy transcript to clipboard", detail: "Automatically copy dictation results", keywords: ["clipboard", "copy", "output"]),
            .init(section: .general, title: "Dictation sound profile", detail: "Choose tones for start, stop, processing, and pasted cues", keywords: ["sound", "start", "listening", "feedback", "processing", "stop", "pasted"]),
            .init(section: .general, title: "Waveform theme", detail: "Choose visual waveform style", keywords: ["waveform", "theme", "appearance"]),
            .init(section: .shortcuts, title: "Hold-to-talk shortcut", detail: "Set keys for press-and-hold dictation", keywords: ["hold", "shortcut", "keyboard"]),
            .init(section: .shortcuts, title: "Mute shortcut system sounds", detail: "Optionally suppress beeps while hold-to-talk is pressed", keywords: ["mute", "beep", "sound", "hold", "shortcut"]),
            .init(section: .shortcuts, title: "Manual shortcut map", detail: "Click modifiers and choose a key manually", keywords: ["manual", "map", "shortcut", "click", "keys"]),
            .init(section: .shortcuts, title: "Continuous toggle shortcut", detail: "Set keys for start/stop dictation mode", keywords: ["continuous", "toggle", "shortcut"]),
            .init(section: .shortcuts, title: "Paste last transcript", detail: "Reserved shortcut: ⌥⌘V", keywords: ["paste", "last transcript", "reserved"]),
            .init(section: .microphone, title: "Auto-detect microphone", detail: "Automatically use best available input", keywords: ["microphone", "input", "auto"]),
            .init(section: .microphone, title: "Microphone device picker", detail: "Choose a specific microphone manually", keywords: ["microphone", "device", "picker"]),
            .init(section: .recognition, title: "Transcription engine", detail: "Switch between Apple Speech and whisper.cpp", keywords: ["engine", "whisper", "apple", "recognition"]),
            .init(section: .recognition, title: "Contextual language bias", detail: "Improve recognition with likely words", keywords: ["context", "bias", "recognition"]),
            .init(section: .recognition, title: "Preserve words across pauses", detail: "Prevent dropped words in short pauses", keywords: ["pause", "preserve", "recognition"]),
            .init(section: .recognition, title: "Recognition mode", detail: "Choose local/cloud behavior for Apple Speech", keywords: ["on-device", "cloud", "privacy", "recognition"]),
            .init(section: .recognition, title: "Automatic punctuation", detail: "Enable punctuation from Apple Speech", keywords: ["punctuation", "speech"]),
            .init(section: .recognition, title: "Finalize delay", detail: "Control speed vs stability before insertion", keywords: ["delay", "finalize", "timing"]),
            .init(section: .recognition, title: "Cleanup mode", detail: "Light or aggressive text cleanup", keywords: ["cleanup", "mode"]),
            .init(section: .recognition, title: "Custom phrases", detail: "Add names, acronyms, and domain language", keywords: ["phrases", "vocabulary", "context"]),
            .init(section: .models, title: "whisper model install", detail: "Download and manage all whisper.cpp models", keywords: ["model", "download", "whisper", "tiny", "base", "small", "medium", "large"]),
            .init(section: .models, title: "whisper Core ML", detail: "Use Core ML encoder when available", keywords: ["core ml", "ane", "whisper", "speed"]),
            .init(section: .corrections, title: "Adaptive corrections", detail: "Learn from your quick word/phrase fixes", keywords: ["adaptive", "learned", "corrections", "backspace"]),
            .init(section: .corrections, title: "Correction learned sound", detail: "Choose a tone when a new correction is learned", keywords: ["sound", "beep", "feedback", "correction", "learned"]),
            .init(section: .corrections, title: "Learned corrections list", detail: "View, remove, or clear saved corrections", keywords: ["learned", "list", "remove", "clear"]),
            .init(section: .memorySources, title: "AI memory assistant toggle", detail: "Enable or disable memory-based prompt rewrite", keywords: ["memory", "indexing", "toggle", "enable", "ai"]),
            .init(section: .memorySources, title: "Markdown suggestion conversion", detail: "Always convert AI suggestions to Markdown before insertion", keywords: ["markdown", "format", "rewrite", "insert", "assistant"]),
            .init(section: .memorySources, title: "Provider connection status", detail: "See OAuth connection status for OpenAI and Anthropic", keywords: ["provider", "oauth", "openai", "anthropic", "connection"]),
            .init(section: .memorySources, title: "Open AI Memory Studio", detail: "Launch dedicated AI page for full provider and memory controls", keywords: ["ai", "memory studio", "providers", "browser", "rescan", "rebuild"]),
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

    private var canSubmitCorrectionDraft: Bool {
        !correctionSourceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !correctionReplacementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func openCreateCorrectionDialog() {
        correctionEditingSource = nil
        correctionSourceDraft = ""
        correctionReplacementDraft = ""
        correctionDialogMessage = nil
        isCorrectionEditorPresented = true
    }

    private func beginEditingCorrection(_ correction: AdaptiveCorrectionStore.LearnedCorrection) {
        correctionEditingSource = correction.source
        correctionSourceDraft = correction.source
        correctionReplacementDraft = correction.replacement
        correctionDialogMessage = nil
        isCorrectionEditorPresented = true
    }

    private func closeCorrectionEditorDialog() {
        isCorrectionEditorPresented = false
        correctionDialogMessage = nil
        correctionEditingSource = nil
        correctionSourceDraft = ""
        correctionReplacementDraft = ""
    }

    private func submitCorrectionDraft() {
        let originalEditingSource = correctionEditingSource
        guard let saved = adaptiveCorrectionStore.upsertManualCorrection(
            source: correctionSourceDraft,
            replacement: correctionReplacementDraft
        ) else {
            correctionDialogMessage = "Enter both fields with real words."
            return
        }

        if let originalEditingSource, originalEditingSource != saved.source {
            adaptiveCorrectionStore.removeCorrection(source: originalEditingSource)
        }

        correctionDialogMessage = nil
        correctionEditingSource = nil
        correctionSourceDraft = ""
        correctionReplacementDraft = ""
        isCorrectionEditorPresented = false
    }

    @ViewBuilder
    private var correctionEditorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(correctionEditingSource == nil ? "Add Custom Correction" : "Edit Correction")
                .font(.title3.weight(.semibold))

            Text("When KeyScribe hears")
                .font(.callout.weight(.medium))
            TextField("e.g. get ignored", text: $correctionSourceDraft)
                .textFieldStyle(.roundedBorder)

            Text("Replace with")
                .font(.callout.weight(.medium))
            TextField("e.g. gitignored", text: $correctionReplacementDraft)
                .textFieldStyle(.roundedBorder)

            if let correctionDialogMessage {
                Text(correctionDialogMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    closeCorrectionEditorDialog()
                }
                .buttonStyle(.bordered)

                Button(correctionEditingSource == nil ? "Add Correction" : "Save Changes") {
                    submitCorrectionDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitCorrectionDraft)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
        .padding(10)
        .background(AppChromeBackground())
        .frame(width: 460)
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
                        PermissionCenter.requestAccessibilityPermission(
                            using: settings,
                            promptIfNeeded: true,
                            openSettingsIfDenied: false
                        )
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

    private func requestMicrophonePermission() {
        PermissionCenter.requestMicrophonePermission(openSettingsIfDenied: true)
    }

    private func requestSpeechRecognitionPermission() {
        PermissionCenter.requestSpeechRecognitionPermission(openSettingsIfDenied: true)
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

    private func shortcutKeyCode(for target: ShortcutCaptureTarget) -> UInt16 {
        switch target {
        case .holdToTalk:
            settings.shortcutKeyCode
        case .continuousToggle:
            settings.continuousToggleShortcutKeyCode
        }
    }

    private func shortcutModifiersRaw(for target: ShortcutCaptureTarget) -> UInt {
        switch target {
        case .holdToTalk:
            settings.shortcutModifiers
        case .continuousToggle:
            settings.continuousToggleShortcutModifiers
        }
    }

    @discardableResult
    private func applyShortcutSelection(
        for target: ShortcutCaptureTarget,
        keyCode: UInt16,
        modifiersRaw: UInt,
        validationMessage: String
    ) -> Bool {
        let filteredModifiers = ShortcutValidation.filteredModifierRawValue(from: modifiersRaw)
        guard ShortcutValidation.isValid(keyCode: keyCode, modifiersRaw: filteredModifiers) else {
            shortcutCaptureMessage = validationMessage
            return false
        }

        if let conflictMessage = shortcutConflictMessage(
            for: target,
            keyCode: keyCode,
            modifiersRaw: filteredModifiers
        ) {
            shortcutCaptureMessage = conflictMessage
            return false
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
        return true
    }

    private func beginShortcutCapture(for target: ShortcutCaptureTarget) {
        shortcutCaptureTarget = target
        shortcutCaptureMessage = nil
        isCapturingShortcut = true
    }

    private func cancelShortcutCapture() {
        shortcutCaptureTarget = nil
        shortcutCaptureMessage = nil
        isCapturingShortcut = false
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
    private func appLogoImage(size: CGFloat) -> some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSectionHeader(for: .about)

            // Version info
            HStack(spacing: 12) {
                appLogoImage(size: 48)
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
                        PermissionCenter.requestAccessibilityPermission(
                            using: settings,
                            promptIfNeeded: true,
                            openSettingsIfDenied: false
                        )
                    }
                )

                permissionRow(
                    name: "Microphone",
                    granted: microphoneAuthorized,
                    hint: "Required to capture speech",
                    action: {
                        requestMicrophonePermission()
                    }
                )

                permissionRow(
                    name: "Speech Recognition",
                    granted: settings.transcriptionEngine == .appleSpeech ? speechRecognitionAuthorized : true,
                    hint: settings.transcriptionEngine == .appleSpeech
                        ? "Required when Apple Speech engine is selected"
                        : "Not required while whisper.cpp engine is selected",
                    action: {
                        requestSpeechRecognitionPermission()
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
                Text("Remove KeyScribe, reset permissions, and clear local app data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive, action: {
                    // Reset all options to off each time the sheet opens
                    uninstallDeleteDownloadedModels = false
                    uninstallDeleteLearnedCorrections = false
                    uninstallDeleteMemories = false
                    uninstallDeleteProviderCredentials = false
                    showUninstallSheet = true
                }) {
                    Label("Uninstall KeyScribe…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showUninstallSheet) {
                    ZStack {
                        AppChromeBackground()

                        VStack(alignment: .leading, spacing: 16) {
                            Text("Uninstall KeyScribe")
                                .font(.title2.bold())

                            Text("This will reset permissions, remove settings, and uninstall the app. Enable any options below to also remove additional data.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Delete downloaded whisper models", isOn: $uninstallDeleteDownloadedModels)
                                    .toggleStyle(.switch)
                                Toggle("Delete learned corrections", isOn: $uninstallDeleteLearnedCorrections)
                                    .toggleStyle(.switch)
                                Toggle("Delete indexed memories", isOn: $uninstallDeleteMemories)
                                    .toggleStyle(.switch)
                                Toggle("Delete provider credentials (API keys & OAuth sessions)", isOn: $uninstallDeleteProviderCredentials)
                                    .toggleStyle(.switch)
                            }

                            Divider()

                            Text(uninstallSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Spacer()
                                Button("Cancel") {
                                    showUninstallSheet = false
                                }
                                .keyboardShortcut(.cancelAction)

                                Button("Uninstall", role: .destructive) {
                                    showUninstallSheet = false
                                    SettingsStore.resetAndUninstall(
                                        deleteDownloadedModels: uninstallDeleteDownloadedModels,
                                        deleteLearnedCorrections: uninstallDeleteLearnedCorrections,
                                        deleteMemories: uninstallDeleteMemories,
                                        deleteProviderCredentials: uninstallDeleteProviderCredentials
                                    )
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(24)
                        .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.17)
                        .padding(10)
                    }
                    .frame(width: 420)
                }
            }

            Text("Built with Apple Speech and whisper.cpp")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var uninstallSummaryText: String {
        let modelText = uninstallDeleteDownloadedModels ? "delete downloaded whisper models" : "keep downloaded whisper models"
        let correctionText = uninstallDeleteLearnedCorrections ? "delete learned corrections" : "keep learned corrections"
        let memoryText = uninstallDeleteMemories ? "delete indexed memories" : "keep indexed memories"
        let credentialText = uninstallDeleteProviderCredentials ? "delete provider credentials" : "keep provider credentials"

        return "This will reset permissions, remove settings, \(modelText), \(correctionText), \(memoryText), \(credentialText), and uninstall the app."
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

private extension WhisperModelManager.InstallState {
    var installButtonTitle: String {
        switch self {
        case .failed:
            return "Retry Install"
        default:
            return "Install"
        }
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
            AppChromeBackground()

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
            .padding(.top, 34)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.18)
            .padding(10)
        }
        .appScrollbars()
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
        .appThemedSurface(cornerRadius: 14, strokeOpacity: 0.16)
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
        .appThemedSurface(cornerRadius: 12, strokeOpacity: 0.16)
    }
}

struct ShortcutCaptureMonitor: NSViewRepresentable {
    @Binding var isCapturing: Bool
    let onCapture: (UInt16, UInt) -> Bool
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
        private static let manualModifierOnlyKeyCode: UInt16 = UInt16.max
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
            let didCaptureShortcut = parent.onCapture(capturedCode, capturedMods)
            guard didCaptureShortcut else { return false }
            didCapture = true
            stop()
            DispatchQueue.main.async {
                self.parent.isCapturing = false
            }
            return true
        }

        @discardableResult
        private func handleFlagsChanged(_ event: NSEvent, mask: NSEvent.ModifierFlags) -> Bool {
            guard !didCapture else { return true }

            let capturedFlags = event.modifierFlags.intersection(mask)
            let count = ShortcutValidation.modifierCount(in: capturedFlags)
            guard (2...4).contains(count) else { return false }

            let didCaptureShortcut = parent.onCapture(
                Self.manualModifierOnlyKeyCode,
                capturedFlags.rawValue
            )
            guard didCaptureShortcut else { return false }
            didCapture = true
            stop()
            DispatchQueue.main.async {
                self.parent.isCapturing = false
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
