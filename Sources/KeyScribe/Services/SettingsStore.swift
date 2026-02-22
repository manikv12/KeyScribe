import AppKit
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let supportedShortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let defaultShortcutKeyCode: UInt16 = 49
    private static let defaultShortcutModifiers: UInt = NSEvent.ModifierFlags([.command, .option]).rawValue

    private let defaults = UserDefaults.standard
    private var isApplyingChanges = false

    private enum Keys {
        static let shortcutKeyCode = "KeyScribe.shortcutKeyCode"
        static let shortcutModifiers = "KeyScribe.shortcutModifiers"
        static let continuousMode = "KeyScribe.continuousMode"
        static let autoDetectMicrophone = "KeyScribe.autoDetectMicrophone"
        static let selectedMicrophoneUID = "KeyScribe.selectedMicrophoneUID"
        static let copyToClipboard = "KeyScribe.copyToClipboard"
        static let enableContextualBias = "KeyScribe.enableContextualBias"
        static let keepTextAcrossPauses = "KeyScribe.keepTextAcrossPauses"
        static let preferOnDeviceRecognition = "KeyScribe.preferOnDeviceRecognition"
        static let finalizeDelaySeconds = "KeyScribe.finalizeDelaySeconds"
        static let customContextPhrases = "KeyScribe.customContextPhrases"
        static let textCleanupMode = "KeyScribe.textCleanupMode"
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

    @Published var continuousMode: Bool {
        didSet {
            save()
        }
    }

    @Published var autoDetectMicrophone: Bool {
        didSet {
            if autoDetectMicrophone {
                selectedMicrophoneUID = ""
            }
            save()
        }
    }

    @Published var selectedMicrophoneUID: String {
        didSet {
            if autoDetectMicrophone {
                selectedMicrophoneUID = ""
            }
            save()
        }
    }

    @Published var copyToClipboard: Bool {
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

    @Published var preferOnDeviceRecognition: Bool {
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

    @Published var availableMicrophones: [MicrophoneOption] = []

    /// Called whenever user-facing settings change. The app can subscribe and reconfigure features.
    var onChange: (() -> Void)?

    private init() {
        isApplyingChanges = true

        var initialShortcutKeyCode: UInt16
        if defaults.object(forKey: Keys.shortcutKeyCode) == nil {
            initialShortcutKeyCode = Self.defaultShortcutKeyCode
        } else {
            initialShortcutKeyCode = UInt16(defaults.integer(forKey: Keys.shortcutKeyCode))
        }

        let storedModifiers = defaults.integer(forKey: Keys.shortcutModifiers)
        var initialShortcutModifiers = storedModifiers == 0
            ? Self.defaultShortcutModifiers
            : UInt(storedModifiers)

        if !Self.isValidShortcut(keyCode: initialShortcutKeyCode, modifiers: initialShortcutModifiers) {
            initialShortcutKeyCode = Self.defaultShortcutKeyCode
            initialShortcutModifiers = Self.defaultShortcutModifiers
        }
        shortcutKeyCode = initialShortcutKeyCode
        shortcutModifiers = initialShortcutModifiers

        if defaults.object(forKey: Keys.continuousMode) == nil {
            continuousMode = true
        } else {
            continuousMode = defaults.bool(forKey: Keys.continuousMode)
        }

        if defaults.object(forKey: Keys.autoDetectMicrophone) == nil {
            autoDetectMicrophone = true
        } else {
            autoDetectMicrophone = defaults.bool(forKey: Keys.autoDetectMicrophone)
        }

        if defaults.object(forKey: Keys.copyToClipboard) == nil {
            copyToClipboard = true
        } else {
            copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
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

        if defaults.object(forKey: Keys.preferOnDeviceRecognition) == nil {
            preferOnDeviceRecognition = true
        } else {
            preferOnDeviceRecognition = defaults.bool(forKey: Keys.preferOnDeviceRecognition)
        }

        let storedFinalizeDelay = defaults.object(forKey: Keys.finalizeDelaySeconds) == nil
            ? 0.35
            : defaults.double(forKey: Keys.finalizeDelaySeconds)
        finalizeDelaySeconds = min(1.2, max(0.15, storedFinalizeDelay))

        customContextPhrases = defaults.string(forKey: Keys.customContextPhrases) ?? ""

        let storedCleanup = defaults.string(forKey: Keys.textCleanupMode) ?? TextCleanupMode.light.rawValue
        if TextCleanupMode(rawValue: storedCleanup) == nil {
            textCleanupModeRawValue = TextCleanupMode.light.rawValue
        } else {
            textCleanupModeRawValue = storedCleanup
        }

        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID) ?? ""

        refreshMicrophones()

        isApplyingChanges = false
        save()
    }

    func refreshMicrophones() {
        isApplyingChanges = true

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

        let shouldNotify = onChange != nil
        isApplyingChanges = false
        if shouldNotify {
            onChange?()
        }
    }

    func save() {
        defaults.set(Int(shortcutKeyCode), forKey: Keys.shortcutKeyCode)
        defaults.set(Int(shortcutModifiers), forKey: Keys.shortcutModifiers)
        defaults.set(continuousMode, forKey: Keys.continuousMode)
        defaults.set(autoDetectMicrophone, forKey: Keys.autoDetectMicrophone)
        defaults.set(selectedMicrophoneUID, forKey: Keys.selectedMicrophoneUID)
        defaults.set(copyToClipboard, forKey: Keys.copyToClipboard)
        defaults.set(enableContextualBias, forKey: Keys.enableContextualBias)
        defaults.set(keepTextAcrossPauses, forKey: Keys.keepTextAcrossPauses)
        defaults.set(preferOnDeviceRecognition, forKey: Keys.preferOnDeviceRecognition)
        defaults.set(min(1.2, max(0.15, finalizeDelaySeconds)), forKey: Keys.finalizeDelaySeconds)
        defaults.set(customContextPhrases, forKey: Keys.customContextPhrases)
        defaults.set(textCleanupModeRawValue, forKey: Keys.textCleanupMode)

        guard !isApplyingChanges else { return }
        onChange?()
    }

    var shortcutModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: shortcutModifiers)
    }

    var textCleanupMode: TextCleanupMode {
        get { TextCleanupMode(rawValue: textCleanupModeRawValue) ?? .light }
        set { textCleanupModeRawValue = newValue.rawValue }
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

    private static func modifierCount(_ flags: NSEvent.ModifierFlags) -> Int {
        var count = 0
        if flags.contains(.function) { count += 1 }
        if flags.contains(.control) { count += 1 }
        if flags.contains(.option) { count += 1 }
        if flags.contains(.shift) { count += 1 }
        if flags.contains(.command) { count += 1 }
        return count
    }

    private static func isValidShortcut(keyCode: UInt16, modifiers: UInt) -> Bool {
        let filteredModifiers = NSEvent.ModifierFlags(rawValue: modifiers).intersection(supportedShortcutModifiers)
        let count = modifierCount(filteredModifiers)

        if keyCode == UInt16.max {
            return (2...3).contains(count)
        }

        guard !modifierOnlyKeyCodes.contains(keyCode) else { return false }
        return (1...2).contains(count)
    }
}
