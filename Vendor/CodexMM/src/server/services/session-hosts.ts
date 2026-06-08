import type { SessionRecord } from "../../shared/contracts";
import { AppError } from "../lib/errors";

export const LOCAL_HOST_ID = "local";
export const LOCAL_HOST_LABEL = "This Mac";

export type SessionHost = {
  hostId: string;
  hostLabel: string;
  isRemote: boolean;
};

export function localSessionHost(): SessionHost {
  return {
    hostId: LOCAL_HOST_ID,
    hostLabel: LOCAL_HOST_LABEL,
    isRemote: false,
  };
}

export function normalizeRemoteHostTarget(sshTarget: unknown): SessionHost {
  if (typeof sshTarget !== "string") {
    throw invalidRemoteHost("Remote SSH target is required.");
  }

  const hostLabel = sshTarget.trim();

  if (
    hostLabel.length === 0 ||
    hostLabel.length > 255 ||
    hostLabel.startsWith("-") ||
    /[\s\0]/u.test(hostLabel)
  ) {
    throw invalidRemoteHost("Remote SSH target must be a single SSH host alias.");
  }

  return {
    hostId: Buffer.from(hostLabel, "utf8").toString("base64url"),
    hostLabel,
    isRemote: true,
  };
}

export function isSafeRemoteHostId(hostId: string) {
  return /^[A-Za-z0-9_-]+$/u.test(hostId);
}

export function buildSessionRecordId(host: SessionHost, threadId: string) {
  return host.isRemote ? `remote:${host.hostId}:${threadId}` : threadId;
}

export function buildDirectRemoteSessionRecordId(host: SessionHost, threadId: string) {
  return `direct:${host.hostId}:${threadId}`;
}

export function readThreadId(record: Pick<SessionRecord, "id" | "threadId">) {
  return record.threadId || record.id;
}

function invalidRemoteHost(message: string) {
  return new AppError(400, "invalid_remote_host", message);
}
