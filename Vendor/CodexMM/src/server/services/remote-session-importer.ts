import { spawn, type ChildProcess } from "node:child_process";
import { copyFile, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { AppError } from "../lib/errors";
import { ensureInsidePath, shellQuote } from "../lib/paths";
import { collectSessions } from "./session-manager-helpers";
import type { ParsedSessionCatalog } from "./jsonl-session-parser";

export type RemoteSessionPullRequest = {
  sshTarget: string;
  codexHomePath: string;
  destinationRoot: string;
};

export type RemoteSessionPullResult = {
  copiedFileCount: number;
  copiedSessionCount: number;
};

export type RemoteSessionPuller = (
  request: RemoteSessionPullRequest,
) => Promise<RemoteSessionPullResult>;

export type RemoteSessionPreviewEntry = {
  relativePath: string;
  parsed: ParsedSessionCatalog;
};

export type RemoteSessionPreviewRequest = {
  sshTarget: string;
  codexHomePath: string;
};

export type RemoteSessionPreviewer = (
  request: RemoteSessionPreviewRequest,
) => Promise<RemoteSessionPreviewEntry[]>;

export type RemoteSessionFileRequest = {
  sshTarget: string;
  codexHomePath: string;
  relativePath: string;
};

export type RemoteSessionFileReader = (
  request: RemoteSessionFileRequest,
) => Promise<Buffer>;

export type RemoteSessionFileWriter = (
  request: RemoteSessionFileRequest & { content: Buffer },
) => Promise<void>;

export async function pullRemoteSessionFiles(
  request: RemoteSessionPullRequest,
): Promise<RemoteSessionPullResult> {
  await mkdir(request.destinationRoot, { recursive: true });
  const tempRoot = await mkdtemp(path.join(tmpdir(), "codex-remote-sessions-"));

  try {
    await extractRemoteSessionsArchive({
      sshTarget: request.sshTarget,
      codexHomePath: request.codexHomePath,
      destinationRoot: tempRoot,
    });

    const entries = await collectSessions(tempRoot);
    let copiedFileCount = 0;

    for (const entry of entries) {
      const relativePath = path.relative(tempRoot, entry.filePath);
      if (
        relativePath.length === 0 ||
        relativePath.startsWith("..") ||
        path.isAbsolute(relativePath)
      ) {
        continue;
      }

      const targetPath = ensureInsidePath(
        request.destinationRoot,
        path.join(request.destinationRoot, relativePath),
      );
      await mkdir(path.dirname(targetPath), { recursive: true });
      await copyFile(entry.filePath, targetPath);
      copiedFileCount += 1;
    }

    return {
      copiedFileCount,
      copiedSessionCount: entries.length,
    };
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
}

export async function previewRemoteSessionFiles(
  request: RemoteSessionPreviewRequest,
): Promise<RemoteSessionPreviewEntry[]> {
  const tempRoot = await mkdtemp(path.join(tmpdir(), "codex-remote-preview-"));

  try {
    await extractRemoteSessionsArchive({
      sshTarget: request.sshTarget,
      codexHomePath: request.codexHomePath,
      destinationRoot: tempRoot,
    });

    const entries = await collectSessions(tempRoot);
    return entries.flatMap((entry) => {
      const relativePath = normalizeRemoteRelativePath(path.relative(tempRoot, entry.filePath));

      if (!relativePath) {
        return [];
      }

      return [
        {
          relativePath,
          parsed: entry.parsed,
        },
      ];
    });
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
}

export async function readRemoteSessionFile(
  request: RemoteSessionFileRequest,
): Promise<Buffer> {
  const relativePath = requireRemoteRelativePath(request.relativePath);
  const remoteCommand = buildRemoteReadFileCommand(request.codexHomePath, relativePath);
  const result = await runSSHCommand({
    sshTarget: request.sshTarget,
    remoteCommand,
  });

  return result.stdout;
}

export async function writeRemoteSessionFile(
  request: RemoteSessionFileRequest & { content: Buffer },
) {
  const relativePath = requireRemoteRelativePath(request.relativePath);
  const remoteCommand = buildRemoteWriteFileCommand(request.codexHomePath, relativePath);
  await runSSHCommand({
    sshTarget: request.sshTarget,
    remoteCommand,
    standardInput: request.content,
  });
}

async function extractRemoteSessionsArchive(options: {
  sshTarget: string;
  codexHomePath: string;
  destinationRoot: string;
}) {
  const remoteCommand = buildRemoteArchiveCommand(options.codexHomePath);
  const ssh = spawnSSH(options.sshTarget, remoteCommand);
  const tar = spawn(
    "/usr/bin/tar",
    ["-xzf", "-", "-C", options.destinationRoot],
    { stdio: ["pipe", "ignore", "pipe"] },
  );

  tar.stdin.on("error", () => {
    // Broken pipes are reported through the child exit status below.
  });
  if (!ssh.stdout) {
    throw new AppError(
      502,
      "remote_ssh_failed",
      "ssh stdout is not available.",
      { host: options.sshTarget },
    );
  }
  ssh.stdout.pipe(tar.stdin);

  const [sshResult, tarResult] = await Promise.all([
    waitForChild(ssh),
    waitForChild(tar),
  ]);

  if (sshResult.exitCode !== 0) {
    throw new AppError(
      502,
      "remote_ssh_failed",
      sshResult.stderr || `ssh exited with ${sshResult.exitCode}`,
      { host: options.sshTarget },
    );
  }

  if (tarResult.exitCode !== 0) {
    throw new AppError(
      502,
      "remote_session_tar_failed",
      tarResult.stderr || `tar exited with ${tarResult.exitCode}`,
      { host: options.sshTarget },
    );
  }
}

export function buildRemoteArchiveCommand(codexHomePath: string) {
  const requestedHome = codexHomePath.trim() || "~/.codex";

  return `
CODEX_HOME_INPUT=${shellQuote(requestedHome)}
case "$CODEX_HOME_INPUT" in
  "~") CODEX_HOME="$HOME" ;;
  "~/"*) CODEX_HOME="$HOME/\${CODEX_HOME_INPUT#\\~/}" ;;
  *) CODEX_HOME="$CODEX_HOME_INPUT" ;;
esac
SESSIONS_DIR="$CODEX_HOME/sessions"
if [ ! -d "$SESSIONS_DIR" ]; then
  EMPTY_DIR=$(mktemp -d "\${TMPDIR:-/tmp}/codex-empty-sessions.XXXXXX") || exit 1
  tar -czf - -C "$EMPTY_DIR" .
  rm -rf "$EMPTY_DIR"
  exit 0
fi
tar -czf - -C "$SESSIONS_DIR" .
`.trim();
}

function buildRemoteReadFileCommand(codexHomePath: string, relativePath: string) {
  return `
${remoteCodexHomePrelude(codexHomePath)}
RELATIVE_PATH=${shellQuote(relativePath)}
SESSION_FILE="$CODEX_HOME/sessions/$RELATIVE_PATH"
if [ ! -f "$SESSION_FILE" ]; then
  echo "remote session file missing: $RELATIVE_PATH" >&2
  exit 2
fi
cat "$SESSION_FILE"
`.trim();
}

function buildRemoteWriteFileCommand(codexHomePath: string, relativePath: string) {
  return `
${remoteCodexHomePrelude(codexHomePath)}
RELATIVE_PATH=${shellQuote(relativePath)}
SESSION_FILE="$CODEX_HOME/sessions/$RELATIVE_PATH"
SESSION_DIR=$(dirname "$SESSION_FILE") || exit 1
mkdir -p "$SESSION_DIR" || exit 1
cat > "$SESSION_FILE"
`.trim();
}

function remoteCodexHomePrelude(codexHomePath: string) {
  const requestedHome = codexHomePath.trim() || "~/.codex";

  return `
CODEX_HOME_INPUT=${shellQuote(requestedHome)}
case "$CODEX_HOME_INPUT" in
  "~") CODEX_HOME="$HOME" ;;
  "~/"*) CODEX_HOME="$HOME/\${CODEX_HOME_INPUT#\\~/}" ;;
  *) CODEX_HOME="$CODEX_HOME_INPUT" ;;
esac
`.trim();
}

function normalizeRemoteRelativePath(relativePath: string) {
  const normalized = relativePath.split(path.sep).join("/");

  if (
    normalized.length === 0 ||
    normalized.startsWith("../") ||
    normalized.includes("/../") ||
    normalized.endsWith("/..") ||
    normalized.startsWith("/") ||
    !normalized.endsWith(".jsonl")
  ) {
    return null;
  }

  return normalized;
}

function requireRemoteRelativePath(relativePath: string) {
  const normalized = normalizeRemoteRelativePath(relativePath);

  if (!normalized) {
    throw new AppError(
      400,
      "path_outside_managed_root",
      `Path is outside managed root: ${relativePath}`,
      {
        candidatePath: relativePath,
        resolvedCandidatePath: relativePath,
      },
    );
  }

  return normalized;
}

async function runSSHCommand(options: {
  sshTarget: string;
  remoteCommand: string;
  standardInput?: Buffer;
}) {
  const ssh = spawnSSH(options.sshTarget, options.remoteCommand, Boolean(options.standardInput));
  const stdout: Buffer[] = [];

  ssh.stdout?.on("data", (chunk: Buffer) => {
    stdout.push(chunk);
  });

  if (options.standardInput) {
    ssh.stdin?.end(options.standardInput);
  }

  const result = await waitForChild(ssh);
  if (result.exitCode !== 0) {
    throw new AppError(
      502,
      "remote_ssh_failed",
      result.stderr || `ssh exited with ${result.exitCode}`,
      { host: options.sshTarget },
    );
  }

  return {
    stdout: Buffer.concat(stdout),
  };
}

function spawnSSH(sshTarget: string, remoteCommand: string, withInput = false) {
  return spawn(
    "/usr/bin/ssh",
    buildSSHCommandArgs(sshTarget, remoteCommand),
    { stdio: [withInput ? "pipe" : "ignore", "pipe", "pipe"] },
  );
}

export function buildSSHCommandArgs(sshTarget: string, remoteCommand: string) {
  return [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    sshTarget,
    "sh",
    "-c",
    shellQuote(remoteCommand),
  ];
}

function waitForChild(child: ChildProcess) {
  return new Promise<{ exitCode: number; stderr: string }>((resolve, reject) => {
    const stderr: Buffer[] = [];

    child.stderr?.on("data", (chunk: Buffer) => {
      stderr.push(chunk);
    });
    child.once("error", reject);
    child.once("close", (code, signal) => {
      resolve({
        exitCode: code ?? (signal ? 1 : 0),
        stderr: Buffer.concat(stderr).toString("utf8").trim(),
      });
    });
  });
}
