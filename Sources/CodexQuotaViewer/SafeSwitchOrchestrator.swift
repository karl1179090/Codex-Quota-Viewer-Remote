import Foundation

struct OfficialRepairSummary: Codable, Equatable {
    let createdThreads: Int
    let updatedThreads: Int
    let updatedSessionIndexEntries: Int
    let removedBrokenThreads: Int
    let hiddenSnapshotOnlySessions: Int
}

struct SwitchOperationPreview: Equatable {
    let targetProfile: ProviderProfile
    let targetProviderID: String
    let filesToBackup: [URL]
    let rolloutFilesToUpdate: [URL]
    let codexWasRunning: Bool
    let remote: RemoteSwitchPreview?
}

enum SwitchBackupStrategy: Equatable {
    case createRestorePoint
    case directWithoutBackup
}

enum RemoteSwitchFailureResolution: Equatable {
    case retry
    case rollback
    case keepSuccessful
}

typealias RemoteSwitchFailureResolutionProvider = @MainActor (
    RemoteSwitchPartialFailureError,
    String?
) async -> RemoteSwitchFailureResolution

struct RemoteSwitchPreview: Equatable {
    let sshTargets: [String]
    let codexHomePath: String

    init(sshTarget: String, codexHomePath: String) {
        self.sshTargets = [sshTarget]
        self.codexHomePath = codexHomePath
    }

    init(sshTargets: [String], codexHomePath: String) {
        self.sshTargets = sshTargets
        self.codexHomePath = codexHomePath
    }

    var sshTarget: String {
        sshTargets.joined(separator: ", ")
    }
}

struct SwitchOperationResult: Equatable {
    let targetProfileID: String
    let restorePoint: RestorePointManifest?
    let updatedRolloutCount: Int
    let repairSummary: OfficialRepairSummary
    let remoteResult: RemoteSwitchResult?
}

struct RepairOperationResult: Equatable {
    let restorePoint: RestorePointManifest
    let repairSummary: OfficialRepairSummary
}

enum SwitchOrchestratorError: LocalizedError {
    case missingRuntimeConfig(String)
    case missingProviderIdentifier(String)
    case automaticRollbackFailed

    var errorDescription: String? {
        switch self {
        case .missingRuntimeConfig(let name):
            return AppLocalization.localized(
                en: "The target profile “\(name)” does not have enough runtime config to switch safely.",
                zh: "目标账号“\(name)”缺少足够的运行时配置，无法安全切换。"
            )
        case .missingProviderIdentifier(let name):
            return AppLocalization.localized(
                en: "The target profile “\(name)” is missing a model provider identifier.",
                zh: "目标账号“\(name)”缺少 model provider 标识。"
            )
        case .automaticRollbackFailed:
            return AppLocalization.localized(
                en: "The operation failed and the automatic rollback could not be completed. Use the latest restore point to roll back manually.",
                zh: "操作失败，且自动回滚未能完成。请使用最新还原点手动回滚。"
            )
        }
    }
}

@MainActor
final class SwitchOrchestrator {
    private let store: ProfileStore
    private let backupManager: BackupManager
    private let rolloutSynchronizer: RolloutProviderSynchronizer
    private let repairClient: OfficialThreadRepairing
    private let historyRepairer: HistoryMetadataRepairing
    private let desktopController: CodexDesktopControlling
    private let quotaChannelInvalidator: CodexRPCChannelInvalidating
    private let remoteSwitchClient: RemoteSwitching

    init(
        store: ProfileStore,
        backupManager: BackupManager,
        rolloutSynchronizer: RolloutProviderSynchronizer,
        repairClient: OfficialThreadRepairing,
        historyRepairer: HistoryMetadataRepairing = HistoryMetadataRepairer(),
        desktopController: CodexDesktopControlling,
        quotaChannelInvalidator: CodexRPCChannelInvalidating,
        remoteSwitchClient: RemoteSwitching = SSHRemoteSwitchClient()
    ) {
        self.store = store
        self.backupManager = backupManager
        self.rolloutSynchronizer = rolloutSynchronizer
        self.repairClient = repairClient
        self.historyRepairer = historyRepairer
        self.desktopController = desktopController
        self.quotaChannelInvalidator = quotaChannelInvalidator
        self.remoteSwitchClient = remoteSwitchClient
    }

    func preview(
        targetProfile: ProviderProfile,
        remoteSettings: RemoteSwitchSettings = RemoteSwitchSettings()
    ) throws -> SwitchOperationPreview {
        let effectiveConfig = try effectiveTargetConfigData(for: targetProfile)
        let targetProviderID = try resolveTargetProviderID(
            for: targetProfile,
            effectiveConfigData: effectiveConfig
        )
        let rolloutFilesToUpdate = try rolloutSynchronizer.plannedUpdates(
            in: [store.sessionsRootURL, store.archivedSessionsRootURL],
            targetProvider: targetProviderID
        )
        let filesToBackup = deduplicatedStandardizedFileURLs(
            store.protectedMutationFileURLs(
                additionalFiles: rolloutFilesToUpdate + targetProfile.managedFileURLs
            )
        )

        return SwitchOperationPreview(
            targetProfile: targetProfile,
            targetProviderID: targetProviderID,
            filesToBackup: filesToBackup,
            rolloutFilesToUpdate: rolloutFilesToUpdate,
            codexWasRunning: desktopController.isRunning,
            remote: remoteSettings.shouldSyncRemote
                ? RemoteSwitchPreview(
                    sshTargets: remoteSettings.trimmedSSHTargets,
                    codexHomePath: remoteSettings.effectiveCodexHomePath
                )
                : nil
        )
    }

    func perform(
        targetProfile: ProviderProfile,
        remoteSettings: RemoteSwitchSettings = RemoteSwitchSettings(),
        backupStrategy: SwitchBackupStrategy = .createRestorePoint,
        terminateRemoteCodexProcesses: Bool = false,
        remoteFailureResolutionProvider: RemoteSwitchFailureResolutionProvider? = nil
    ) async throws -> SwitchOperationResult {
        let previouslyRunning = try await desktopController.closeIfRunning()
        var restorePoint: RestorePointManifest?
        var remoteRollbackSettings: RemoteSwitchSettings?

        do {
            let latestPreview = try preview(
                targetProfile: targetProfile,
                remoteSettings: remoteSettings
            )
            let writer: FileDataWriting
            switch backupStrategy {
            case .createRestorePoint:
                let createdRestorePoint = try backupManager.createRestorePoint(
                    reason: "safe-switch",
                    summary: "Switch to \(targetProfile.displayName)",
                    files: latestPreview.filesToBackup,
                    codexWasRunning: previouslyRunning
                )
                restorePoint = createdRestorePoint
                writer = ProtectedFileMutationContext(restorePoint: createdRestorePoint)
            case .directWithoutBackup:
                writer = DirectFileDataWriter()
            }

            let targetConfig = try effectiveTargetConfigData(for: targetProfile)
            let mergedConfig = try mergeRuntimeConfig(
                currentConfigData: try store.currentConfigData(),
                targetConfigData: targetConfig,
                removingSectionNames: targetProfile.authMode == .chatgpt ? ["model_providers.custom"] : []
            )
            let remoteResult: RemoteSwitchResult?
            if remoteSettings.shouldSyncRemote {
                let stripCustomProviderSection = targetProfile.authMode == .chatgpt
                let operation = RemoteSwitchOperation(
                    settings: remoteSettings,
                    restorePointID: restorePoint?.id,
                    authData: targetProfile.runtimeMaterial.authData,
                    targetConfigData: targetConfig,
                    targetProviderID: latestPreview.targetProviderID,
                    terminateRemoteCodexProcesses: terminateRemoteCodexProcesses,
                    stripCustomProviderSection: stripCustomProviderSection
                )
                remoteResult = try await performRemoteSwitch(
                    operation,
                    failureResolutionProvider: remoteFailureResolutionProvider
                )
                remoteRollbackSettings = rollbackSettings(
                    for: remoteResult,
                    codexHomePath: remoteSettings.effectiveCodexHomePath
                )
            } else {
                remoteResult = nil
            }

            try writer.write(targetProfile.runtimeMaterial.authData, to: store.currentAuthURL)
            try writer.write(mergedConfig, to: store.currentConfigURL)

            let rolloutResult = try rolloutSynchronizer.syncProviders(
                in: [store.sessionsRootURL, store.archivedSessionsRootURL],
                targetProvider: latestPreview.targetProviderID,
                writer: writer
            )
            let repairSummary = try await repairClient.rescanAndRepair()
            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)

            return SwitchOperationResult(
                targetProfileID: targetProfile.id,
                restorePoint: restorePoint,
                updatedRolloutCount: rolloutResult.updatedFiles.count,
                repairSummary: repairSummary,
                remoteResult: remoteResult
            )
        } catch {
            if let remoteRollbackSettings,
               let restorePoint {
                try? await remoteSwitchClient.rollback(
                    settings: remoteRollbackSettings,
                    restorePointID: restorePoint.id
                )
            }
            if let restorePoint {
                do {
                    try backupManager.restoreRestorePoint(restorePoint)
                } catch {
                    try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
                    throw SwitchOrchestratorError.automaticRollbackFailed
                }
            }
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    func repairCurrentThreads() async throws -> RepairOperationResult {
        let filesToBackup = deduplicatedStandardizedFileURLs(store.protectedMutationFileURLs())
        let previouslyRunning = try await desktopController.closeIfRunning()
        var restorePoint: RestorePointManifest?

        do {
            let createdRestorePoint = try backupManager.createRestorePoint(
                reason: "repair-local-threads",
                summary: "Repair local thread metadata",
                files: filesToBackup,
                codexWasRunning: previouslyRunning
            )
            restorePoint = createdRestorePoint
            let repairSummary = try await repairClient.rescanAndRepair()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            return RepairOperationResult(
                restorePoint: createdRestorePoint,
                repairSummary: repairSummary
            )
        } catch {
            if let restorePoint {
                do {
                    try backupManager.restoreRestorePoint(restorePoint)
                } catch {
                    try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
                    throw SwitchOrchestratorError.automaticRollbackFailed
                }
            }
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    func repairHistoryMetadata(
        scope: HistoryMetadataRepairScope,
        remoteSettings: RemoteSwitchSettings = RemoteSwitchSettings()
    ) async throws -> HistoryMetadataRepairOperationResult {
        let localResult = scope.includesLocal
            ? try await repairLocalHistoryMetadata()
            : nil
        let remoteResult = scope.includesRemote
            ? try await repairRemoteHistoryMetadata(remoteSettings: remoteSettings)
            : nil
        return HistoryMetadataRepairOperationResult(
            scope: scope,
            localResult: localResult,
            remoteResult: remoteResult
        )
    }

    private func repairLocalHistoryMetadata() async throws -> LocalHistoryMetadataRepairResult {
        let filesToBackup = try historyRepairer.plannedMutationFiles(store: store)
        let previouslyRunning = try await desktopController.closeIfRunning()
        var restorePoint: RestorePointManifest?

        do {
            let createdRestorePoint = try backupManager.createRestorePoint(
                reason: "repair-history-metadata",
                summary: "Repair local Codex history model metadata",
                files: filesToBackup,
                codexWasRunning: previouslyRunning
            )
            restorePoint = createdRestorePoint
            let writer = ProtectedFileMutationContext(restorePoint: createdRestorePoint)
            let summary = try historyRepairer.repair(store: store, writer: writer)
            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            return LocalHistoryMetadataRepairResult(
                restorePoint: createdRestorePoint,
                summary: summary
            )
        } catch {
            if let restorePoint {
                do {
                    try backupManager.restoreRestorePoint(restorePoint)
                } catch {
                    try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
                    throw SwitchOrchestratorError.automaticRollbackFailed
                }
            }
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }

    private func repairRemoteHistoryMetadata(
        remoteSettings: RemoteSwitchSettings
    ) async throws -> RemoteHistoryRepairResult {
        let targets = remoteSettings.trimmedSSHTargets
        guard !targets.isEmpty else {
            throw RemoteSwitchError.missingSSHTarget
        }

        return try await remoteSwitchClient.repairHistoryMetadata(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTargets: targets,
                codexHomePath: remoteSettings.effectiveCodexHomePath
            )
        )
    }

    func syncCurrentRuntimeToRemote(
        remoteSettings: RemoteSwitchSettings,
        remoteFailureResolutionProvider: RemoteSwitchFailureResolutionProvider? = nil
    ) async throws -> RemoteSwitchResult {
        let targets = remoteSettings.trimmedSSHTargets
        guard !targets.isEmpty else {
            throw RemoteSwitchError.missingSSHTarget
        }

        let currentRuntime = try store.currentRuntimeMaterial()
        let configData = try effectiveCurrentConfigData(
            authData: currentRuntime.authData,
            configData: currentRuntime.configData
        )
        let providerID = try resolveCurrentProviderID(
            authData: currentRuntime.authData,
            configData: configData
        )
        let operation = RemoteSwitchOperation(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTargets: targets,
                codexHomePath: remoteSettings.effectiveCodexHomePath
            ),
            restorePointID: remoteOnlyRestorePointID(),
            authData: currentRuntime.authData,
            targetConfigData: configData,
            targetProviderID: providerID
        )

        return try await performRemoteSwitch(
            operation,
            failureResolutionProvider: remoteFailureResolutionProvider
        )
    }

    private func performRemoteSwitch(
        _ operation: RemoteSwitchOperation,
        failureResolutionProvider: RemoteSwitchFailureResolutionProvider?
    ) async throws -> RemoteSwitchResult {
        let originalTargetOrder = Dictionary(
            uniqueKeysWithValues: operation.settings.trimmedSSHTargets.enumerated().map { ($0.element, $0.offset) }
        )
        var accumulatedSuccesses: [RemoteSwitchTargetResult] = []
        var nextOperation = operation

        while true {
            do {
                let result = try await remoteSwitchClient.perform(nextOperation)
                accumulatedSuccesses.append(contentsOf: result.targets)
                return RemoteSwitchResult(
                    targets: sortedUniqueRemoteResults(accumulatedSuccesses, targetOrder: originalTargetOrder)
                )
            } catch let partialFailure as RemoteSwitchPartialFailureError {
                accumulatedSuccesses.append(contentsOf: partialFailure.successes)
                let successes = sortedUniqueRemoteResults(accumulatedSuccesses, targetOrder: originalTargetOrder)
                let failure = RemoteSwitchPartialFailureError(
                    successes: successes,
                    failures: partialFailure.failures
                )

                guard let failureResolutionProvider else {
                    try await rollbackSuccessfulRemoteTargets(
                        successes,
                        codexHomePath: operation.settings.effectiveCodexHomePath,
                        restorePointID: operation.restorePointID
                    )
                    throw failure
                }

                switch await failureResolutionProvider(failure, operation.restorePointID) {
                case .retry:
                    nextOperation = operation.withSettings(
                        RemoteSwitchSettings(
                            enabled: true,
                            sshTargets: failure.failures.map(\.sshTarget),
                            codexHomePath: operation.settings.effectiveCodexHomePath
                        )
                    )
                case .rollback:
                    try await rollbackSuccessfulRemoteTargets(
                        successes,
                        codexHomePath: operation.settings.effectiveCodexHomePath,
                        restorePointID: operation.restorePointID
                    )
                    throw failure
                case .keepSuccessful:
                    return RemoteSwitchResult(targets: successes)
                }
            }
        }
    }

    private func rollbackSuccessfulRemoteTargets(
        _ successes: [RemoteSwitchTargetResult],
        codexHomePath: String,
        restorePointID: String?
    ) async throws {
        guard let restorePointID,
              !successes.isEmpty else {
            return
        }

        try await remoteSwitchClient.rollback(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTargets: successes.map(\.sshTarget),
                codexHomePath: codexHomePath
            ),
            restorePointID: restorePointID
        )
    }

    private func rollbackSettings(
        for result: RemoteSwitchResult?,
        codexHomePath: String
    ) -> RemoteSwitchSettings? {
        guard let targets = result?.targets.map(\.sshTarget),
              !targets.isEmpty else {
            return nil
        }

        return RemoteSwitchSettings(
            enabled: true,
            sshTargets: targets,
            codexHomePath: codexHomePath
        )
    }

    private func sortedUniqueRemoteResults(
        _ results: [RemoteSwitchTargetResult],
        targetOrder: [String: Int]
    ) -> [RemoteSwitchTargetResult] {
        var byTarget: [String: RemoteSwitchTargetResult] = [:]
        for result in results {
            byTarget[result.sshTarget] = result
        }

        return byTarget.values.sorted {
            (targetOrder[$0.sshTarget] ?? Int.max) < (targetOrder[$1.sshTarget] ?? Int.max)
        }
    }

    private func effectiveCurrentConfigData(
        authData: Data,
        configData: Data?
    ) throws -> Data {
        if let configData {
            guard let raw = String(data: configData, encoding: .utf8) else {
                throw RuntimeConfigMergeError.invalidUTF8
            }

            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return configData
            }
        }

        if resolveAuthMode(authData: authData) == .chatgpt {
            return Data("model_provider = \"openai\"\n".utf8)
        }

        throw SwitchOrchestratorError.missingRuntimeConfig(
            AppLocalization.localized(en: "Current local config", zh: "当前本机配置")
        )
    }

    private func resolveCurrentProviderID(
        authData: Data,
        configData: Data?
    ) throws -> String {
        let summary = parseRuntimeConfig(configData)
        if let providerID = summary.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return providerID
        }

        if resolveAuthMode(authData: authData) == .chatgpt {
            return "openai"
        }

        throw SwitchOrchestratorError.missingProviderIdentifier(
            AppLocalization.localized(en: "Current local config", zh: "当前本机配置")
        )
    }

    private func remoteOnlyRestorePointID() -> String {
        "remote-sync-\(UUID().uuidString)"
    }

    private func effectiveTargetConfigData(for targetProfile: ProviderProfile) throws -> Data {
        if let configData = targetProfile.runtimeMaterial.configData,
           let raw = String(data: configData, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summary = parseRuntimeConfig(configData)
            if summary.usesOpenAICompatibilityProvider {
                return synthesizedOpenAICompatibleConfig(from: summary)
            }
            return configData
        }

        if targetProfile.authMode == .chatgpt {
            return Data("model_provider = \"openai\"\n".utf8)
        }

        if let threadProviderID = targetProfile.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !threadProviderID.isEmpty {
            return Data("model_provider = \"\(threadProviderID)\"\n".utf8)
        }

        if let providerID = targetProfile.providerID,
           !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Data("model_provider = \"\(providerID)\"\n".utf8)
        }

        throw SwitchOrchestratorError.missingRuntimeConfig(targetProfile.displayName)
    }
    private func resolveTargetProviderID(
        for targetProfile: ProviderProfile,
        effectiveConfigData: Data?
    ) throws -> String {
        let configSummary = parseRuntimeConfig(effectiveConfigData)
        if let providerID = configSummary.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return providerID
        }

        if let providerID = targetProfile.threadProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty {
            return providerID
        }

        if targetProfile.authMode == .chatgpt {
            return "openai"
        }

        throw SwitchOrchestratorError.missingProviderIdentifier(targetProfile.displayName)
    }
}

@MainActor
final class RollbackManager {
    private let backupManager: BackupManager
    private let desktopController: CodexDesktopControlling
    private let quotaChannelInvalidator: CodexRPCChannelInvalidating

    init(
        backupManager: BackupManager,
        desktopController: CodexDesktopControlling,
        quotaChannelInvalidator: CodexRPCChannelInvalidating
    ) {
        self.backupManager = backupManager
        self.desktopController = desktopController
        self.quotaChannelInvalidator = quotaChannelInvalidator
    }

    func rollbackLatest() async throws -> RestorePointManifest {
        let previouslyRunning = try await desktopController.closeIfRunning()

        do {
            let manifest = try backupManager.restoreLatestRestorePoint()
            await quotaChannelInvalidator.invalidateAllReusableChannels()
            try await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            return manifest
        } catch {
            try? await desktopController.reopenIfNeeded(previouslyRunning: previouslyRunning)
            throw error
        }
    }
}
