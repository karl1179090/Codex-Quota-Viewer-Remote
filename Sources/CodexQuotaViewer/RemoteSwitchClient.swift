import Foundation

struct RemoteSwitchOperation: Equatable, Sendable {
    let settings: RemoteSwitchSettings
    let restorePointID: String?
    let authData: Data
    let targetConfigData: Data
    let targetProviderID: String
    let terminateRemoteCodexProcesses: Bool

    init(
        settings: RemoteSwitchSettings,
        restorePointID: String?,
        authData: Data,
        targetConfigData: Data,
        targetProviderID: String,
        terminateRemoteCodexProcesses: Bool = false
    ) {
        self.settings = settings
        self.restorePointID = restorePointID
        self.authData = authData
        self.targetConfigData = targetConfigData
        self.targetProviderID = targetProviderID
        self.terminateRemoteCodexProcesses = terminateRemoteCodexProcesses
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
        if let failed = outcomes.first(where: { $0.error != nil }),
           let error = failed.error {
            throw error
        }
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
            terminateRemoteCodexProcesses: operation.terminateRemoteCodexProcesses
        )
        let outcomes = await runPerform(targets: targets, script: script, codexHomePath: operation.settings.effectiveCodexHomePath)
        let failed = outcomes.first { $0.error != nil }
        let successes = outcomes.compactMap(\.result)

        guard failed == nil else {
            if let restorePointID = operation.restorePointID, !successes.isEmpty {
                let rollbackSettings = RemoteSwitchSettings(
                    enabled: true,
                    sshTargets: successes.map(\.sshTarget),
                    codexHomePath: operation.settings.effectiveCodexHomePath
                )
                try? await rollback(settings: rollbackSettings, restorePointID: restorePointID)
            }

            if let error = failed?.error {
                throw error
            }
            throw RemoteSwitchError.sshFailed("unknown remote sync failure")
        }

        let targetOrder = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element, $0.offset) })
        return successes.sorted {
            (targetOrder[$0.sshTarget] ?? Int.max) < (targetOrder[$1.sshTarget] ?? Int.max)
        }
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
                            error: nil
                        )
                    } catch {
                        return RemoteSwitchTargetOutcome(
                            result: nil,
                            error: RemoteSwitchError.sshFailed("\(target): \(error.localizedDescription)")
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
                        return RemoteSwitchTargetOutcome(result: nil, error: nil)
                    } catch {
                        return RemoteSwitchTargetOutcome(
                            result: nil,
                            error: RemoteSwitchError.sshFailed("\(target): \(error.localizedDescription)")
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
}

private struct RemoteScriptSummary: Equatable {
    let updatedRollouts: Int
    let warnings: Int
    let terminatedCodexProcesses: Int
}

private struct RemoteSwitchTargetOutcome: Sendable {
    let result: RemoteSwitchTargetResult?
    let error: RemoteSwitchError?
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
    terminateRemoteCodexProcesses: Bool
) -> String {
    let quotedCodexHome = shellSingleQuote(codexHomePath)
    let quotedRestoreID = shellSingleQuote(restorePointID ?? "direct-no-backup")
    let backupEnabled = restorePointID == nil ? "0" : "1"
    let remoteKillEnabled = terminateRemoteCodexProcesses ? "1" : "0"
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
    fi
    WARNINGS=0
    UPDATED_ROLLOUTS=0
    export CODEX_HOME BACKUP_ROOT FILES_DIR BACKUP_ENABLED AUTH_B64_FILE TARGET_CONFIG_B64_FILE PROVIDER_B64_FILE
    SUMMARY_FILE="$TMP_DIR/summary.env"
    export SUMMARY_FILE
    python3 <<'PY'
    import base64, json, os, shutil, sys, tempfile
    from pathlib import Path

    codex_home = Path(os.environ["CODEX_HOME"])
    backup_root = Path(os.environ["BACKUP_ROOT"])
    files_dir = Path(os.environ["FILES_DIR"])
    backup_enabled = os.environ.get("BACKUP_ENABLED") == "1"
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

    def atomic_write(path: Path, data: bytes):
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp_name, path)

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
            atomic_write(path, next_first + b"".join(rest))
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
