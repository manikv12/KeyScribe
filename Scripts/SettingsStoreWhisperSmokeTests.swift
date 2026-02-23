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
        let originalMemoryIndexingEnabled = await MainActor.run { settings.memoryIndexingEnabled }
        let originalMemoryCatalogAutoUpdate = await MainActor.run { settings.memoryProviderCatalogAutoUpdate }
        let originalDetectedProviderIDs = await MainActor.run { settings.memoryDetectedProviderIDs }
        let originalEnabledProviderIDs = await MainActor.run { settings.memoryEnabledProviderIDs }
        let originalDetectedSourceFolderIDs = await MainActor.run { settings.memoryDetectedSourceFolderIDs }
        let originalEnabledSourceFolderIDs = await MainActor.run { settings.memoryEnabledSourceFolderIDs }

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

            settings.memoryIndexingEnabled = true
            settings.memoryProviderCatalogAutoUpdate = false
            settings.updateDetectedMemoryProviders(["transcript-history", "custom-phrases"])
            settings.setMemoryProviderEnabled("custom-phrases", enabled: false)
            settings.updateDetectedMemoryProviders(["transcript-history", "custom-phrases", "learned-corrections"])

            check(settings.memoryIndexingEnabled == true, "Memory indexing master toggle should persist")
            check(settings.memoryProviderCatalogAutoUpdate == false, "Memory provider catalog auto-update should persist")
            check(
                settings.memoryDetectedProviderIDs == ["custom-phrases", "learned-corrections", "transcript-history"],
                "Detected providers should be normalized and saved"
            )
            check(
                settings.memoryEnabledProviderIDs == ["learned-corrections", "transcript-history"],
                "Disabled providers should stay disabled and new providers should default enabled"
            )
            check(
                settings.isMemoryProviderEnabled("learned-corrections"),
                "Newly detected provider should be enabled"
            )
            check(
                !settings.isMemoryProviderEnabled("custom-phrases"),
                "Explicitly disabled provider should remain disabled"
            )

            settings.updateDetectedMemorySourceFolders(["/tmp/keyscribe-a", "/tmp/keyscribe-b"])
            settings.setMemorySourceFolderEnabled("/tmp/keyscribe-b", enabled: false)
            settings.updateDetectedMemorySourceFolders(["/tmp/keyscribe-a", "/tmp/keyscribe-b", "/tmp/keyscribe-c"])

            check(
                settings.memoryDetectedSourceFolderIDs == ["/tmp/keyscribe-a", "/tmp/keyscribe-b", "/tmp/keyscribe-c"],
                "Detected source folders should be normalized and saved"
            )
            check(
                settings.memoryEnabledSourceFolderIDs == ["/tmp/keyscribe-a", "/tmp/keyscribe-c"],
                "Disabled source folders should stay disabled and new folders should default enabled"
            )
            check(
                settings.isMemorySourceFolderEnabled("/tmp/keyscribe-c"),
                "Newly detected source folder should be enabled"
            )
            check(
                !settings.isMemorySourceFolderEnabled("/tmp/keyscribe-b"),
                "Explicitly disabled source folder should remain disabled"
            )

            check(
                defaults.bool(forKey: "KeyScribe.memoryIndexingEnabled"),
                "Memory indexing key should be saved in UserDefaults"
            )
            check(
                defaults.bool(forKey: "KeyScribe.memoryProviderCatalogAutoUpdate") == false,
                "Memory catalog auto-update key should be saved in UserDefaults"
            )
            check(
                defaults.stringArray(forKey: "KeyScribe.memoryEnabledProviderIDs") == ["learned-corrections", "transcript-history"],
                "Enabled provider IDs key should be saved in UserDefaults"
            )
            check(
                defaults.stringArray(forKey: "KeyScribe.memoryEnabledSourceFolderIDs") == ["/tmp/keyscribe-a", "/tmp/keyscribe-c"],
                "Enabled source folder IDs key should be saved in UserDefaults"
            )
        }

        await MainActor.run {
            settings.transcriptionEngineRawValue = originalEngine
            settings.selectedWhisperModelID = originalModelID
            settings.whisperUseCoreML = originalUseCoreML
            settings.memoryIndexingEnabled = originalMemoryIndexingEnabled
            settings.memoryProviderCatalogAutoUpdate = originalMemoryCatalogAutoUpdate
            settings.memoryDetectedProviderIDs = originalDetectedProviderIDs
            settings.memoryEnabledProviderIDs = originalEnabledProviderIDs
            settings.memoryDetectedSourceFolderIDs = originalDetectedSourceFolderIDs
            settings.memoryEnabledSourceFolderIDs = originalEnabledSourceFolderIDs
        }

        print("✅ Settings store whisper smoke tests passed")
    }
}
