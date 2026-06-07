import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func vaultBootstrapCoordinatorRewritesPreferredAccountIDAfterNormalization() throws {
    try withExclusiveAppLocalization {
        AppLocalization.setPreferredLanguage(.en, preferredLanguages: ["en-US"])

        let harness = try makeHarness()
        let vault = makeVaultStore(harness)
        let backupManager = makeBackupManager(harness)
        let protectedFilesProvider = makeProtectedFilesProvider(for: vault)
        let captureCoordinator = CurrentRuntimeCaptureCoordinator(
            vaultStore: vault,
            backupManager: backupManager,
            protectedFilesProvider: protectedFilesProvider
        )
        let coordinator = VaultBootstrapCoordinator(
            vaultStore: vault,
            backupManager: backupManager,
            currentRuntimeCaptureCoordinator: captureCoordinator,
            protectedFilesProvider: protectedFilesProvider
        )

        let fixture = makeChatGPTNormalizationFixture()

        let accountsRoot = vault.accountsRootURL
        try FileManager.default.createDirectory(at: accountsRoot, withIntermediateDirectories: true)

        try writeTestVaultRecord(
            root: accountsRoot,
            metadata: fixture.legacyMetadata,
            runtime: fixture.legacyRuntime,
            encoder: fixture.encoder
        )
        try writeTestVaultRecord(
            root: accountsRoot,
            metadata: fixture.currentMetadata,
            runtime: fixture.currentRuntime,
            encoder: fixture.encoder
        )
        try fixture.encoder.encode([fixture.legacyMetadata, fixture.currentMetadata]).write(to: vault.indexURL)

        var persistedSettings: AppSettings?
        let outcome = try coordinator.bootstrap(
            currentRuntimeMaterial: nil,
            currentSnapshot: nil,
            settings: AppSettings(preferredAccountID: fixture.legacyMetadata.id),
            saveSettings: { settings, _ in
                persistedSettings = settings
            },
            userFacingMessage: { $0.localizedDescription }
        )

        #expect(outcome.settings.preferredAccountID == vault.accountID(for: fixture.currentRuntime))
        #expect(persistedSettings?.preferredAccountID == vault.accountID(for: fixture.currentRuntime))
        #expect(outcome.statusNotice?.kind == .info)
        #expect(outcome.statusNotice?.message.contains("local vault") == true)
        #expect(outcome.safeSwitchNotice == nil)
    }
}

@Test
func vaultBootstrapCoordinatorPreservesLegacyCustomDisplayNameAfterSwitchCapture() throws {
    let harness = try makeHarness()
    let vault = makeVaultStore(harness)
    let backupManager = makeBackupManager(harness)
    let protectedFilesProvider = makeProtectedFilesProvider(for: vault)
    let captureCoordinator = CurrentRuntimeCaptureCoordinator(
        vaultStore: vault,
        backupManager: backupManager,
        protectedFilesProvider: protectedFilesProvider
    )
    let coordinator = VaultBootstrapCoordinator(
        vaultStore: vault,
        backupManager: backupManager,
        currentRuntimeCaptureCoordinator: captureCoordinator,
        protectedFilesProvider: protectedFilesProvider
    )
    let originalRuntime = makeTestRuntimeMaterial(id: "legacy-switch-alias", authMode: .chatgpt)
    var refreshedAuth = try JSONSerialization.jsonObject(with: originalRuntime.authData) as? [String: Any]
    refreshedAuth?["last_refresh"] = "2026-06-06T05:30:00Z"
    let refreshedRuntime = ProfileRuntimeMaterial(
        authData: try JSONSerialization.data(withJSONObject: try #require(refreshedAuth)),
        configData: originalRuntime.configData
    )
    let inserted = try vault.upsertAccount(
        fallbackDisplayName: "Pix6.5",
        source: .manualChatGPT,
        runtimeMaterial: originalRuntime
    )
    try removeDisplayNameEditedFlag(from: inserted.record.metadataURL)
    try removeDisplayNameEditedFlag(from: vault.indexURL)

    _ = try coordinator.bootstrap(
        currentRuntimeMaterial: refreshedRuntime,
        currentSnapshot: makeTestSnapshot(
            email: "original@example.com",
            primaryRemaining: 80,
            secondaryRemaining: 70,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        settings: AppSettings(),
        saveSettings: { _, _ in },
        userFacingMessage: { $0.localizedDescription }
    )
    let snapshot = try vault.loadSnapshot()

    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts.first?.metadata.displayName == "Pix6.5")
    #expect(snapshot.accounts.first?.metadata.isDisplayNameUserEdited == true)
}

private func removeDisplayNameEditedFlag(from url: URL) throws {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    if var dictionary = object as? [String: Any] {
        dictionary.removeValue(forKey: "isDisplayNameUserEdited")
        try JSONSerialization.data(withJSONObject: dictionary).write(to: url, options: .atomic)
        return
    }

    var array = try #require(object as? [[String: Any]])
    for index in array.indices {
        array[index].removeValue(forKey: "isDisplayNameUserEdited")
    }
    try JSONSerialization.data(withJSONObject: array).write(to: url, options: .atomic)
}
