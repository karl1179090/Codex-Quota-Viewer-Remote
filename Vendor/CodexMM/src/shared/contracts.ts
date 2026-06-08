export type SessionStatus =
  | "active"
  | "archived"
  | "deleted_pending_purge"
  | "restorable";

export type SessionRecord = {
  id: string;
  threadId: string;
  hostId: string;
  hostLabel: string;
  isRemote: boolean;
  filePath: string | null;
  activePath: string | null;
  archivePath: string | null;
  snapshotPath: string | null;
  originalRelativePath: string | null;
  cwd: string;
  startedAt: string;
  originator: string;
  source: string;
  cliVersion: string;
  modelProvider: string;
  sizeBytes: number;
  lineCount: number;
  eventCount: number;
  toolCallCount: number;
  userPromptExcerpt: string;
  latestAgentMessageExcerpt: string;
  status: SessionStatus;
  createdAt: string;
  updatedAt: string;
  indexedAt: string;
};

export type AuditEntry = {
  id: number;
  action: string;
  sessionId: string;
  sourcePath: string | null;
  targetPath: string | null;
  details: Record<string, string | boolean | null>;
  createdAt: string;
};

export type SessionTimelineItem =
  | {
      id: string;
      type: "message:user" | "message:assistant";
      timestamp: string;
      text: string;
    }
  | {
      id: string;
      type: "tool_call";
      timestamp: string;
      toolName: string;
      summary: string;
      input: string;
      output: string;
      status: "pending" | "completed" | "errored";
    };

export type SessionOfficialIssueCode =
  | "missing_thread"
  | "wrong_rollout_path"
  | "archived_flag_mismatch"
  | "missing_recent_conversation"
  | "stale_recent_conversation"
  | "snapshot_thread_still_present"
  | "snapshot_recent_conversation_still_present";

export type SessionOfficialState = {
  status: "synced" | "repair_needed" | "hidden" | "remote_copy";
  canAppearInCodex: boolean;
  issueCodes: SessionOfficialIssueCode[];
};

export type SessionDetail = {
  record: SessionRecord;
  auditEntries: AuditEntry[];
  timeline: SessionTimelineItem[];
  timelineTotal: number;
  timelineNextOffset: number | null;
  officialState: SessionOfficialState;
};

export type SessionTimelinePage = {
  items: SessionTimelineItem[];
  total: number;
  nextOffset: number | null;
};

export type SessionFilters = {
  query?: string;
  status?: SessionStatus;
  cwd?: string;
  hostId?: string;
};

export type RestoreMode = "resume_only" | "rebind_cwd";

export type ApiErrorCode =
  | "active_session_cannot_be_archived"
  | "active_session_must_be_deleted_before_purge"
  | "internal_server_error"
  | "invalid_remote_host"
  | "managed_session_path_outside"
  | "path_outside_managed_root"
  | "rebind_requires_target"
  | "remote_session_import_failed"
  | "remote_session_tar_failed"
  | "remote_ssh_failed"
  | "remote_sync_target_required"
  | "restore_target_missing_directory"
  | "restore_target_not_directory"
  | "restore_target_permission_denied"
  | "session_has_no_file_to_delete"
  | "session_is_not_restorable"
  | "unknown_server_error"
  | "unknown_session"
  | "unsupported_restore_mode";

export type ApiErrorDetails = {
  sessionId?: string;
  host?: string;
  label?: "active" | "archive" | "snapshot";
  managedRoot?: string;
  candidatePath?: string;
  resolvedCandidatePath?: string;
};

export type ApiErrorResponse = {
  code: ApiErrorCode;
  error: string;
  details?: ApiErrorDetails;
};

export type RestoreRequest = {
  sessionId: string;
  targetCwd?: string;
  restoreMode: RestoreMode;
  launch?: boolean;
};

export type BatchSessionActionRequest = {
  sessionIds: string[];
};

export type BatchSessionActionFailure = {
  sessionId: string;
  code?: ApiErrorCode;
  error: string;
  details?: ApiErrorDetails;
};

export type BatchSessionActionResponse = {
  records: SessionRecord[];
  failures: BatchSessionActionFailure[];
};

export type OfficialRepairStats = {
  createdThreads: number;
  updatedThreads: number;
  updatedSessionIndexEntries: number;
  removedBrokenThreads: number;
  hiddenSnapshotOnlySessions: number;
};

export type OfficialRepairResponse = {
  sessions: SessionRecord[];
  stats: OfficialRepairStats;
};

export type RemoteSessionImportRequest = {
  sshTarget: string;
  codexHomePath?: string;
};

export type RemoteSessionImportResponse = {
  hostId: string;
  hostLabel: string;
  importedCount: number;
  copiedFileCount: number;
  sessions: SessionRecord[];
};

export type RemoteSessionPreviewResponse = {
  hostId: string;
  hostLabel: string;
  previewedCount: number;
  sessions: SessionRecord[];
};

export type SessionSyncTarget =
  | {
      kind: "local";
    }
  | {
      kind: "remote";
      sshTarget: string;
      codexHomePath?: string;
    };

export type SessionSyncRequest = {
  target: SessionSyncTarget;
};

export type SessionSyncResponse = {
  sourceSessionId: string;
  targetHostId: string;
  targetHostLabel: string;
  relativePath: string;
  sessions: SessionRecord[];
};

export type UiConfigResponse = {
  language: "en" | "zh";
};
