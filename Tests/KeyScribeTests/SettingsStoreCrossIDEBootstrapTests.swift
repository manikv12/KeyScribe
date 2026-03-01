import XCTest
@testable import KeyScribe

@MainActor
final class SettingsStoreCrossIDEBootstrapTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "KeyScribeTests.SettingsStore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create isolated defaults suite: \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testBootstrapAppliesOneTimeMigrationForFreshDefaults() {
        let defaults = makeIsolatedDefaults()

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: true, source: .fallback)
        )

        XCTAssertTrue(result.settingEnabled)
        XCTAssertTrue(result.runtimeEnabled)
        XCTAssertEqual(result.source, "migration")
        XCTAssertTrue(result.migrationApplied)
        XCTAssertEqual(
            defaults.bool(forKey: "KeyScribe.promptRewriteCrossIDEConversationSharingEnabled"),
            true
        )
        XCTAssertEqual(
            defaults.bool(forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey),
            true
        )
    }

    func testBootstrapMigratesExistingFalseValueWhenSentinelMissing() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "KeyScribe.promptRewriteCrossIDEConversationSharingEnabled")

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: true, source: .userDefault)
        )

        XCTAssertTrue(result.settingEnabled)
        XCTAssertTrue(result.runtimeEnabled)
        XCTAssertEqual(result.source, "migration")
        XCTAssertTrue(result.migrationApplied)
        XCTAssertEqual(
            defaults.bool(forKey: "KeyScribe.promptRewriteCrossIDEConversationSharingEnabled"),
            true
        )
        XCTAssertEqual(
            defaults.bool(forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey),
            true
        )
    }

    func testBootstrapSkipsMigrationWhenEnvironmentHardOffAndSettingMissing() {
        let defaults = makeIsolatedDefaults()

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: false, source: .env)
        )

        XCTAssertFalse(result.settingEnabled)
        XCTAssertFalse(result.runtimeEnabled)
        XCTAssertEqual(result.source, "env")
        XCTAssertFalse(result.migrationApplied)
        XCTAssertNil(defaults.object(forKey: "KeyScribe.promptRewriteCrossIDEConversationSharingEnabled"))
        XCTAssertNil(defaults.object(forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey))
    }

    func testBootstrapDoesNotForceRewriteWhenMigrationAlreadyApplied() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: SettingsStore.crossIDEConversationSharingMigrationDefaultsKey)
        defaults.set(false, forKey: "KeyScribe.promptRewriteCrossIDEConversationSharingEnabled")

        let result = SettingsStore.resolveCrossIDEConversationSharingBootstrap(
            defaults: defaults,
            featureResolution: .init(enabled: false, source: .userDefault)
        )

        XCTAssertFalse(result.settingEnabled)
        XCTAssertFalse(result.runtimeEnabled)
        XCTAssertEqual(result.source, "user-default")
        XCTAssertFalse(result.migrationApplied)
    }
}
