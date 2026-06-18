import Foundation

struct RemoteSwitchOperation: Equatable, Sendable {
    let settings: RemoteSwitchSettings
    let restorePointID: String?
    let authData: Data
    let targetConfigData: Data
    let targetProviderID: String
    let terminateRemoteCodexProcesses: Bool
    let stripCustomProviderSection: Bool

    init(
        settings: RemoteSwitchSettings,
        restorePointID: String?,
        authData: Data,
        targetConfigData: Data,
        targetProviderID: String,
        terminateRemoteCodexProcesses: Bool = false,
        stripCustomProviderSection: Bool = false
    ) {
        self.settings = settings
        self.restorePointID = restorePointID
        self.authData = authData
        self.targetConfigData = targetConfigData
        self.targetProviderID = targetProviderID
        self.terminateRemoteCodexProcesses = terminateRemoteCodexProcesses
        self.stripCustomProviderSection = stripCustomProviderSection
    }

    func withSettings(_ settings: RemoteSwitchSettings) -> RemoteSwitchOperation {
        RemoteSwitchOperation(
            settings: settings,
            restorePointID: restorePointID,
            authData: authData,
            targetConfigData: targetConfigData,
            targetProviderID: targetProviderID,
            terminateRemoteCodexProcesses: terminateRemoteCodexProcesses,
            stripCustomProviderSection: stripCustomProviderSection
        )
    }
}

struct RemoteSwitchTargetResult: Equatable, Sendable {
    let sshTarget: String
    let codexHomePath: String
    let updatedRolloutCount: Int
    let warningCount: Int
    let terminatedCodexProcessCount: Int
}

struct RemoteSwitchResult: Equatable, Sendable {
    let targets: [RemoteSwitchTargetResult]

    init(targets: [RemoteSwitchTargetResult]) {
        self.targets = targets
    }

    init(
        sshTarget: String,
        codexHomePath: String,
        updatedRolloutCount: Int,
        warningCount: Int,
        terminatedCodexProcessCount: Int = 0
    ) {
        targets = [
            RemoteSwitchTargetResult(
                sshTarget: sshTarget,
                codexHomePath: codexHomePath,
                updatedRolloutCount: updatedRolloutCount,
                warningCount: warningCount,
                terminatedCodexProcessCount: terminatedCodexProcessCount
            ),
        ]
    }

    var sshTarget: String {
        targets.map(\.sshTarget).joined(separator: ", ")
    }

    var codexHomePath: String {
        targets.first?.codexHomePath ?? RemoteSwitchSettings.defaultCodexHomePath
    }

    var updatedRolloutCount: Int {
        targets.reduce(0) { $0 + $1.updatedRolloutCount }
    }

    var warningCount: Int {
        targets.reduce(0) { $0 + $1.warningCount }
    }

    var terminatedCodexProcessCount: Int {
        targets.reduce(0) { $0 + $1.terminatedCodexProcessCount }
    }
}

struct RemoteHistoryRepairTargetResult: Equatable, Sendable {
    let sshTarget: String
    let codexHomePath: String
    let summary: HistoryMetadataRepairSummary
}

struct RemoteHistoryRepairResult: Equatable, Sendable {
    let targets: [RemoteHistoryRepairTargetResult]

    var sshTarget: String {
        targets.map(\.sshTarget).joined(separator: ", ")
    }

    var totalSummary: HistoryMetadataRepairSummary {
        targets.reduce(.empty) { $0 + $1.summary }
    }
}

struct RemoteSwitchTargetFailure: Equatable, Sendable {
    let sshTarget: String
    let reason: String
}

struct RemoteSwitchPartialFailureError: LocalizedError, Equatable, Sendable {
    let successes: [RemoteSwitchTargetResult]
    let failures: [RemoteSwitchTargetFailure]

    var errorDescription: String? {
        let details = failures
            .map { "\($0.sshTarget): \($0.reason)" }
            .joined(separator: "; ")
        return AppLocalization.localized(
            en: "Remote sync failed on \(failures.count) host(s): \(details)",
            zh: "\(failures.count) 台远端主机同步失败：\(details)"
        )
    }
}

struct RemoteHistoryRepairPartialFailureError: LocalizedError, Equatable, Sendable {
    let successes: [RemoteHistoryRepairTargetResult]
    let failures: [RemoteSwitchTargetFailure]

    var errorDescription: String? {
        let details = failures
            .map { "\($0.sshTarget): \($0.reason)" }
            .joined(separator: "; ")
        return AppLocalization.localized(
            en: "Remote history repair failed on \(failures.count) host(s): \(details)",
            zh: "\(failures.count) 台远端主机历史修复失败：\(details)"
        )
    }
}

enum RemoteSwitchError: LocalizedError, Sendable {
    case missingSSHTarget
    case sshFailed(String)
    case invalidUTF8Payload
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingSSHTarget:
            return AppLocalization.localized(
                en: "Remote sync is enabled, but the SSH target is empty.",
                zh: "已启用远端同步，但 SSH 目标为空。"
            )
        case .sshFailed(let message):
            return AppLocalization.localized(
                en: "Remote sync failed: \(message)",
                zh: "远端同步失败：\(message)"
            )
        case .invalidUTF8Payload:
            return AppLocalization.localized(
                en: "Remote sync payload is not valid UTF-8.",
                zh: "远端同步内容不是有效 UTF-8。"
            )
        case .invalidResponse(let response):
            return AppLocalization.localized(
                en: "Remote sync returned an invalid response: \(response)",
                zh: "远端同步返回了无效响应：\(response)"
            )
        }
    }
}

protocol RemoteSwitching: Sendable {
    func perform(_ operation: RemoteSwitchOperation) async throws -> RemoteSwitchResult
    func rollback(settings: RemoteSwitchSettings, restorePointID: String) async throws
    func repairHistoryMetadata(settings: RemoteSwitchSettings) async throws -> RemoteHistoryRepairResult
}

struct ProcessExecutionResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

protocol ProcessExecuting: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) async throws -> ProcessExecutionResult
}

struct SystemProcessExecutor: ProcessExecuting {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) async throws -> ProcessExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: ProcessExecutionResult(
                        terminationStatus: process.terminationStatus,
                        standardOutput: outputData,
                        standardError: errorData
                    )
                )
            }

            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(standardInput)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

final class SSHRemoteSwitchClient: RemoteSwitching, Sendable {
    private let executor: ProcessExecuting
    private let sshURL: URL

    init(
        executor: ProcessExecuting = SystemProcessExecutor(),
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) {
        self.executor = executor
        self.sshURL = sshURL
    }

    func perform(_ operation: RemoteSwitchOperation) async throws -> RemoteSwitchResult {
        let targets = operation.settings.trimmedSSHTargets
        guard !targets.isEmpty else {
            throw RemoteSwitchError.missingSSHTarget
        }

        let payload = try remoteSwitchPayload(
            authData: operation.authData,
            targetConfigData: operation.targetConfigData,
            targetProviderID: operation.targetProviderID
        )
        let results = try await performOnTargets(
            targets,
            operation: operation,
            payload: payload
        )
        return RemoteSwitchResult(targets: results)
    }

    func rollback(settings: RemoteSwitchSettings, restorePointID: String) async throws {
        let targets = settings.trimmedSSHTargets
        guard !targets.isEmpty else {
            throw RemoteSwitchError.missingSSHTarget
        }

        let script = remoteRollbackScript(
            codexHomePath: settings.effectiveCodexHomePath,
            restorePointID: restorePointID
        )
        let outcomes = await runRollback(targets: targets, script: script)
        if let failed = outcomes.first(where: { $0.failure != nil }),
           let failure = failed.failure {
            throw RemoteSwitchError.sshFailed("\(failure.sshTarget): \(failure.reason)")
        }
    }

    func repairHistoryMetadata(settings: RemoteSwitchSettings) async throws -> RemoteHistoryRepairResult {
        let targets = settings.trimmedSSHTargets
        guard !targets.isEmpty else {
            throw RemoteSwitchError.missingSSHTarget
        }

        let script = remoteHistoryRepairScript(codexHomePath: settings.effectiveCodexHomePath)
        let outcomes = await runHistoryRepair(
            targets: targets,
            script: script,
            codexHomePath: settings.effectiveCodexHomePath
        )
        let targetOrder = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element, $0.offset) })
        let successes = outcomes
            .compactMap(\.historyRepairResult)
            .sorted {
                (targetOrder[$0.sshTarget] ?? Int.max) < (targetOrder[$1.sshTarget] ?? Int.max)
            }
        let failures = outcomes
            .compactMap(\.failure)
            .sorted {
                (targetOrder[$0.sshTarget] ?? Int.max) < (targetOrder[$1.sshTarget] ?? Int.max)
            }

        guard failures.isEmpty else {
            throw RemoteHistoryRepairPartialFailureError(successes: successes, failures: failures)
        }

        return RemoteHistoryRepairResult(targets: successes)
    }

    private func runSSH(target: String, script: String) async throws -> String {
        let result = try await executor.run(
            executableURL: sshURL,
            arguments: [target, "sh", "-s"],
            standardInput: Data(script.utf8)
        )

        guard result.terminationStatus == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteSwitchError.sshFailed(stderr?.isEmpty == false ? stderr! : (stdout ?? "exit \(result.terminationStatus)"))
        }

        return String(data: result.standardOutput, encoding: .utf8) ?? ""
    }

    private func performOnTargets(
        _ targets: [String],
        operation: RemoteSwitchOperation,
        payload: RemoteSwitchPayload
    ) async throws -> [RemoteSwitchTargetResult] {
        let script = remotePerformScript(
            codexHomePath: operation.settings.effectiveCodexHomePath,
            restorePointID: operation.restorePointID,
            payload: payload,
            terminateRemoteCodexProcesses: operation.terminateRemoteCodexProcesses,
            stripCustomProviderSection: operation.stripCustomProviderSection
        )
        let outcomes = await runPerform(targets: targets, script: script, codexHomePath: operation.settings.effectiveCodexHomePath)
        let targetOrder = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element, $0.offset) })
        let successes = outcomes
            .compactMap(\.result)
            .sorted {
                (targetOrder[$0.sshTarget] ?? Int.max) < (targetOrder[$1.sshTarget] ?? Int.max)
            }
        let failures = outcomes
            .compactMap(\.failure)
            .sorted {
                (targetOrder[$0.sshTarget] ?? Int.max) < (targetOrder[$1.sshTarget] ?? Int.max)
            }

        guard failures.isEmpty else {
            throw RemoteSwitchPartialFailureError(successes: successes, failures: failures)
        }

        return successes
    }

    private func runPerform(
        targets: [String],
        script: String,
        codexHomePath: String
    ) async -> [RemoteSwitchTargetOutcome] {
        await withTaskGroup(of: RemoteSwitchTargetOutcome.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let response = try await self.runSSH(target: target, script: script)
                        let summary = try self.parseRemoteSummary(response)
                        return RemoteSwitchTargetOutcome(
                            result: RemoteSwitchTargetResult(
                                sshTarget: target,
                                codexHomePath: codexHomePath,
                                updatedRolloutCount: summary.updatedRollouts,
                                warningCount: summary.warnings,
                                terminatedCodexProcessCount: summary.terminatedCodexProcesses
                            ),
                            failure: nil
                        )
                    } catch {
                        return RemoteSwitchTargetOutcome(
                            result: nil,
                            failure: RemoteSwitchTargetFailure(
                                sshTarget: target,
                                reason: remoteSwitchFailureReason(for: error)
                            )
                        )
                    }
                }
            }

            var outcomes: [RemoteSwitchTargetOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private func runRollback(
        targets: [String],
        script: String
    ) async -> [RemoteSwitchTargetOutcome] {
        await withTaskGroup(of: RemoteSwitchTargetOutcome.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        _ = try await self.runSSH(target: target, script: script)
                        return RemoteSwitchTargetOutcome(result: nil, failure: nil)
                    } catch {
                        return RemoteSwitchTargetOutcome(
                            result: nil,
                            failure: RemoteSwitchTargetFailure(
                                sshTarget: target,
                                reason: remoteSwitchFailureReason(for: error)
                            )
                        )
                    }
                }
            }

            var outcomes: [RemoteSwitchTargetOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private func runHistoryRepair(
        targets: [String],
        script: String,
        codexHomePath: String
    ) async -> [RemoteSwitchTargetOutcome] {
        await withTaskGroup(of: RemoteSwitchTargetOutcome.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        let response = try await self.runSSH(target: target, script: script)
                        let summary = try self.parseRemoteHistoryRepairSummary(response)
                        return RemoteSwitchTargetOutcome(
                            historyRepairResult: RemoteHistoryRepairTargetResult(
                                sshTarget: target,
                                codexHomePath: codexHomePath,
                                summary: summary
                            ),
                            failure: nil
                        )
                    } catch {
                        return RemoteSwitchTargetOutcome(
                            historyRepairResult: nil,
                            failure: RemoteSwitchTargetFailure(
                                sshTarget: target,
                                reason: remoteSwitchFailureReason(for: error)
                            )
                        )
                    }
                }
            }

            var outcomes: [RemoteSwitchTargetOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    private func parseRemoteSummary(_ response: String) throws -> RemoteScriptSummary {
        guard let summaryLine = response
            .components(separatedBy: .newlines)
            .last(where: { $0.hasPrefix("REMOTE_SWITCH_SUMMARY ") }) else {
            throw RemoteSwitchError.invalidResponse(response)
        }

        let summaryText = String(summaryLine.dropFirst("REMOTE_SWITCH_SUMMARY ".count))
        let parts = summaryText
            .split(separator: " ")
            .compactMap { part -> (String, Int)? in
                let columns = part.split(separator: "=", maxSplits: 1)
                guard columns.count == 2,
                      let value = Int(columns[1]) else {
                    return nil
                }
                return (String(columns[0]), value)
            }
        let values = Dictionary(uniqueKeysWithValues: parts)
        return RemoteScriptSummary(
            updatedRollouts: values["updated_rollouts"] ?? 0,
            warnings: values["warnings"] ?? 0,
            terminatedCodexProcesses: values["terminated_codex_processes"] ?? 0
        )
    }

    private func parseRemoteHistoryRepairSummary(_ response: String) throws -> HistoryMetadataRepairSummary {
        guard let summaryLine = response
            .components(separatedBy: .newlines)
            .last(where: { $0.hasPrefix("REMOTE_HISTORY_REPAIR_SUMMARY ") }) else {
            throw RemoteSwitchError.invalidResponse(response)
        }

        let summaryText = String(summaryLine.dropFirst("REMOTE_HISTORY_REPAIR_SUMMARY ".count))
        guard let data = summaryText.data(using: .utf8) else {
            throw RemoteSwitchError.invalidResponse(response)
        }

        do {
            return try JSONDecoder().decode(HistoryMetadataRepairSummary.self, from: data)
        } catch {
            throw RemoteSwitchError.invalidResponse(response)
        }
    }
}

private struct RemoteScriptSummary: Equatable {
    let updatedRollouts: Int
    let warnings: Int
    let terminatedCodexProcesses: Int
}

private struct RemoteSwitchTargetOutcome: Sendable {
    let result: RemoteSwitchTargetResult?
    let historyRepairResult: RemoteHistoryRepairTargetResult?
    let failure: RemoteSwitchTargetFailure?

    init(
        result: RemoteSwitchTargetResult? = nil,
        historyRepairResult: RemoteHistoryRepairTargetResult? = nil,
        failure: RemoteSwitchTargetFailure?
    ) {
        self.result = result
        self.historyRepairResult = historyRepairResult
        self.failure = failure
    }
}

private func remoteSwitchFailureReason(for error: Error) -> String {
    if let remoteError = error as? RemoteSwitchError {
        switch remoteError {
        case .sshFailed(let message):
            return message
        case .missingSSHTarget, .invalidUTF8Payload, .invalidResponse:
            return remoteError.errorDescription ?? remoteError.localizedDescription
        }
    }

    if let localized = error as? LocalizedError,
       let description = localized.errorDescription {
        return description
    }

    return error.localizedDescription
}

private struct RemoteSwitchPayload: Equatable {
    let authBase64: String
    let targetConfigBase64: String
    let providerBase64: String
}

private func remoteSwitchPayload(
    authData: Data,
    targetConfigData: Data,
    targetProviderID: String
) throws -> RemoteSwitchPayload {
    guard let auth = String(data: authData.base64EncodedData(), encoding: .utf8),
          let config = String(data: targetConfigData.base64EncodedData(), encoding: .utf8),
          let provider = String(data: Data(targetProviderID.utf8).base64EncodedData(), encoding: .utf8) else {
        throw RemoteSwitchError.invalidUTF8Payload
    }

    return RemoteSwitchPayload(authBase64: auth, targetConfigBase64: config, providerBase64: provider)
}

private func shellSingleQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func remoteCodexPIDFinderScript() -> String {
    """
    import os, shlex, subprocess, sys

    uid = os.getuid()
    user = ""
    try:
        user = subprocess.check_output(["id", "-un"], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        pass

    excluded = {os.getpid(), os.getppid()}
    for key in ("REMOTE_KILL_SHELL_PID", "REMOTE_KILL_PARENT_PID"):
        try:
            value = int(os.environ.get(key, "0"))
            if value > 0:
                excluded.add(value)
        except ValueError:
            pass

    try:
        output = subprocess.check_output(
            ["ps", "-eo", "pid=", "-o", "ppid=", "-o", "uid=", "-o", "comm=", "-o", "args="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        sys.exit(0)

    processes = {}
    children = {}

    def basename(value):
        return os.path.basename(value.strip().strip("'").strip('"'))

    def same_user(raw_uid):
        try:
            return int(raw_uid) == uid
        except ValueError:
            return bool(user) and raw_uid == user

    def command_has_codex_token(args):
        try:
            tokens = shlex.split(args)
        except ValueError:
            tokens = args.split()
        return any(basename(token) in {"codex", "codex.js"} for token in tokens)

    for line in output.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) < 4:
            continue
        if len(parts) == 4:
            pid_text, ppid_text, uid_text, comm = parts
            args = comm
        else:
            pid_text, ppid_text, uid_text, comm, args = parts
        try:
            pid = int(pid_text)
            ppid = int(ppid_text)
        except ValueError:
            continue
        if pid in excluded or not same_user(uid_text):
            continue
        processes[pid] = {
            "pid": pid,
            "ppid": ppid,
            "comm": comm,
            "args": args,
        }
        children.setdefault(ppid, []).append(pid)

    direct_matches = {
        pid for pid, process in processes.items()
        if basename(process["comm"]) == "codex" or command_has_codex_token(process["args"])
    }
    matched = set(direct_matches)

    stack = list(direct_matches)
    while stack:
        parent_pid = stack.pop()
        for child_pid in children.get(parent_pid, []):
            if child_pid not in matched:
                matched.add(child_pid)
                stack.append(child_pid)

    for pid in list(matched):
        process = processes.get(pid)
        if not process:
            continue
        parent = processes.get(process["ppid"])
        if not parent:
            continue
        parent_comm = basename(parent["comm"])
        if parent_comm in {"node", "nodejs"} or command_has_codex_token(parent["args"]):
            matched.add(parent["pid"])

    for pid in sorted(matched):
        if pid not in excluded:
            print(pid)
    """
}

private func remotePerformScript(
    codexHomePath: String,
    restorePointID: String?,
    payload: RemoteSwitchPayload,
    terminateRemoteCodexProcesses: Bool,
    stripCustomProviderSection: Bool
) -> String {
    let quotedCodexHome = shellSingleQuote(codexHomePath)
    let quotedRestoreID = shellSingleQuote(restorePointID ?? "direct-no-backup")
    let backupEnabled = restorePointID == nil ? "0" : "1"
    let remoteKillEnabled = terminateRemoteCodexProcesses ? "1" : "0"
    let removeCustomProviderSection = stripCustomProviderSection ? "1" : "0"
    let quotedAuth = shellSingleQuote(payload.authBase64)
    let quotedTargetConfig = shellSingleQuote(payload.targetConfigBase64)
    let quotedProvider = shellSingleQuote(payload.providerBase64)
    let quotedRemoteCodexPIDFinder = shellSingleQuote(remoteCodexPIDFinderScript())
    return """
    set -eu
    CODEX_HOME_INPUT=\(quotedCodexHome)
    RESTORE_ID=\(quotedRestoreID)
    BACKUP_ENABLED=\(backupEnabled)
    REMOTE_CODEX_KILL_ENABLED=\(remoteKillEnabled)
    REMOVE_CUSTOM_PROVIDER_SECTION=\(removeCustomProviderSection)
    AUTH_B64=\(quotedAuth)
    TARGET_CONFIG_B64=\(quotedTargetConfig)
    PROVIDER_B64=\(quotedProvider)
    TMP_DIR="${TMPDIR:-/tmp}/codex-quota-viewer-${RESTORE_ID}-$$"
    mkdir -p "$TMP_DIR"
    AUTH_B64_FILE="$TMP_DIR/auth.b64"
    TARGET_CONFIG_B64_FILE="$TMP_DIR/target-config.b64"
    PROVIDER_B64_FILE="$TMP_DIR/provider.b64"
    printf '%s' "$AUTH_B64" > "$AUTH_B64_FILE"
    printf '%s' "$TARGET_CONFIG_B64" > "$TARGET_CONFIG_B64_FILE"
    printf '%s' "$PROVIDER_B64" > "$PROVIDER_B64_FILE"
    CODEX_HOME=$(python3 - "$CODEX_HOME_INPUT" <<'PY'
    import os, sys
    print(os.path.abspath(os.path.expanduser(sys.argv[1])))
    PY
    )
    BACKUP_ROOT="$CODEX_HOME/.codex-quota-viewer/remote-switch-backups/$RESTORE_ID"
    FILES_DIR="$BACKUP_ROOT/files"
    if [ "$BACKUP_ENABLED" = "1" ]; then
      mkdir -p "$CODEX_HOME" "$FILES_DIR"
    else
      mkdir -p "$CODEX_HOME"
    fi
    TERMINATED_REMOTE_CODEX=0
    if [ "$REMOTE_CODEX_KILL_ENABLED" = "1" ]; then
      REMOTE_KILL_SHELL_PID=$$
      REMOTE_KILL_PARENT_PID=${PPID:-0}
      export REMOTE_KILL_SHELL_PID REMOTE_KILL_PARENT_PID
      REMOTE_CODEX_PIDS=$(python3 -c \(quotedRemoteCodexPIDFinder))
      if [ -n "$REMOTE_CODEX_PIDS" ]; then
        TERMINATED_REMOTE_CODEX=$(printf '%s\n' "$REMOTE_CODEX_PIDS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
        kill $REMOTE_CODEX_PIDS 2>/dev/null || true
        sleep 1
        REMOTE_CODEX_STILL_RUNNING=""
        for pid in $REMOTE_CODEX_PIDS; do
          if kill -0 "$pid" 2>/dev/null; then
            REMOTE_CODEX_STILL_RUNNING="$REMOTE_CODEX_STILL_RUNNING $pid"
          fi
        done
        if [ -n "$REMOTE_CODEX_STILL_RUNNING" ]; then
          kill -KILL $REMOTE_CODEX_STILL_RUNNING 2>/dev/null || true
        fi
      fi
      rm -f "$CODEX_HOME/app-server-control/desktop-ssh-websocket-v0.sock"
    fi
    WARNINGS=0
    UPDATED_ROLLOUTS=0
    export CODEX_HOME BACKUP_ROOT FILES_DIR BACKUP_ENABLED AUTH_B64_FILE TARGET_CONFIG_B64_FILE PROVIDER_B64_FILE REMOVE_CUSTOM_PROVIDER_SECTION
    SUMMARY_FILE="$TMP_DIR/summary.env"
    export SUMMARY_FILE
    python3 <<'PY'
    import base64, json, os, shutil, sys, tempfile
    from pathlib import Path

    codex_home = Path(os.environ["CODEX_HOME"])
    backup_root = Path(os.environ["BACKUP_ROOT"])
    files_dir = Path(os.environ["FILES_DIR"])
    backup_enabled = os.environ.get("BACKUP_ENABLED") == "1"
    remove_custom_provider_section = os.environ.get("REMOVE_CUSTOM_PROVIDER_SECTION") == "1"
    auth = base64.b64decode(Path(os.environ["AUTH_B64_FILE"]).read_text())
    target_config = base64.b64decode(Path(os.environ["TARGET_CONFIG_B64_FILE"]).read_text())
    provider = base64.b64decode(Path(os.environ["PROVIDER_B64_FILE"]).read_text()).decode("utf-8")
    manifest = []
    rollouts_to_update = []
    warnings = 0

    def backup(path: Path):
        global warnings
        if not backup_enabled:
            return
        try:
            rel = str(path.relative_to(codex_home))
        except ValueError:
            rel = path.name
        dest = files_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        record = {"path": str(path), "relative": rel, "exists": path.exists()}
        if path.exists():
            shutil.copy2(path, dest)
        manifest.append(record)

    def atomic_write(path: Path, data: bytes, preserve_metadata=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
            if preserve_metadata and path.exists():
                shutil.copystat(path, tmp_path, follow_symlinks=False)
            os.replace(tmp_path, path)
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            raise

    def toml_assignment_key(line: str):
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#") or trimmed.startswith("[") or "=" not in trimmed:
            return None
        return trimmed.split("=", 1)[0].strip()

    def toml_section_name(line: str):
        trimmed = line.strip()
        if trimmed.startswith("[") and trimmed.endswith("]"):
            return trimmed[1:-1]
        return None

    def parse_toml_document(data: bytes):
        raw = data.decode("utf-8").replace("\\r\\n", "\\n")
        root = []
        sections = []
        current_name = None
        current_header = None
        current_body = []
        for line in raw.split("\\n"):
            section_name = toml_section_name(line)
            if section_name is not None:
                if current_name is not None and current_header is not None:
                    sections.append({
                        "name": current_name,
                        "header": current_header,
                        "body": current_body,
                    })
                current_name = section_name
                current_header = line
                current_body = []
                continue

            if current_name is None:
                root.append(line)
            else:
                current_body.append(line)

        if current_name is not None and current_header is not None:
            sections.append({
                "name": current_name,
                "header": current_header,
                "body": current_body,
            })
        return root, sections

    def trim_leading_blank(lines):
        index = 0
        while index < len(lines) and not lines[index].strip():
            index += 1
        return lines[index:]

    def trim_trailing_blank(lines):
        index = len(lines)
        while index > 0 and not lines[index - 1].strip():
            index -= 1
        return lines[:index]

    def trim_blank(lines):
        return trim_trailing_blank(trim_leading_blank(lines))

    def append_lines(output, lines):
        trimmed = trim_blank(lines)
        if not trimmed:
            return
        if output and output[-1] != "":
            output.append("")
        output.extend(trimmed)

    def append_section(output, section):
        if output and output[-1] != "":
            output.append("")
        output.append(section["header"])
        output.extend(trim_trailing_blank(section["body"]))

    def merge_runtime_config(current_data: bytes, target_data: bytes):
        current_root, current_sections = parse_toml_document(current_data)
        target_root, target_sections = parse_toml_document(target_data)
        target_root_keys = {
            key for key in (toml_assignment_key(line) for line in target_root) if key is not None
        }
        target_section_names = {section["name"] for section in target_sections}
        filtered_current_root = [
            line for line in current_root
            if (toml_assignment_key(line) is None
                or (toml_assignment_key(line) != "model_provider"
                    and toml_assignment_key(line) not in target_root_keys))
        ]
        filtered_current_sections = [
            section for section in current_sections
            if section["name"] not in target_section_names
            and (not remove_custom_provider_section or section["name"] != "model_providers.custom")
        ]

        output = []
        append_lines(output, filtered_current_root)
        append_lines(output, target_root)
        for section in target_sections:
            append_section(output, section)
        for section in filtered_current_sections:
            append_section(output, section)

        joined = "\\n".join(trim_blank(output))
        return (joined + "\\n").encode("utf-8") if joined else b""

    def restore_manifest():
        if not backup_enabled:
            return
        for record in reversed(manifest):
            path = Path(record["path"])
            if record.get("exists"):
                source = files_dir / record["relative"]
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, path)
            elif path.exists():
                path.unlink()

    auth_path = codex_home / "auth.json"
    config_path = codex_home / "config.toml"
    backup(auth_path)
    backup(config_path)

    rollout_candidates = []
    for root_name in ("sessions", "archived_sessions"):
        root = codex_home / root_name
        if root.exists():
            rollout_candidates.extend(sorted(root.rglob("*.jsonl")))

    for path in rollout_candidates:
        try:
            with path.open("rb") as handle:
                first_line = handle.readline()
            if not first_line.strip():
                continue
            first = first_line.rstrip(b"\\r\\n")
            obj = json.loads(first.decode("utf-8"))
            if obj.get("type") != "session_meta":
                continue
            payload = obj.get("payload")
            if not isinstance(payload, dict):
                continue
            if payload.get("model_provider") == provider:
                continue
            backup(path)
            rollouts_to_update.append((path, first_line, obj))
        except Exception as error:
            warnings += 1
            print(f"warning: skipped {path}: {error}", file=sys.stderr)

    if backup_enabled:
        (backup_root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")

    try:
        current_config = config_path.read_bytes() if config_path.exists() else b""
        merged_config = merge_runtime_config(current_config, target_config)
        updated_rollouts = 0
        for path, first_line, obj in rollouts_to_update:
            payload = obj["payload"]
            payload["model_provider"] = provider
            obj["payload"] = payload
            rest = path.read_bytes().splitlines(keepends=True)[1:]
            newline = b"\\n" if first_line.endswith(b"\\n") else b""
            next_first = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8") + newline
            atomic_write(path, next_first + b"".join(rest), preserve_metadata=True)
            updated_rollouts += 1

        atomic_write(auth_path, auth)
        atomic_write(config_path, merged_config)
        Path(os.environ["SUMMARY_FILE"]).write_text(
            f"UPDATED_ROLLOUTS={updated_rollouts}\\nWARNINGS={warnings}\\n",
            encoding="utf-8",
        )
    except Exception:
        restore_manifest()
        raise
    PY
    . "$SUMMARY_FILE"
    if [ "${CODEX_QUOTA_VIEWER_SKIP_APP_SERVER_PKILL:-0}" != "1" ]; then
      pkill -f 'codex.*app-server' 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
    echo "REMOTE_SWITCH_SUMMARY updated_rollouts=${UPDATED_ROLLOUTS:-0} warnings=${WARNINGS:-0} terminated_codex_processes=${TERMINATED_REMOTE_CODEX:-0}"
    """
}

private func remoteHistoryRepairScript(codexHomePath: String) -> String {
    let quotedCodexHome = shellSingleQuote(codexHomePath)
    return """
    set -eu
    CODEX_HOME_INPUT=\(quotedCodexHome)
    CODEX_HOME=$(python3 - "$CODEX_HOME_INPUT" <<'PY'
    import os, sys
    print(os.path.abspath(os.path.expanduser(sys.argv[1])))
    PY
    )
    export CODEX_HOME
    python3 <<'PY'
    import datetime, json, os, shutil, sqlite3, tarfile, tempfile, time
    from pathlib import Path

    DEFAULT_PROVIDER = "openai"
    DEFAULT_MODEL = "gpt-5"
    UTC = datetime.timezone.utc
    home = Path(os.environ["CODEX_HOME"])
    if not home.exists():
        raise SystemExit(f"Codex home does not exist: {home}")

    config_path = home / "config.toml"
    state_db = home / "state_5.sqlite"
    session_index = home / "session_index.jsonl"
    backup_dir = home / "history-sync-backups"
    sessions_roots = [home / "sessions", home / "archived_sessions"]
    stats = {
        "dbThreadsSeen": 0,
        "dbThreadsUpdated": 0,
        "rolloutFilesSeen": 0,
        "rolloutFilesUpdated": 0,
        "indexRowsSeen": 0,
        "indexRowsUpdated": 0,
        "malformedJSONLines": 0,
        "backupPath": None,
    }

    def strip_comment(value):
        result = []
        in_quotes = False
        escaping = False
        for char in value:
            if char == "#" and not in_quotes:
                break
            result.append(char)
            if escaping:
                escaping = False
                continue
            if char == "\\\\":
                escaping = True
                continue
            if char == '"':
                in_quotes = not in_quotes
        return "".join(result).strip()

    def normalized_value(raw):
        value = strip_comment(raw).strip()
        if len(value) >= 2 and value[0] in ("'", '"') and value[-1] == value[0]:
            return value[1:-1]
        return value

    def load_settings():
        if not config_path.exists():
            return DEFAULT_PROVIDER, DEFAULT_MODEL
        data = {}
        section = None
        for raw_line in config_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                data.setdefault(section, {})
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            target = data if section is None else data.setdefault(section, {})
            target[key.strip()] = normalized_value(value)
        defaults = data.get("defaults") if isinstance(data.get("defaults"), dict) else {}
        provider = (
            data.get("model_provider")
            or data.get("modelProvider")
            or data.get("provider")
            or defaults.get("model_provider")
            or defaults.get("provider")
            or DEFAULT_PROVIDER
        )
        model = data.get("model") or defaults.get("model") or DEFAULT_MODEL
        provider = str(provider).strip() or DEFAULT_PROVIDER
        model = str(model).strip() or DEFAULT_MODEL
        return provider, model

    def rollout_files():
        files = []
        for root in sessions_roots:
            if root.exists():
                files.extend(sorted(root.rglob("rollout-*.jsonl")))
        return sorted(files)

    def backup_candidates():
        for path in (config_path, state_db, session_index):
            yield path
        for path in rollout_files():
            yield path

    def create_backup():
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_path = backup_dir / f"codex-history-{time.strftime('%Y%m%d-%H%M%S')}.tar.gz"
        with tarfile.open(backup_path, "w:gz") as archive:
            for path in backup_candidates():
                if path.exists():
                    archive.add(path, arcname=path.relative_to(home).as_posix())
        stats["backupPath"] = str(backup_path)

    def table_columns(connection, table):
        return {row[1] for row in connection.execute(f"PRAGMA table_info({table})").fetchall()}

    def sync_state_database(provider, model):
        if not state_db.exists():
            return
        connection = sqlite3.connect(state_db, timeout=30.0)
        try:
            connection.execute("PRAGMA busy_timeout = 30000")
            columns = table_columns(connection, "threads")
            if not {"id", "model_provider", "model"}.issubset(columns):
                return
            stats["dbThreadsSeen"] = connection.execute("SELECT COUNT(*) FROM threads").fetchone()[0]
            stats["dbThreadsUpdated"] = connection.execute(
                "SELECT COUNT(*) FROM threads WHERE model_provider IS NOT ? OR model IS NOT ?",
                (provider, model),
            ).fetchone()[0]
            if stats["dbThreadsUpdated"]:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute(
                    "UPDATE threads SET model_provider = ?, model = ? WHERE model_provider IS NOT ? OR model IS NOT ?",
                    (provider, model, provider, model),
                )
                connection.commit()
        finally:
            connection.close()

    def apply_model_fields(record, provider, model, add_missing):
        changed = False
        provider_keys = ("model_provider", "modelProvider", "provider")
        model_keys = ("model", "model_name", "modelName")
        for key in provider_keys:
            if key in record and record.get(key) != provider:
                record[key] = provider
                changed = True
        for key in model_keys:
            if key in record and record.get(key) != model:
                record[key] = model
                changed = True
        if add_missing and not any(key in record for key in provider_keys):
            record["model_provider"] = provider
            changed = True
        if add_missing and not any(key in record for key in model_keys):
            record["model"] = model
            changed = True
        return changed

    def atomic_write_text(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        temp_path = Path(temp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\\n") as handle:
                handle.write(content)
            if path.exists():
                shutil.copystat(path, temp_path, follow_symlinks=False)
            else:
                temp_path.chmod(0o644)
            temp_path.replace(path)
        except BaseException:
            temp_path.unlink(missing_ok=True)
            raise

    def sync_rollout_files(provider, model):
        for path in rollout_files():
            stats["rolloutFilesSeen"] += 1
            lines = path.read_text(encoding="utf-8").splitlines(True)
            if not lines:
                continue
            try:
                first = json.loads(lines[0])
            except json.JSONDecodeError:
                continue
            if not isinstance(first, dict) or first.get("type") != "session_meta":
                continue
            payload = first.get("payload")
            target = payload if isinstance(payload, dict) else first
            if not apply_model_fields(target, provider, model, True):
                continue
            if isinstance(payload, dict):
                first["payload"] = target
            lines[0] = json.dumps(first, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\\n"
            atomic_write_text(path, "".join(lines))
            stats["rolloutFilesUpdated"] += 1

    def iso_utc(value):
        timestamp = int(value)
        if timestamp > 10000000000:
            timestamp //= 1000
        return datetime.datetime.fromtimestamp(timestamp, tz=UTC).isoformat().replace("+00:00", "Z")

    def parse_index_timestamp(value):
        if not value:
            return datetime.datetime.fromtimestamp(0, tz=UTC)
        try:
            parsed = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return datetime.datetime.fromtimestamp(0, tz=UTC)
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC)

    def row_value(row, key):
        return row[key] if key in row.keys() else None

    def apply_thread_metadata(entry, row):
        for key in ("cwd", "git_branch", "git_sha", "git_origin_url", "rollout_path"):
            value = row_value(row, key)
            if value:
                entry[key] = str(value)
        git = {
            "branch": entry.get("git_branch"),
            "commit_hash": entry.get("git_sha"),
            "repository_url": entry.get("git_origin_url"),
        }
        git = {key: str(value) for key, value in git.items() if value}
        if git:
            existing = entry.get("git") if isinstance(entry.get("git"), dict) else {}
            existing.update(git)
            entry["git"] = existing

    def read_index_entries_from_database(existing_entries):
        if not state_db.exists():
            return None
        connection = sqlite3.connect(state_db, timeout=30.0)
        try:
            connection.row_factory = sqlite3.Row
            columns = table_columns(connection, "threads")
            if "id" not in columns:
                return None
            selected = ["id"]
            for column in ("title", "updated_at", "cwd", "git_branch", "git_sha", "git_origin_url", "rollout_path"):
                if column in columns:
                    selected.append(column)
            where_sql = "WHERE archived = 0" if "archived" in columns else ""
            rows = connection.execute(f"SELECT {', '.join(selected)} FROM threads {where_sql} ORDER BY id ASC").fetchall()
        finally:
            connection.close()
        entries = []
        for row in rows:
            thread_id = str(row["id"])
            entry = dict(existing_entries.get(thread_id) or {})
            title = str(row["title"]) if "title" in row.keys() and row["title"] else thread_id
            updated_at = iso_utc(row["updated_at"]) if "updated_at" in row.keys() and row["updated_at"] else str(entry.get("updated_at") or "")
            entry["id"] = thread_id
            entry["thread_name"] = str(entry.get("thread_name") or title)
            entry["updated_at"] = updated_at
            apply_thread_metadata(entry, row)
            entries.append(entry)
        return entries

    def sync_session_index(provider, model):
        if not session_index.exists() and not state_db.exists():
            return
        existing_lines = session_index.read_text(encoding="utf-8").splitlines() if session_index.exists() else []
        existing_entries = {}
        existing_order = []
        for line in existing_lines:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                stats["malformedJSONLines"] += 1
                continue
            if not isinstance(record, dict):
                continue
            thread_id = str(record.get("id") or "").strip()
            if not thread_id:
                continue
            stats["indexRowsSeen"] += 1
            existing_entries[thread_id] = record
            existing_order.append(thread_id)
        db_entries = read_index_entries_from_database(existing_entries)
        if db_entries is None:
            output = []
            for thread_id in existing_order:
                record = dict(existing_entries[thread_id])
                apply_model_fields(record, provider, model, False)
                output.append(record)
        else:
            db_ids = {str(entry["id"]) for entry in db_entries}
            index_only = [existing_entries[thread_id] for thread_id in existing_order if thread_id not in db_ids]
            output = db_entries + index_only
            for entry in output:
                apply_model_fields(entry, provider, model, False)
            output.sort(key=lambda item: (parse_index_timestamp(str(item.get("updated_at") or "")), str(item.get("id") or "")))
        current_text = "\\n".join(existing_lines)
        desired = "\\n".join(json.dumps(entry, ensure_ascii=False, separators=(",", ":"), sort_keys=True) for entry in output)
        if desired:
            desired += "\\n"
        if current_text and not current_text.endswith("\\n"):
            current_text += "\\n"
        if desired != current_text:
            stats["indexRowsUpdated"] = len(output)
            atomic_write_text(session_index, desired)

    provider, model = load_settings()
    create_backup()
    sync_state_database(provider, model)
    sync_rollout_files(provider, model)
    sync_session_index(provider, model)
    print("REMOTE_HISTORY_REPAIR_SUMMARY " + json.dumps(stats, separators=(",", ":")))
    PY
    if [ "${CODEX_QUOTA_VIEWER_SKIP_APP_SERVER_PKILL:-0}" != "1" ]; then
      pkill -f 'codex.*app-server' 2>/dev/null || true
    fi
    """
}

private func remoteRollbackScript(
    codexHomePath: String,
    restorePointID: String
) -> String {
    let quotedCodexHome = shellSingleQuote(codexHomePath)
    let quotedRestoreID = shellSingleQuote(restorePointID)
    return """
    set -eu
    CODEX_HOME_INPUT=\(quotedCodexHome)
    RESTORE_ID=\(quotedRestoreID)
    CODEX_HOME=$(python3 - "$CODEX_HOME_INPUT" <<'PY'
    import os, sys
    print(os.path.abspath(os.path.expanduser(sys.argv[1])))
    PY
    )
    BACKUP_ROOT="$CODEX_HOME/.codex-quota-viewer/remote-switch-backups/$RESTORE_ID"
    export CODEX_HOME BACKUP_ROOT
    python3 <<'PY'
    import json, os, shutil
    from pathlib import Path

    backup_root = Path(os.environ["BACKUP_ROOT"])
    manifest_path = backup_root / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"remote restore manifest missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for record in reversed(manifest):
        path = Path(record["path"])
        if record.get("exists"):
            source = backup_root / "files" / record["relative"]
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, path)
        elif path.exists():
            path.unlink()
    PY
    echo "REMOTE_SWITCH_ROLLBACK restored=1"
    """
}
