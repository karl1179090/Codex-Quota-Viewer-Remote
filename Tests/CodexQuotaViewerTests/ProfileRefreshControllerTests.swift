import Foundation
import Testing

@testable import CodexQuotaViewer

@MainActor
@Test
func scheduledRefreshTimerRefreshesSavedAccounts() async throws {
    let harness = try makeHarness()
    defer {
        try? FileManager.default.removeItem(at: harness.homeURL.deletingLastPathComponent())
    }

    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json", isDirectory: false),
        homeDirectoryOverride: harness.homeURL
    )
    let vaultStore = makeVaultStore(harness)
    let savedRuntime = makeTestRuntimeMaterial(id: "saved", authMode: .chatgpt)
    try writeTestVaultRecord(
        root: vaultStore.accountsRootURL,
        metadata: VaultAccountMetadata(
            id: stableAccountRecordID(for: savedRuntime),
            displayName: "saved@example.com",
            authMode: .chatgpt,
            providerID: "openai",
            baseURL: nil,
            model: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: nil,
            source: .currentRuntime,
            runtimeKey: stableAccountIdentityKey(for: savedRuntime)
        ),
        runtime: savedRuntime
    )

    let backupManager = makeBackupManager(harness)
    let captureCoordinator = CurrentRuntimeCaptureCoordinator(
        vaultStore: vaultStore,
        backupManager: backupManager,
        protectedFilesProvider: makeProtectedFilesProvider(for: vaultStore)
    )
    let bootstrapCoordinator = VaultBootstrapCoordinator(
        vaultStore: vaultStore,
        backupManager: backupManager,
        currentRuntimeCaptureCoordinator: captureCoordinator,
        protectedFilesProvider: makeProtectedFilesProvider(for: vaultStore)
    )
    let fetchCounter = ScheduledRefreshFetchCounter()
    let quotaRefreshCoordinator = VaultQuotaRefreshCoordinator(
        snapshotFetcher: { _, _ in
            await fetchCounter.incrementSavedAccountFetches()
            return makeTestSnapshot(
                email: "saved@example.com",
                primaryRemaining: 80,
                secondaryRemaining: 70,
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
    )
    let controller = ProfileRefreshController(
        store: store,
        vaultStore: vaultStore,
        currentSnapshotFetcher: CurrentSnapshotFetcher(
            fetchFromRuntimeMaterial: { _ in
                makeTestSnapshot(
                    email: "current@example.com",
                    primaryRemaining: 90,
                    secondaryRemaining: 80,
                    fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            },
            fetchFromCodexHome: { _ in
                makeTestSnapshot(
                    email: "current@example.com",
                    primaryRemaining: 90,
                    secondaryRemaining: 80,
                    fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            }
        ),
        vaultBootstrapCoordinator: bootstrapCoordinator,
        quotaRefreshCoordinator: quotaRefreshCoordinator,
        quotaCacheStore: VaultQuotaCacheStore(cacheURL: harness.appSupportURL.appendingPathComponent("quota-cache.json")),
        settingsProvider: {
            AppSettings(refreshIntervalPreset: .oneMinute)
        },
        saveSettings: { _, _ in },
        applySettings: { _ in },
        currentProfileBuilder: { _, _, _, _, _ in nil },
        localizedErrorNotice: { kind, en, zh, _ in
            MenuNotice(kind: kind, message: AppLocalization.localized(en: en, zh: zh))
        },
        userFacingMessage: { $0.localizedDescription },
        presentSafeSwitchNotice: { _, _ in },
        setStatusNotice: { _ in },
        onStateChanged: {}
    )

    controller.scheduleRefreshTimer()
    let timer = try #require(refreshTimer(from: controller))
    timer.fire()

    try await waitForScheduledFetchCount(atLeast: 1, counter: fetchCounter)
}

private actor ScheduledRefreshFetchCounter {
    private var savedAccountFetches = 0

    func incrementSavedAccountFetches() {
        savedAccountFetches += 1
    }

    func savedAccountFetchCount() -> Int {
        savedAccountFetches
    }
}

@MainActor
private func refreshTimer(from controller: ProfileRefreshController) -> Timer? {
    for child in Mirror(reflecting: controller).children where child.label == "refreshTimer" {
        let optionalMirror = Mirror(reflecting: child.value)
        return optionalMirror.children.first?.value as? Timer
    }
    return nil
}

private func waitForScheduledFetchCount(
    atLeast expected: Int,
    counter: ScheduledRefreshFetchCounter
) async throws {
    for _ in 0..<200 {
        if await counter.savedAccountFetchCount() >= expected {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    #expect(await counter.savedAccountFetchCount() >= expected)
}
