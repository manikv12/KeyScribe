import Foundation

@inline(__always)
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("❌ \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SettingsStoreWhisperSmokeTests {
    static func main() async {
        let settings = await MainActor.run { SettingsStore.shared }

        let originalEngine = await MainActor.run { settings.transcriptionEngineRawValue }
        let originalModelID = await MainActor.run { settings.selectedWhisperModelID }
        let originalUseCoreML = await MainActor.run { settings.whisperUseCoreML }

        await MainActor.run {
            check(TranscriptionEngineType(rawValue: settings.transcriptionEngineRawValue) != nil, "Default engine should be valid")

            settings.transcriptionEngine = .whisperCpp
            settings.selectedWhisperModelID = "tiny.en"
            settings.whisperUseCoreML = false

            check(settings.transcriptionEngine == .whisperCpp, "Engine setter should persist whisper.cpp")
            check(settings.selectedWhisperModelID == "tiny.en", "Selected whisper model should persist")
            check(settings.whisperUseCoreML == false, "Core ML toggle should persist")

            let defaults = UserDefaults.standard
            check(
                defaults.string(forKey: "KeyScribe.transcriptionEngine") == TranscriptionEngineType.whisperCpp.rawValue,
                "Engine key should be saved in UserDefaults"
            )
            check(
                defaults.string(forKey: "KeyScribe.selectedWhisperModelID") == "tiny.en",
                "Selected model key should be saved in UserDefaults"
            )
            check(
                defaults.bool(forKey: "KeyScribe.whisperUseCoreML") == false,
                "Core ML key should be saved in UserDefaults"
            )

            settings.transcriptionEngineRawValue = "invalid-engine"
            check(settings.transcriptionEngine == .appleSpeech, "Invalid engine raw value should fall back to Apple Speech")
        }

        await MainActor.run {
            settings.transcriptionEngineRawValue = originalEngine
            settings.selectedWhisperModelID = originalModelID
            settings.whisperUseCoreML = originalUseCoreML
        }

        print("✅ Settings store whisper smoke tests passed")
    }
}
