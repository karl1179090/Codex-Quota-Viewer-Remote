import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func sshConfigParserReturnsSelectableHostAliases() {
    let hosts = parseSSHConfigHosts(
        """
        # comment
        Host *
          User ignored

        Host codex-box prod-box
          HostName 10.0.0.10

        host staging-box !blocked *.example.com codex-box
          User deploy
        """)

    #expect(hosts == ["codex-box", "prod-box", "staging-box"])
}

@Test
func sshRemoteSwitchClientBuildsSSHInvocationAndPayloadScript() async throws {
    let executor = RemoteProcessExecutorSpy(
        result: ProcessExecutionResult(
            terminationStatus: 0,
            standardOutput: Data("REMOTE_SWITCH_SUMMARY updated_rollouts=3 warnings=1\n".utf8),
            standardError: Data()
        )
    )
    let client = SSHRemoteSwitchClient(
        executor: executor,
        sshURL: URL(fileURLWithPath: "/mock/ssh")
    )

    let result = try await client.perform(
        RemoteSwitchOperation(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTarget: "codex-box",
                codexHomePath: "~/.codex"
            ),
            restorePointID: "restore-1",
            authData: Data(#"{"auth_mode":"chatgpt"}"#.utf8),
            targetConfigData: Data("model_provider = \"openai\"\n".utf8),
            targetProviderID: "openai"
        )
    )

    #expect(result.updatedRolloutCount == 3)
    #expect(result.warningCount == 1)
    #expect(result.terminatedCodexProcessCount == 0)
    #expect(executor.calls.count == 1)
    #expect(executor.calls[0].executableURL.path == "/mock/ssh")
    #expect(executor.calls[0].arguments == ["codex-box", "sh", "-s"])
    let script = try executor.calls[0].standardInput.utf8String()
    #expect(script.contains("CODEX_HOME_INPUT='~/.codex'"))
    #expect(script.contains("RESTORE_ID='restore-1'"))
    #expect(script.contains("AUTH_B64='eyJhdXRoX21vZGUiOiJjaGF0Z3B0In0='"))
    #expect(script.contains("TARGET_CONFIG_B64='bW9kZWxfcHJvdmlkZXIgPSAib3BlbmFpIgo='"))
    #expect(script.contains("PROVIDER_B64='b3BlbmFp'"))
    #expect(script.contains("REMOTE_CODEX_KILL_ENABLED=0"))
    #expect(script.contains("merged_config = merge_runtime_config(current_config, target_config)"))
    #expect(script.contains("remote-switch-backups/$RESTORE_ID"))
    #expect(script.contains("updated_rollouts=${UPDATED_ROLLOUTS:-0}"))
    #expect(script.contains("terminated_codex_processes=${TERMINATED_REMOTE_CODEX:-0}"))
    #expect(script.contains("restore_manifest()"))
    #expect(script.contains("(backup_root / \"manifest.json\").write_text"))
}

@Test
func sshRemoteSwitchClientCanTerminateRemoteCodexProcessesWhenRequested() async throws {
    let executor = RemoteProcessExecutorSpy(
        result: ProcessExecutionResult(
            terminationStatus: 0,
            standardOutput: Data("REMOTE_SWITCH_SUMMARY updated_rollouts=0 warnings=0 terminated_codex_processes=4\n".utf8),
            standardError: Data()
        )
    )
    let client = SSHRemoteSwitchClient(
        executor: executor,
        sshURL: URL(fileURLWithPath: "/mock/ssh")
    )

    let result = try await client.perform(
        RemoteSwitchOperation(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTarget: "codex-box",
                codexHomePath: "~/.codex"
            ),
            restorePointID: "restore-kill",
            authData: Data(#"{"auth_mode":"chatgpt"}"#.utf8),
            targetConfigData: Data("model_provider = \"openai\"\n".utf8),
            targetProviderID: "openai",
            terminateRemoteCodexProcesses: true
        )
    )

    #expect(result.terminatedCodexProcessCount == 4)
    let script = try executor.calls[0].standardInput.utf8String()
    #expect(script.contains("REMOTE_CODEX_KILL_ENABLED=1"))
    #expect(script.contains("[\"ps\", \"-eo\", \"pid=\", \"-o\", \"ppid=\", \"-o\", \"uid=\", \"-o\", \"comm=\", \"-o\", \"args=\"]"))
    #expect(script.contains("command_has_codex_token(process[\"args\"])"))
    #expect(script.contains("parent_comm in {\"node\", \"nodejs\"}"))
    #expect(script.contains("kill $REMOTE_CODEX_PIDS"))
    #expect(script.contains("kill -KILL $REMOTE_CODEX_STILL_RUNNING"))
}

@Test
func sshRemoteSwitchClientSynchronizesMultipleTargets() async throws {
    let executor = ConcurrentRemoteProcessExecutorSpy(
        result: ProcessExecutionResult(
            terminationStatus: 0,
            standardOutput: Data("REMOTE_SWITCH_SUMMARY updated_rollouts=3 warnings=1\n".utf8),
            standardError: Data()
        )
    )
    let client = SSHRemoteSwitchClient(
        executor: executor,
        sshURL: URL(fileURLWithPath: "/mock/ssh")
    )

    let result = try await client.perform(
        RemoteSwitchOperation(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTargets: ["codex-box", "prod-box"],
                codexHomePath: "~/.codex"
            ),
            restorePointID: "restore-1",
            authData: Data(#"{"auth_mode":"chatgpt"}"#.utf8),
            targetConfigData: Data("model_provider = \"openai\"\n".utf8),
            targetProviderID: "openai"
        )
    )

    let calls = await executor.recordedCalls()
    #expect(result.targets.map(\.sshTarget) == ["codex-box", "prod-box"])
    #expect(result.sshTarget == "codex-box, prod-box")
    #expect(result.updatedRolloutCount == 6)
    #expect(result.warningCount == 2)
    #expect(result.terminatedCodexProcessCount == 0)
    #expect(calls.map(\.arguments).sorted { $0[0] < $1[0] } == [
        ["codex-box", "sh", "-s"],
        ["prod-box", "sh", "-s"],
    ])
}

@Test
func sshRemoteSwitchClientMergesTargetConfigWithRemoteCurrentConfig() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RemoteSwitchClientTests-\(UUID().uuidString)", isDirectory: true)
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(
        at: codexHome.appendingPathComponent("sessions", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data(
        """
        remote_personality = "keep"
        model = "old-model"
        model_provider = "legacy"

        [model_providers.legacy]
        name = "Legacy"
        base_url = "https://legacy.example.com/v1"

        [mcp_servers.remote]
        command = "remote-only"
        """.utf8
    )
    .write(to: codexHome.appendingPathComponent("config.toml"), options: .atomic)
    try Data(#"{"auth_mode":"old"}"#.utf8)
        .write(to: codexHome.appendingPathComponent("auth.json"), options: .atomic)
    let rolloutURL = codexHome
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("rollout.jsonl", isDirectory: false)
    try Data(
        """
        {"timestamp":"2026-06-02T00:00:00Z","type":"session_meta","payload":{"id":"r1","model_provider":"legacy"}}
        {"timestamp":"2026-06-02T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
        """.utf8
    )
    .write(to: rolloutURL, options: .atomic)

    let executor = LocalShellRemoteProcessExecutor()
    let client = SSHRemoteSwitchClient(
        executor: executor,
        sshURL: URL(fileURLWithPath: "/mock/ssh")
    )

    let result = try await client.perform(
        RemoteSwitchOperation(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTarget: "remote",
                codexHomePath: codexHome.path
            ),
            restorePointID: "restore-merge",
            authData: Data(#"{"auth_mode":"chatgpt"}"#.utf8),
            targetConfigData: Data(
                """
                model_provider = "openai"
                model = "gpt-5.4"

                [model_providers.openai]
                name = "OpenAI"
                base_url = "https://api.openai.com/v1"
                """.utf8
            ),
            targetProviderID: "openai"
        )
    )

    let config = try Data(contentsOf: codexHome.appendingPathComponent("config.toml")).utf8String()
    #expect(result.updatedRolloutCount == 1)
    #expect(config.contains("remote_personality = \"keep\""))
    #expect(config.contains("model_provider = \"openai\""))
    #expect(config.contains("model = \"gpt-5.4\""))
    #expect(config.contains("[model_providers.openai]"))
    #expect(config.contains("[model_providers.legacy]"))
    #expect(config.contains("[mcp_servers.remote]"))
    #expect(config.contains("model_provider = \"legacy\"") == false)
    #expect(try Data(contentsOf: codexHome.appendingPathComponent("auth.json")).utf8String()
        == #"{"auth_mode":"chatgpt"}"#)
    #expect(try remoteTestSessionMetaProvider(from: rolloutURL) == "openai")
}

@Test
func sshRemoteSwitchClientDirectSwitchWithoutRestorePointSkipsRemoteBackup() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RemoteSwitchClientTests-\(UUID().uuidString)", isDirectory: true)
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(
        at: codexHome.appendingPathComponent("sessions", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("model_provider = \"legacy\"\n".utf8)
        .write(to: codexHome.appendingPathComponent("config.toml"), options: .atomic)
    try Data(#"{"auth_mode":"old"}"#.utf8)
        .write(to: codexHome.appendingPathComponent("auth.json"), options: .atomic)
    let rolloutURL = codexHome
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("rollout.jsonl", isDirectory: false)
    try Data(
        """
        {"timestamp":"2026-06-02T00:00:00Z","type":"session_meta","payload":{"id":"r1","model_provider":"legacy"}}
        {"timestamp":"2026-06-02T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
        """.utf8
    )
    .write(to: rolloutURL, options: .atomic)

    let executor = LocalShellRemoteProcessExecutor()
    let client = SSHRemoteSwitchClient(
        executor: executor,
        sshURL: URL(fileURLWithPath: "/mock/ssh")
    )

    let result = try await client.perform(
        RemoteSwitchOperation(
            settings: RemoteSwitchSettings(
                enabled: true,
                sshTarget: "remote",
                codexHomePath: codexHome.path
            ),
            restorePointID: nil,
            authData: Data(#"{"auth_mode":"chatgpt"}"#.utf8),
            targetConfigData: Data("model_provider = \"openai\"\n".utf8),
            targetProviderID: "openai"
        )
    )

    let backupRoot = codexHome
        .appendingPathComponent(".codex-quota-viewer", isDirectory: true)
        .appendingPathComponent("remote-switch-backups", isDirectory: true)
    let firstCall = try #require(executor.calls.first)
    let script = try firstCall.standardInput.utf8String()
    #expect(result.updatedRolloutCount == 1)
    #expect(script.contains("BACKUP_ENABLED=0"))
    #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)
    #expect(try Data(contentsOf: codexHome.appendingPathComponent("auth.json")).utf8String()
        == #"{"auth_mode":"chatgpt"}"#)
    #expect(try remoteTestSessionMetaProvider(from: rolloutURL) == "openai")
}

@Test
func sshRemoteSwitchClientRollbackUsesSameRestorePoint() async throws {
    let executor = RemoteProcessExecutorSpy(
        result: ProcessExecutionResult(
            terminationStatus: 0,
            standardOutput: Data("REMOTE_SWITCH_ROLLBACK restored=1\n".utf8),
            standardError: Data()
        )
    )
    let client = SSHRemoteSwitchClient(executor: executor)

    try await client.rollback(
        settings: RemoteSwitchSettings(enabled: true, sshTarget: "prod", codexHomePath: "/srv/codex"),
        restorePointID: "restore-2"
    )

    #expect(executor.calls.count == 1)
    #expect(executor.calls[0].arguments == ["prod", "sh", "-s"])
    let script = try executor.calls[0].standardInput.utf8String()
    #expect(script.contains("CODEX_HOME_INPUT='/srv/codex'"))
    #expect(script.contains("RESTORE_ID='restore-2'"))
    #expect(script.contains("REMOTE_SWITCH_ROLLBACK restored=1"))
}

@Test
func sshRemoteSwitchClientThrowsReadableErrorOnSSHFailure() async throws {
    let executor = RemoteProcessExecutorSpy(
        result: ProcessExecutionResult(
            terminationStatus: 255,
            standardOutput: Data(),
            standardError: Data("permission denied".utf8)
        )
    )
    let client = SSHRemoteSwitchClient(executor: executor)

    await #expect(throws: RemoteSwitchError.self) {
        _ = try await client.perform(
            RemoteSwitchOperation(
                settings: RemoteSwitchSettings(enabled: true, sshTarget: "prod"),
                restorePointID: "restore-3",
                authData: Data("auth".utf8),
                targetConfigData: Data("config".utf8),
                targetProviderID: "openai"
            )
        )
    }
}

private final class RemoteProcessExecutorSpy: ProcessExecuting, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let executableURL: URL
        let arguments: [String]
        let standardInput: Data
    }

    private(set) var calls: [Call] = []
    private let result: ProcessExecutionResult

    init(result: ProcessExecutionResult) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) async throws -> ProcessExecutionResult {
        calls.append(
            Call(
                executableURL: executableURL,
                arguments: arguments,
                standardInput: standardInput
            )
        )
        return result
    }
}

private actor ConcurrentRemoteProcessExecutorSpy: ProcessExecuting {
    private var calls: [RemoteProcessExecutorSpy.Call] = []
    private let result: ProcessExecutionResult

    init(result: ProcessExecutionResult) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) async throws -> ProcessExecutionResult {
        calls.append(
            RemoteProcessExecutorSpy.Call(
                executableURL: executableURL,
                arguments: arguments,
                standardInput: standardInput
            )
        )
        return result
    }

    func recordedCalls() -> [RemoteProcessExecutorSpy.Call] {
        calls
    }
}

private final class LocalShellRemoteProcessExecutor: ProcessExecuting, @unchecked Sendable {
    private(set) var calls: [RemoteProcessExecutorSpy.Call] = []

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) async throws -> ProcessExecutionResult {
        calls.append(
            RemoteProcessExecutorSpy.Call(
                executableURL: executableURL,
                arguments: arguments,
                standardInput: standardInput
            )
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(standardInput)
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return ProcessExecutionResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            standardError: errorPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

private func remoteTestSessionMetaProvider(from fileURL: URL) throws -> String {
    guard let firstLine = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n")
        .first else {
        throw NSError(domain: "RemoteSwitchClientTests", code: 1)
    }
    let object = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
    let payload = object?["payload"] as? [String: Any]
    guard let provider = payload?["model_provider"] as? String else {
        throw NSError(domain: "RemoteSwitchClientTests", code: 2)
    }
    return provider
}
