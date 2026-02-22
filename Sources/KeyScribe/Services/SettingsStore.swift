import AppKit
import Foundation
import SwiftUI

enum RecognitionMode: String, CaseIterable, Identifiable {
    case localOnly = "Local Only"
    case cloudOnly = "Cloud Only"
    case automatic = "Automatic"

    var id: Self { self }

    var displayName: String {
        rawValue
    }

    var helpText: String {
        switch self {
        case .localOnly:
            return "All processing stays on your Mac. Faster and fully private, but may be less accurate for complex speech."
        case .cloudOnly:
            return "Audio is sent to Apple servers for recognition. More accurate for difficult speech, but requires an internet connection."
        case .automatic:
            return "Apple decides whether to use on-device or server recognition based on conditions."
        }
    }
}

enum WaveformTheme: String, CaseIterable, Identifiable {
    case vibrantSpectrum = "Vibrant Spectrum"
    case professionalTech = "Professional Tech"
    case monochrome = "Monochrome"
    case neonLagoon = "Neon Lagoon"
    case sunsetCandy = "Sunset Candy"
    case cosmicPop = "Cosmic Pop"
    case mintBlush = "Mint Blush"

    var id: Self { self }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let accessibilityTrustDidBecomeGrantedNotification = Notification.Name(
        "KeyScribe.accessibilityTrustDidBecomeGranted"
    )

    private let defaults = UserDefaults.standard
    private var isApplyingChanges = false

    private enum Keys {
        static let shortcutKeyCode = "KeyScribe.shortcutKeyCode"
        static let shortcutModifiers = "KeyScribe.shortcutModifiers"
        static let continuousMode = "KeyScribe.continuousMode" // legacy key kept for migration safety
        static let continuousToggleShortcutKeyCode = "KeyScribe.continuousToggleShortcutKeyCode"
        static let continuousToggleShortcutModifiers = "KeyScribe.continuousToggleShortcutModifiers"
        static let autoDetectMicrophone = "KeyScribe.autoDetectMicrophone"
        static let selectedMicrophoneUID = "KeyScribe.selectedMicrophoneUID"
        static let copyToClipboard = "KeyScribe.copyToClipboard"
        static let insertionDiagnosticsEnabled = "KeyScribe.insertionDiagnosticsEnabled"
        static let enableContextualBias = "KeyScribe.enableContextualBias"
        static let keepTextAcrossPauses = "KeyScribe.keepTextAcrossPauses"
        static let preferOnDeviceRecognition = "KeyScribe.preferOnDeviceRecognition" // legacy key for migration
        static let recognitionMode = "KeyScribe.recognitionMode"
        static let finalizeDelaySeconds = "KeyScribe.finalizeDelaySeconds"
        static let customContextPhrases = "KeyScribe.customContextPhrases"
        static let textCleanupMode = "KeyScribe.textCleanupMode"
        static let autoPunctuation = "KeyScribe.autoPunctuation"
        static let waveformTheme = "KeyScribe.waveformTheme"
    }

    private enum ContinuousToggleDefaults {
        static let keyCode: UInt16 = 49 // Space
        static let modifiers: UInt = NSEvent.ModifierFlags([.command, .option, .control]).rawValue
    }

    private enum PasteLastShortcut {
        static let keyCode: UInt16 = 9 // V
        static let modifiers: UInt = NSEvent.ModifierFlags([.command, .option]).rawValue
    }

    @Published var shortcutKeyCode: UInt16 {
        didSet {
            save()
        }
    }

    @Published var shortcutModifiers: UInt {
        didSet {
            save()
        }
    }

    @Published var continuousToggleShortcutKeyCode: UInt16 {
        didSet {
            save()
        }
    }

    @Published var continuousToggleShortcutModifiers: UInt {
        didSet {
            save()
        }
    }

    @Published var autoDetectMicrophone: Bool {
        didSet {
            guard oldValue != autoDetectMicrophone else { return }
            if autoDetectMicrophone && !selectedMicrophoneUID.isEmpty {
                selectedMicrophoneUID = ""
            }
            save()
        }
    }

    @Published var selectedMicrophoneUID: String {
        didSet {
            guard oldValue != selectedMicrophoneUID else { return }
            save()
        }
    }

    @Published var copyToClipboard: Bool {
        didSet {
            save()
        }
    }

    @Published var insertionDiagnosticsEnabled: Bool {
        didSet {
            save()
        }
    }

    @Published var enableContextualBias: Bool {
        didSet {
            save()
        }
    }

    @Published var keepTextAcrossPauses: Bool {
        didSet {
            save()
        }
    }

    @Published var recognitionModeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var finalizeDelaySeconds: Double {
        didSet {
            save()
        }
    }

    @Published var customContextPhrases: String {
        didSet {
            save()
        }
    }

    @Published var textCleanupModeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var autoPunctuation: Bool {
        didSet {
            save()
        }
    }

    @Published var waveformThemeRawValue: String {
        didSet {
            save()
        }
    }

    @Published var availableMicrophones: [MicrophoneOption] = []
    @Published var accessibilityTrusted: Bool = AXIsProcessTrusted()

    /// Called whenever user-facing settings change. The app can subscribe and reconfigure features.
    var onChange: (() -> Void)?

    private init() {
        isApplyingChanges = true

        var initialShortcutKeyCode: UInt16
        if defaults.object(forKey: Keys.shortcutKeyCode) == nil {
            initialShortcutKeyCode = ShortcutValidation.defaultKeyCode
        } else {
            initialShortcutKeyCode = UInt16(defaults.integer(forKey: Keys.shortcutKeyCode))
        }

        let storedModifiers = defaults.integer(forKey: Keys.shortcutModifiers)
        var initialShortcutModifiers = storedModifiers == 0
            ? ShortcutValidation.defaultModifiers
            : UInt(storedModifiers)

        if !ShortcutValidation.isValid(keyCode: initialShortcutKeyCode, modifiersRaw: initialShortcutModifiers) {
            initialShortcutKeyCode = ShortcutValidation.defaultKeyCode
            initialShortcutModifiers = ShortcutValidation.defaultModifiers
        }
        shortcutKeyCode = initialShortcutKeyCode
        shortcutModifiers = ShortcutValidation.filteredModifierRawValue(from: initialShortcutModifiers)

        let storedContinuousToggleKeyCode: UInt16
        if defaults.object(forKey: Keys.continuousToggleShortcutKeyCode) == nil {
            storedContinuousToggleKeyCode = ContinuousToggleDefaults.keyCode
        } else {
            storedContinuousToggleKeyCode = UInt16(defaults.integer(forKey: Keys.continuousToggleShortcutKeyCode))
        }

        let storedContinuousToggleModifiersRaw: UInt
        if defaults.object(forKey: Keys.continuousToggleShortcutModifiers) == nil {
            storedContinuousToggleModifiersRaw = ContinuousToggleDefaults.modifiers
        } else {
            storedContinuousToggleModifiersRaw = UInt(defaults.integer(forKey: Keys.continuousToggleShortcutModifiers))
        }

        let resolvedContinuousToggle = Self.resolveContinuousToggleShortcut(
            keyCode: storedContinuousToggleKeyCode,
            modifiersRaw: storedContinuousToggleModifiersRaw,
            holdToTalkKeyCode: initialShortcutKeyCode,
            holdToTalkModifiersRaw: ShortcutValidation.filteredModifierRawValue(from: initialShortcutModifiers)
        )
        continuousToggleShortcutKeyCode = resolvedContinuousToggle.keyCode
        continuousToggleShortcutModifiers = resolvedContinuousToggle.modifiersRaw

        if defaults.object(forKey: Keys.autoDetectMicrophone) == nil {
            autoDetectMicrophone = true
        } else {
            autoDetectMicrophone = defaults.bool(forKey: Keys.autoDetectMicrophone)
        }

        if defaults.object(forKey: Keys.copyToClipboard) == nil {
            copyToClipboard = false
        } else {
            copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        }

        if defaults.object(forKey: Keys.insertionDiagnosticsEnabled) == nil {
            insertionDiagnosticsEnabled = false
        } else {
            insertionDiagnosticsEnabled = defaults.bool(forKey: Keys.insertionDiagnosticsEnabled)
        }

        if defaults.object(forKey: Keys.enableContextualBias) == nil {
            enableContextualBias = true
        } else {
            enableContextualBias = defaults.bool(forKey: Keys.enableContextualBias)
        }

        if defaults.object(forKey: Keys.keepTextAcrossPauses) == nil {
            keepTextAcrossPauses = true
        } else {
            keepTextAcrossPauses = defaults.bool(forKey: Keys.keepTextAcrossPauses)
        }

        // Migration: convert legacy preferOnDeviceRecognition bool → recognitionMode
        if let storedMode = defaults.string(forKey: Keys.recognitionMode),
           RecognitionMode(rawValue: storedMode) != nil {
            recognitionModeRawValue = storedMode
        } else if defaults.object(forKey: Keys.preferOnDeviceRecognition) != nil {
            let oldPref = defaults.bool(forKey: Keys.preferOnDeviceRecognition)
            recognitionModeRawValue = (oldPref ? RecognitionMode.localOnly : RecognitionMode.automatic).rawValue
        } else {
            recognitionModeRawValue = RecognitionMode.localOnly.rawValue
        }

        let storedFinalizeDelay = defaults.object(forKey: Keys.finalizeDelaySeconds) == nil
            ? 0.25
            : defaults.double(forKey: Keys.finalizeDelaySeconds)
        finalizeDelaySeconds = min(1.2, max(0.15, storedFinalizeDelay))

        customContextPhrases = defaults.string(forKey: Keys.customContextPhrases) ?? ""

        let storedCleanup = defaults.string(forKey: Keys.textCleanupMode) ?? TextCleanupMode.light.rawValue
        if TextCleanupMode(rawValue: storedCleanup) == nil {
            textCleanupModeRawValue = TextCleanupMode.light.rawValue
        } else {
            textCleanupModeRawValue = storedCleanup
        }

        if defaults.object(forKey: Keys.autoPunctuation) == nil {
            autoPunctuation = true
        } else {
            autoPunctuation = defaults.bool(forKey: Keys.autoPunctuation)
        }

        let storedTheme = defaults.string(forKey: Keys.waveformTheme) ?? WaveformTheme.vibrantSpectrum.rawValue
        if WaveformTheme(rawValue: storedTheme) == nil {
            waveformThemeRawValue = WaveformTheme.vibrantSpectrum.rawValue
        } else {
            waveformThemeRawValue = storedTheme
        }

        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID) ?? ""

        refreshMicrophones(notifyChange: false)
        refreshAccessibilityStatus(prompt: false)

        isApplyingChanges = false
        save()
    }

    func refreshAccessibilityStatus(prompt: Bool) {
        let previousTrust = accessibilityTrusted

        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        accessibilityTrusted = AXIsProcessTrusted()
        if !previousTrust && accessibilityTrusted {
            NotificationCenter.default.post(
                name: Self.accessibilityTrustDidBecomeGrantedNotification,
                object: self
            )
        }
    }

    func refreshMicrophones(notifyChange: Bool = true) {
        isApplyingChanges = true
        let previousSelectedMicrophoneUID = selectedMicrophoneUID

        let list = MicrophoneManager.availableMicrophones()
        availableMicrophones = list

        if !autoDetectMicrophone {
            if selectedMicrophoneUID.isEmpty, let fallback = MicrophoneManager.defaultMicrophoneUID() {
                selectedMicrophoneUID = fallback
            }

            if !selectedMicrophoneUID.isEmpty,
               !availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }) {
                selectedMicrophoneUID = availableMicrophones.first?.uid ?? ""
            }
        }

        let didChangeSelectedMicrophone = selectedMicrophoneUID != previousSelectedMicrophoneUID
        let shouldNotify = notifyChange && didChangeSelectedMicrophone && onChange != nil
        isApplyingChanges = false
        if shouldNotify {
            onChange?()
        }
    }

    func save() {
        defaults.set(Int(shortcutKeyCode), forKey: Keys.shortcutKeyCode)
        defaults.set(Int(ShortcutValidation.filteredModifierRawValue(from: shortcutModifiers)), forKey: Keys.shortcutModifiers)
        defaults.set(Int(continuousToggleShortcutKeyCode), forKey: Keys.continuousToggleShortcutKeyCode)
        defaults.set(Int(ShortcutValidation.filteredModifierRawValue(from: continuousToggleShortcutModifiers)), forKey: Keys.continuousToggleShortcutModifiers)
        defaults.set(autoDetectMicrophone, forKey: Keys.autoDetectMicrophone)
        defaults.set(selectedMicrophoneUID, forKey: Keys.selectedMicrophoneUID)
        defaults.set(copyToClipboard, forKey: Keys.copyToClipboard)
        defaults.set(insertionDiagnosticsEnabled, forKey: Keys.insertionDiagnosticsEnabled)
        defaults.set(enableContextualBias, forKey: Keys.enableContextualBias)
        defaults.set(keepTextAcrossPauses, forKey: Keys.keepTextAcrossPauses)
        defaults.set(recognitionModeRawValue, forKey: Keys.recognitionMode)
        defaults.set(min(1.2, max(0.15, finalizeDelaySeconds)), forKey: Keys.finalizeDelaySeconds)
        defaults.set(customContextPhrases, forKey: Keys.customContextPhrases)
        defaults.set(textCleanupModeRawValue, forKey: Keys.textCleanupMode)
        defaults.set(autoPunctuation, forKey: Keys.autoPunctuation)
        defaults.set(waveformThemeRawValue, forKey: Keys.waveformTheme)

        guard !isApplyingChanges else { return }
        onChange?()
    }

    var shortcutModifierFlags: NSEvent.ModifierFlags {
        ShortcutValidation.filteredModifierFlags(from: shortcutModifiers)
    }

    var continuousToggleShortcutModifierFlags: NSEvent.ModifierFlags {
        ShortcutValidation.filteredModifierFlags(from: continuousToggleShortcutModifiers)
    }

    var recognitionMode: RecognitionMode {
        get { RecognitionMode(rawValue: recognitionModeRawValue) ?? .localOnly }
        set { recognitionModeRawValue = newValue.rawValue }
    }

    var textCleanupMode: TextCleanupMode {
        get { TextCleanupMode(rawValue: textCleanupModeRawValue) ?? .light }
        set { textCleanupModeRawValue = newValue.rawValue }
    }

    var waveformTheme: WaveformTheme {
        get { WaveformTheme(rawValue: waveformThemeRawValue) ?? .vibrantSpectrum }
        set { waveformThemeRawValue = newValue.rawValue }
    }

    /// Resets all permissions, deletes UserDefaults, and removes the app bundle.
    /// Requires admin privileges for tccutil and rm of /Applications bundle.
    static func resetAndUninstall() {
        let currentBundleID = Bundle.main.bundleIdentifier ?? "com.keyscribe.KeyScribe"
        // Include legacy IDs so old TCC rows are cleaned up during uninstall.
        let bundleIDs = Array(
            Set([
                currentBundleID,
                "com.keyscribe.KeyScribe",
                "com.manikvashith.KeyScribe"
            ])
        )
        let appPath = Bundle.main.bundlePath

        // Build a shell script that:
        // 1. Resets TCC permissions (Accessibility, Microphone, Speech Recognition)
        // 2. Removes UserDefaults plist
        // 3. Removes the .app bundle from /Applications
        let resetCommands = bundleIDs.flatMap { bundleID in
            [
                "tccutil reset Accessibility \(bundleID) 2>/dev/null || true",
                "tccutil reset Microphone \(bundleID) 2>/dev/null || true",
                "tccutil reset SpeechRecognition \(bundleID) 2>/dev/null || true"
            ]
        }.joined(separator: "; ")

        let prefsCleanupCommands = bundleIDs.map { bundleID in
            "rm -f '\(NSHomeDirectory())/Library/Preferences/\(bundleID).plist'"
        }.joined(separator: "; ")

        let cacheCleanupCommands = bundleIDs.map { bundleID in
            "rm -rf '\(NSHomeDirectory())/Library/Caches/\(bundleID)'"
        }.joined(separator: "; ")

        let script = """
        \(resetCommands); \
        \(prefsCleanupCommands); \
        \(cacheCleanupCommands); \
        rm -rf '\(appPath)'
        """

        let appleScript = """
        do shell script "\(script)" with administrator privileges
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            scriptObject.executeAndReturnError(&error)
            if error == nil {
                // Successfully uninstalled — quit the app
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func hasModifier(_ modifier: NSEvent.ModifierFlags) -> Bool {
        shortcutModifierFlags.contains(modifier)
    }

    func setModifier(_ modifier: NSEvent.ModifierFlags, enabled: Bool) {
        if enabled {
            shortcutModifiers |= modifier.rawValue
        } else {
            shortcutModifiers &= ~modifier.rawValue
        }
    }

    private static func normalizedShortcut(
        keyCode: UInt16,
        modifiersRaw: UInt,
        defaultKeyCode: UInt16,
        defaultModifiersRaw: UInt
    ) -> (keyCode: UInt16, modifiersRaw: UInt) {
        let filtered = ShortcutValidation.filteredModifierRawValue(from: modifiersRaw)
        if ShortcutValidation.isValid(keyCode: keyCode, modifiersRaw: filtered) {
            return (keyCode, filtered)
        }

        let fallbackFiltered = ShortcutValidation.filteredModifierRawValue(from: defaultModifiersRaw)
        return (defaultKeyCode, fallbackFiltered)
    }

    private static func shortcutsConflict(
        lhsKeyCode: UInt16,
        lhsModifiersRaw: UInt,
        rhsKeyCode: UInt16,
        rhsModifiersRaw: UInt
    ) -> Bool {
        lhsKeyCode == rhsKeyCode &&
            ShortcutValidation.filteredModifierRawValue(from: lhsModifiersRaw) ==
            ShortcutValidation.filteredModifierRawValue(from: rhsModifiersRaw)
    }

    private static func resolveContinuousToggleShortcut(
        keyCode: UInt16,
        modifiersRaw: UInt,
        holdToTalkKeyCode: UInt16,
        holdToTalkModifiersRaw: UInt
    ) -> (keyCode: UInt16, modifiersRaw: UInt) {
        let normalized = normalizedShortcut(
            keyCode: keyCode,
            modifiersRaw: modifiersRaw,
            defaultKeyCode: ContinuousToggleDefaults.keyCode,
            defaultModifiersRaw: ContinuousToggleDefaults.modifiers
        )

        if !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: holdToTalkKeyCode,
            rhsModifiersRaw: holdToTalkModifiersRaw
        ) && !shortcutsConflict(
            lhsKeyCode: normalized.keyCode,
            lhsModifiersRaw: normalized.modifiersRaw,
            rhsKeyCode: PasteLastShortcut.keyCode,
            rhsModifiersRaw: PasteLastShortcut.modifiers
        ) {
            return normalized
        }

        let fallbacks: [(UInt16, UInt)] = [
            (ContinuousToggleDefaults.keyCode, ContinuousToggleDefaults.modifiers),
            (36, NSEvent.ModifierFlags([.command, .option]).rawValue), // Return
            (8, NSEvent.ModifierFlags([.command, .option, .control]).rawValue) // C
        ]

        for candidate in fallbacks {
            let normalizedCandidate = normalizedShortcut(
                keyCode: candidate.0,
                modifiersRaw: candidate.1,
                defaultKeyCode: ContinuousToggleDefaults.keyCode,
                defaultModifiersRaw: ContinuousToggleDefaults.modifiers
            )
            let conflictsHold = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: holdToTalkKeyCode,
                rhsModifiersRaw: holdToTalkModifiersRaw
            )
            let conflictsPasteLast = shortcutsConflict(
                lhsKeyCode: normalizedCandidate.keyCode,
                lhsModifiersRaw: normalizedCandidate.modifiersRaw,
                rhsKeyCode: PasteLastShortcut.keyCode,
                rhsModifiersRaw: PasteLastShortcut.modifiers
            )
            if !conflictsHold && !conflictsPasteLast {
                return normalizedCandidate
            }
        }

        return normalized
    }

}
