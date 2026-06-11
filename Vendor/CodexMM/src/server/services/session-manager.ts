import { constants, mkdirSync } from "node:fs";
import {
  access,
  copyFile,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import path from "node:path";

import type {
  AuditEntry,
  BatchSessionActionResponse,
  RestoreRequest,
  OfficialRepairResponse,
  RemoteSessionImportRequest,
  RemoteSessionImportResponse,
  RemoteSessionPreviewResponse,
  SessionSyncRequest,
  SessionSyncResponse,
  SessionRecord,
  SessionDetail,
  SessionFilters,
  SessionTimelinePage,
} from "../../shared/contracts";
import { AppError } from "../lib/errors";
import {
  buildRemoteSessionRoots,
  buildSessionRoots,
  ensureInsidePath,
  ensureInsideRealpath,
  sessionArchivePath,
  sessionSnapshotPath,
} from "../lib/paths";
import { launchResumeCommand } from "./launch-resume";
import {
  buildFallbackRelativePath,
  buildResumeCommand,
  collectSessions,
  copyIfMissing,
  looksCanonicalSessionRelativePath,
  resolveSessionRelativePath,
  uniqueSessionIds,
} from "./session-manager-helpers";
import { CodexOfficialThreadBridge } from "./codex-official-thread-bridge";
import {
  DEFAULT_TIMELINE_PAGE_SIZE,
  MAX_TIMELINE_PAGE_SIZE,
  parseSessionCatalog,
} from "./jsonl-session-parser";
import { SessionRepository } from "./session-repository";
import type { CatalogSessionEntry } from "./session-repository-model";
import {
  LOCAL_HOST_ID,
  buildDirectRemoteSessionRecordId,
  buildSessionRecordId,
  isSafeRemoteHostId,
  localSessionHost,
  normalizeRemoteHostTarget,
  readThreadId,
  type SessionHost,
} from "./session-hosts";
import {
  previewRemoteSessionFiles,
  pullRemoteSessionFiles,
  readRemoteSessionFile,
  writeRemoteSessionFile,
  type RemoteSessionFileReader,
  type RemoteSessionFileWriter,
  type RemoteSessionPreviewer,
  type RemoteSessionPuller,
} from "./remote-session-importer";

type ManagerConfig = {
  codexHome: string;
  managerHome: string;
  remoteSessionPuller?: RemoteSessionPuller;
  remoteSessionPreviewer?: RemoteSessionPreviewer;
  remoteSessionFileReader?: RemoteSessionFileReader;
  remoteSessionFileWriter?: RemoteSessionFileWriter;
};

type SessionSourceEntry = Awaited<ReturnType<typeof collectSessions>>[number];
type ManagedSessionRoots = {
  sessionsRoot: string;
  archiveRoot: string;
  snapshotRoot: string;
};
type SessionHostContext = SessionHost & {
  roots: ManagedSessionRoots;
};
type RemoteHostManifest = {
  hostId: string;
  hostLabel: string;
  codexHomePath: string;
  lastImportedAt: string;
};
type DirectRemoteSessionEntry = CatalogSessionEntry & {
  sshTarget: string;
  codexHomePath: string;
  relativePath: string;
};

export type SessionManager = ReturnType<typeof createSessionManager>;

export function createSessionManager(config: ManagerConfig) {
  const roots = buildSessionRoots(config.codexHome, config.managerHome);
  const remoteSessionPuller = config.remoteSessionPuller ?? pullRemoteSessionFiles;
  const remoteSessionPreviewer =
    config.remoteSessionPreviewer ?? previewRemoteSessionFiles;
  const remoteSessionFileReader =
    config.remoteSessionFileReader ?? readRemoteSessionFile;
  const remoteSessionFileWriter =
    config.remoteSessionFileWriter ?? writeRemoteSessionFile;
  mkdirSync(config.managerHome, { recursive: true });
  mkdirSync(roots.archiveRoot, { recursive: true });
  mkdirSync(roots.snapshotRoot, { recursive: true });
  mkdirSync(roots.remoteRoot, { recursive: true });
  const repository = new SessionRepository(roots.databasePath);
  const officialThreads = new CodexOfficialThreadBridge(config.codexHome);
  const directRemoteSessions = new Map<string, DirectRemoteSessionEntry>();
  let mutationQueue = Promise.resolve();

  async function rescan() {
    return enqueueMutation(async () => {
      await scanAndIndexSessions();
      return listSessions();
    });
  }

  async function repairOfficialThreads(sessionIds?: string[]): Promise<OfficialRepairResponse> {
    return enqueueMutation(async () => {
      const targetIds = normalizeSessionIds(sessionIds);

      if (!targetIds) {
        const sessions = await scanAndIndexSessions();
        const stats = await officialThreads.repairSessions(localOfficialRecords(sessions), {
          cleanupBroken: true,
        });

        return {
          sessions: await listSessions(),
          stats,
        };
      }

      const refreshed = await refreshIndexedSessions(targetIds);
      const repairableRecords = localOfficialRecords(refreshed.records);
      const stats =
        repairableRecords.length > 0
          ? await officialThreads.repairSessions(repairableRecords, {
              sessionIds: targetIds,
            })
          : createEmptyRepairStats();

      for (const removedId of refreshed.removedIds) {
        const removed = await officialThreads.removeSession(removedId);

        if (removed.removedThread) {
          stats.removedBrokenThreads += 1;
        }

        if (removed.removedIndex) {
          stats.updatedSessionIndexEntries += 1;
        }
      }

      return {
        sessions: await listSessions(),
        stats,
      };
    });
  }

  async function importRemoteSessions(
    request: RemoteSessionImportRequest,
  ): Promise<RemoteSessionImportResponse> {
    return enqueueMutation(async () => {
      await ensureRoots();
      const host = normalizeRemoteHostTarget(request.sshTarget);
      const codexHomePath = normalizeCodexHomePath(request.codexHomePath);
      const remoteRoots = buildRemoteSessionRoots(roots.remoteRoot, host.hostId);

      await mkdir(remoteRoots.hostRoot, { recursive: true });
      await mkdir(remoteRoots.sessionsRoot, { recursive: true });
      await mkdir(remoteRoots.archiveRoot, { recursive: true });
      await mkdir(remoteRoots.snapshotRoot, { recursive: true });

      let pullResult;
      try {
        pullResult = await remoteSessionPuller({
          sshTarget: host.hostLabel,
          codexHomePath,
          destinationRoot: remoteRoots.sessionsRoot,
        });
      } catch (error) {
        if (error instanceof AppError) {
          throw error;
        }

        throw new AppError(
          502,
          "remote_session_import_failed",
          error instanceof Error ? error.message : "Remote session import failed.",
          { host: host.hostLabel },
        );
      }

      await writeRemoteHostManifest({
        hostId: host.hostId,
        hostLabel: host.hostLabel,
        codexHomePath,
        lastImportedAt: new Date().toISOString(),
      });
      clearDirectRemoteSessionsForHost(host.hostId);

      const sessions = await scanAndIndexSessions();
      return {
        hostId: host.hostId,
        hostLabel: host.hostLabel,
        importedCount: sessions.filter((session) => session.hostId === host.hostId).length,
        copiedFileCount: pullResult.copiedFileCount,
        sessions: await listSessions(),
      };
    });
  }

  async function previewRemoteSessions(
    request: RemoteSessionImportRequest,
  ): Promise<RemoteSessionPreviewResponse> {
    return enqueueMutation(async () => {
      const host = normalizeRemoteHostTarget(request.sshTarget);
      const codexHomePath = normalizeCodexHomePath(request.codexHomePath);
      const entries = await remoteSessionPreviewer({
        sshTarget: host.hostLabel,
        codexHomePath,
      });

      clearDirectRemoteSessionsForHost(host.hostId);

      for (const entry of entries) {
        const threadId = entry.parsed.summary.id;
        const recordId = buildDirectRemoteSessionRecordId(host, threadId);

        directRemoteSessions.set(recordId, {
          recordId,
          threadId,
          hostId: host.hostId,
          hostLabel: host.hostLabel,
          isRemote: true,
          summary: entry.parsed.summary,
          timeline: entry.parsed.timeline,
          activePath: `ssh://${host.hostLabel}/${entry.relativePath}`,
          archivePath: null,
          snapshotPath: null,
          originalRelativePath: entry.relativePath,
          status: "active",
          sshTarget: host.hostLabel,
          codexHomePath,
          relativePath: entry.relativePath,
        });
      }

      return {
        hostId: host.hostId,
        hostLabel: host.hostLabel,
        previewedCount: entries.length,
        sessions: await listSessions(),
      };
    });
  }

  async function syncSession(
    sessionId: string,
    request: SessionSyncRequest,
  ): Promise<SessionSyncResponse> {
    return enqueueMutation(async () => {
      await ensureRoots();
      const source = await readSessionFileForSync(sessionId);
      const target = normalizeSyncTarget(request.target);

      if (target.kind === "local") {
        const targetPath = await assertManagedPath(
          "active",
          roots.sessionsRoot,
          path.join(roots.sessionsRoot, source.relativePath),
          { allowMissingTail: true },
        );
        await mkdir(path.dirname(targetPath), { recursive: true });
        await writeFile(targetPath, source.content);

        const sessions = await scanAndIndexSessions();
        return {
          sourceSessionId: sessionId,
          targetHostId: LOCAL_HOST_ID,
          targetHostLabel: localSessionHost().hostLabel,
          relativePath: source.relativePath,
          sessions: mergeDirectRemoteRecords(sessions),
        };
      }

      await remoteSessionFileWriter({
        sshTarget: target.host.hostLabel,
        codexHomePath: target.codexHomePath,
        relativePath: source.relativePath,
        content: source.content,
      });

      return {
        sourceSessionId: sessionId,
        targetHostId: target.host.hostId,
        targetHostLabel: target.host.hostLabel,
        relativePath: source.relativePath,
        sessions: await listSessions(),
      };
    });
  }

  async function scanAndIndexSessions() {
    await ensureRoots();
    const hostContexts = await listHostContexts();
    const latestAuditBySessionId = new Map(
      repository.listLatestAuditEntries().map((entry) => [entry.sessionId, entry]),
    );

    const catalogEntries = (
      await Promise.all(
        hostContexts.map((hostContext) =>
          scanHostSessions(hostContext, latestAuditBySessionId),
        ),
      )
    ).flat();

    return repository.replaceCatalog(catalogEntries);
  }

  async function scanHostSessions(
    hostContext: SessionHostContext,
    latestAuditBySessionId: Map<string, AuditEntry>,
  ) {
    const [activeEntries, archivedEntries, snapshotEntries] = await Promise.all([
      collectSessions(hostContext.roots.sessionsRoot),
      collectSessions(hostContext.roots.archiveRoot),
      collectSessions(hostContext.roots.snapshotRoot),
    ]);
    const activeById = new Map<string, SessionSourceEntry>();
    const archivedById = new Map<string, SessionSourceEntry>();
    const archivedRelativePaths = new Map<string, string>();
    const snapshotById = new Map<string, SessionSourceEntry>();

    for (const entry of activeEntries) {
      activeById.set(entry.parsed.summary.id, entry);
    }

    for (const entry of archivedEntries) {
      const { entry: normalizedEntry, originalRelativePath } = await canonicalizeArchivedEntry(
        hostContext.roots,
        entry,
        buildFallbackRelativePath(entry.parsed.summary.startedAt, entry.parsed.summary.id),
      );

      archivedById.set(normalizedEntry.parsed.summary.id, normalizedEntry);
      archivedRelativePaths.set(normalizedEntry.parsed.summary.id, originalRelativePath);
    }

    for (const entry of snapshotEntries) {
      snapshotById.set(entry.parsed.summary.id, entry);
    }

    const catalogEntries: CatalogSessionEntry[] = [];
    const sessionIds = new Set<string>([
      ...activeById.keys(),
      ...archivedById.keys(),
      ...snapshotById.keys(),
    ]);

    for (const sessionId of sessionIds) {
      const activeEntry = activeById.get(sessionId);
      const archivedEntry = archivedById.get(sessionId);
      const snapshotEntry = snapshotById.get(sessionId);
      const primaryEntry = activeEntry ?? archivedEntry ?? snapshotEntry;
      const recordId = buildSessionRecordId(hostContext, sessionId);

      if (!primaryEntry) {
        continue;
      }

      const summary = primaryEntry.parsed.summary;
      const latestAudit = latestAuditBySessionId.get(recordId);
      const activePath = activeEntry?.filePath ?? null;
      const archivePath = archivedEntry?.filePath ?? null;
      const snapshotPath = snapshotEntry?.filePath ?? null;
      const originalRelativePath =
        activeEntry
          ? path.relative(hostContext.roots.sessionsRoot, activeEntry.filePath)
          : archivedRelativePaths.get(sessionId) ??
            readRelativePathFromAudit(latestAudit?.sourcePath, hostContext.roots) ??
            readRelativePathFromAudit(latestAudit?.targetPath, hostContext.roots) ??
            buildFallbackRelativePath(summary.startedAt, summary.id);

      catalogEntries.push({
        recordId,
        threadId: summary.id,
        hostId: hostContext.hostId,
        hostLabel: hostContext.hostLabel,
        isRemote: hostContext.isRemote,
        summary,
        timeline: primaryEntry.parsed.timeline,
        activePath,
        archivePath,
        snapshotPath,
        originalRelativePath,
        status: resolveCatalogStatus(activePath, archivePath, latestAudit?.action),
      });
    }

    return catalogEntries;
  }

  async function refreshIndexedSessions(sessionIds: string[]) {
    await ensureRoots();
    const latestAuditBySessionId = new Map(
      repository.listLatestAuditEntries().map((entry) => [entry.sessionId, entry]),
    );
    const records: SessionRecord[] = [];
    const removedIds: string[] = [];

    for (const sessionId of sessionIds) {
      const existing = repository.getSession(sessionId);

      if (!existing) {
        continue;
      }

      const catalogEntry = await readCatalogEntryForSession(
        existing,
        latestAuditBySessionId.get(sessionId),
      );

      if (!catalogEntry) {
        repository.deleteSession(sessionId);
        removedIds.push(sessionId);
        continue;
      }

      records.push(repository.saveCatalogEntry(catalogEntry));
    }

    return {
      records,
      removedIds,
    };
  }

  async function readCatalogEntryForSession(
    existing: SessionRecord,
    latestAudit?: AuditEntry,
  ): Promise<CatalogSessionEntry | null> {
    const recordRoots = managedRootsForRecord(existing);
    const threadId = readThreadId(existing);
    const fallbackRelativePath =
      existing.originalRelativePath ??
      readRelativePathFromAudit(latestAudit?.sourcePath, recordRoots) ??
      readRelativePathFromAudit(latestAudit?.targetPath, recordRoots) ??
      buildFallbackRelativePath(existing.startedAt, threadId);
    const activeEntry = await readCatalogSourceEntry(threadId, recordRoots.sessionsRoot, [
      existing.activePath,
      path.join(recordRoots.sessionsRoot, fallbackRelativePath),
      latestAudit?.sourcePath,
      latestAudit?.targetPath,
    ]);
    const archived = await readArchivedCatalogSourceEntry(
      recordRoots,
      threadId,
      fallbackRelativePath,
      [
        existing.archivePath,
        sessionArchivePath(recordRoots.archiveRoot, fallbackRelativePath),
        latestAudit?.sourcePath,
        latestAudit?.targetPath,
      ],
    );
    const snapshotEntry = await readCatalogSourceEntry(threadId, recordRoots.snapshotRoot, [
      existing.snapshotPath,
      sessionSnapshotPath(recordRoots.snapshotRoot, existing.id),
    ]);
    const primaryEntry = activeEntry ?? archived.entry ?? snapshotEntry;

    if (!primaryEntry) {
      return null;
    }

    return {
      recordId: existing.id,
      threadId,
      hostId: existing.hostId,
      hostLabel: existing.hostLabel,
      isRemote: existing.isRemote,
      summary: primaryEntry.parsed.summary,
      timeline: primaryEntry.parsed.timeline,
      activePath: activeEntry?.filePath ?? null,
      archivePath: archived.entry?.filePath ?? null,
      snapshotPath: snapshotEntry?.filePath ?? null,
      originalRelativePath:
        activeEntry
          ? path.relative(recordRoots.sessionsRoot, activeEntry.filePath)
          : archived.originalRelativePath ??
            readRelativePathFromAudit(latestAudit?.sourcePath, recordRoots) ??
            readRelativePathFromAudit(latestAudit?.targetPath, recordRoots) ??
            buildFallbackRelativePath(
              primaryEntry.parsed.summary.startedAt,
              primaryEntry.parsed.summary.id,
            ),
      status: resolveCatalogStatus(
        activeEntry?.filePath ?? null,
        archived.entry?.filePath ?? null,
        latestAudit?.action,
      ),
    };
  }

  async function readCatalogSourceEntry(
    sessionId: string,
    root: string,
    candidates: Array<string | null | undefined>,
  ): Promise<SessionSourceEntry | null> {
    for (const candidate of uniquePaths(candidates)) {
      const filePath = await resolveManagedExistingPath(root, candidate);

      if (!filePath) {
        continue;
      }

      try {
        const parsed = await parseSessionCatalog(filePath);

        if (!parsed || parsed.summary.id !== sessionId) {
          continue;
        }

        return {
          filePath,
          parsed,
        };
      } catch {
        continue;
      }
    }

    return null;
  }

  async function readArchivedCatalogSourceEntry(
    recordRoots: ManagedSessionRoots,
    sessionId: string,
    fallbackRelativePath: string,
    candidates: Array<string | null | undefined>,
  ): Promise<{
    entry: SessionSourceEntry | null;
    originalRelativePath: string | null;
  }> {
    for (const candidate of uniquePaths(candidates)) {
      const filePath = await resolveManagedExistingPath(recordRoots.archiveRoot, candidate);

      if (!filePath) {
        continue;
      }

      try {
        const parsed = await parseSessionCatalog(filePath);

        if (!parsed || parsed.summary.id !== sessionId) {
          continue;
        }
        const normalized = await canonicalizeArchivedEntry(
          recordRoots,
          { filePath, parsed },
          fallbackRelativePath,
        );

        return {
          entry: normalized.entry,
          originalRelativePath: normalized.originalRelativePath,
        };
      } catch {
        continue;
      }
    }

    return {
      entry: null,
      originalRelativePath: null,
    };
  }

  async function canonicalizeArchivedEntry(
    recordRoots: ManagedSessionRoots,
    entry: SessionSourceEntry,
    fallbackRelativePath: string,
  ): Promise<{
    entry: SessionSourceEntry;
    originalRelativePath: string;
  }> {
    const currentRelativePath = path.relative(recordRoots.archiveRoot, entry.filePath);
    const originalRelativePath = looksCanonicalSessionRelativePath(
      currentRelativePath,
      entry.parsed.summary.id,
    )
      ? currentRelativePath
      : fallbackRelativePath;
    const archivePath = await ensureInsideRealpath(
      recordRoots.archiveRoot,
      sessionArchivePath(recordRoots.archiveRoot, originalRelativePath),
      { allowMissingTail: true },
    );

    if (entry.filePath !== archivePath) {
      await mkdir(path.dirname(archivePath), { recursive: true });
      await rename(entry.filePath, archivePath);
    }

    return {
      entry: {
        ...entry,
        filePath: archivePath,
      },
      originalRelativePath,
    };
  }

  async function resolveManagedExistingPath(root: string, candidate: string | null | undefined) {
    if (!candidate) {
      return null;
    }

    try {
      await ensureInsideRealpath(root, candidate);
      return path.resolve(candidate);
    } catch {
      return null;
    }
  }

  async function listSessions(filters: SessionFilters = {}) {
    return mergeDirectRemoteRecords(repository.listSessions(filters), filters);
  }

  async function getSessionDetail(id: string): Promise<SessionDetail> {
    const directEntry = directRemoteSessions.get(id);
    if (directEntry) {
      const record = directEntryToRecord(directEntry);
      return {
        record,
        auditEntries: [],
        timeline: directEntry.timeline.slice(0, DEFAULT_TIMELINE_PAGE_SIZE),
        timelineTotal: directEntry.timeline.length,
        timelineNextOffset:
          directEntry.timeline.length > DEFAULT_TIMELINE_PAGE_SIZE
            ? DEFAULT_TIMELINE_PAGE_SIZE
            : null,
        officialState: await officialThreads.inspectSession(record),
      };
    }

    requireSession(id);
    const detail = repository.listDetails(id);
    const timelinePage = repository.listTimelinePage(id, {
      offset: 0,
      limit: DEFAULT_TIMELINE_PAGE_SIZE,
    });

    return {
      ...detail,
      timeline: timelinePage.items,
      timelineTotal: timelinePage.total,
      timelineNextOffset: timelinePage.nextOffset,
      officialState: await officialThreads.inspectSession(detail.record),
    };
  }

  async function getSessionTimelinePage(
    id: string,
    options: {
      offset?: number;
      limit?: number;
    } = {},
  ): Promise<SessionTimelinePage> {
    const directEntry = directRemoteSessions.get(id);
    if (directEntry) {
      const offset = Math.max(options.offset ?? 0, 0);
      const limit = clampTimelineLimit(options.limit);
      return {
        items: directEntry.timeline.slice(offset, offset + limit),
        total: directEntry.timeline.length,
        nextOffset:
          offset + limit < directEntry.timeline.length ? offset + limit : null,
      };
    }

    requireSession(id);
    return repository.listTimelinePage(id, {
      offset: options.offset,
      limit: clampTimelineLimit(options.limit),
    });
  }

  async function archiveSession(id: string): Promise<SessionRecord> {
    return enqueueMutation(() => archiveSessionUnsafe(id));
  }

  async function archiveSessionUnsafe(id: string): Promise<SessionRecord> {
    await ensureRoots();
    const record = requireSession(id);
    const recordRoots = managedRootsForRecord(record);

    if (!record.activePath) {
      if (record.archivePath) {
        return record;
      }

      throw new AppError(
        409,
        "active_session_cannot_be_archived",
        "Session is not active and cannot be archived.",
      );
    }

    const sourcePath = await assertManagedPath("active", recordRoots.sessionsRoot, record.activePath);
    const targetPath = await assertManagedPath(
      "archive",
      recordRoots.archiveRoot,
      sessionArchivePath(recordRoots.archiveRoot, resolveSessionRelativePath(record)),
      { allowMissingTail: true },
    );
    await mkdir(path.dirname(targetPath), { recursive: true });
    await rename(sourcePath, targetPath);

    const next = repository.updateSession(id, {
      activePath: null,
      archivePath: targetPath,
      status: "archived",
    });
    if (!next.isRemote) {
      await officialThreads.repairSessions([next]);
    }

    repository.insertAudit("archive", id, sourcePath, targetPath);
    return next;
  }

  async function deleteSession(id: string): Promise<SessionRecord> {
    return enqueueMutation(() => deleteSessionUnsafe(id));
  }

  async function deleteSessionUnsafe(id: string): Promise<SessionRecord> {
    await ensureRoots();
    const record = requireSession(id);
    const recordRoots = managedRootsForRecord(record);
    const sourcePath = await assertManagedCurrentPath(record);
    const archivePath = await assertManagedPath(
      "archive",
      recordRoots.archiveRoot,
      sessionArchivePath(recordRoots.archiveRoot, resolveSessionRelativePath(record)),
      { allowMissingTail: true },
    );
    const snapshotPath = record.snapshotPath
      ? await assertManagedPath("snapshot", recordRoots.snapshotRoot, record.snapshotPath)
      : await assertManagedPath(
          "snapshot",
          recordRoots.snapshotRoot,
          sessionSnapshotPath(recordRoots.snapshotRoot, id),
          { allowMissingTail: true },
        );

    await mkdir(path.dirname(snapshotPath), { recursive: true });
    await copyIfMissing(sourcePath, snapshotPath);

    if (sourcePath !== archivePath) {
      await mkdir(path.dirname(archivePath), { recursive: true });
      await rename(sourcePath, archivePath);
    }

    const next = repository.updateSession(id, {
      activePath: null,
      archivePath,
      snapshotPath,
      status: "deleted_pending_purge",
    });
    if (!next.isRemote) {
      await officialThreads.repairSessions([next]);
    }

    repository.insertAudit("delete", id, sourcePath, archivePath, {
      snapshotPath,
    });
    return next;
  }

  async function restoreSession(request: RestoreRequest) {
    return enqueueMutation(() => restoreSessionUnsafe(request));
  }

  async function restoreSessionUnsafe(request: RestoreRequest) {
    await ensureRoots();
    const record = requireSession(request.sessionId);
    const recordRoots = managedRootsForRecord(record);
    const restoreMode = normalizeRestoreMode(request.restoreMode);
    const isAlreadyActive = Boolean(record.activePath);
    const sourcePath = isAlreadyActive
      ? await assertManagedPath("active", recordRoots.sessionsRoot, record.activePath!)
      : await assertManagedRestoreSource(record);
    const restorePath = isAlreadyActive
      ? await assertManagedPath("active", recordRoots.sessionsRoot, record.activePath!)
      : await assertManagedPath(
          "active",
          recordRoots.sessionsRoot,
          path.join(
            recordRoots.sessionsRoot,
            record.originalRelativePath ??
              buildFallbackRelativePath(record.startedAt, readThreadId(record)),
          ),
          { allowMissingTail: true },
        );

    if (request.targetCwd) {
      await validateRestoreTargetDirectory(request.targetCwd);
    }

    if (restoreMode === "rebind_cwd" && !request.targetCwd) {
      throw new AppError(
        400,
        "rebind_requires_target",
        "永久改目录时必须提供目标项目目录。",
      );
    }

    if (!isAlreadyActive) {
      await mkdir(path.dirname(restorePath), { recursive: true });

      if (sourcePath !== restorePath) {
        if (sourcePath === record.archivePath) {
          await rename(sourcePath, restorePath);
        } else {
          await copyFile(sourcePath, restorePath);
        }
      }
    }

    if (restoreMode === "rebind_cwd") {
      await rewriteSessionMetaCwd(restorePath, request.targetCwd!);
    }

    const next = isAlreadyActive
      ? restoreMode === "rebind_cwd"
        ? repository.updateSession(record.id, {
            cwd: request.targetCwd!,
          })
        : record
      : repository.updateSession(record.id, {
          activePath: restorePath,
          archivePath: sourcePath === record.archivePath ? null : record.archivePath,
          cwd: restoreMode === "rebind_cwd" ? request.targetCwd! : record.cwd,
          status: "active",
        });
    if (!next.isRemote) {
      await officialThreads.repairSessions([next]);
    }

    const resumeCommand = buildResumeCommand(
      readThreadId(record),
      restoreMode === "resume_only" ? request.targetCwd : undefined,
    );
    let launched = false;

    if (request.launch) {
      launched = await launchResumeCommand(resumeCommand);
    }

    repository.insertAudit("restore", record.id, sourcePath, restorePath, {
      targetCwd: request.targetCwd ?? null,
      restoreMode,
      launched,
    });

    return { record: next, resumeCommand, launched };
  }

  async function purgeSession(id: string): Promise<{ purgedId: string }> {
    return enqueueMutation(() => purgeSessionUnsafe(id));
  }

  async function purgeSessionUnsafe(id: string): Promise<{ purgedId: string }> {
    await ensureRoots();
    const record = requireSession(id);
    const recordRoots = managedRootsForRecord(record);

    if (record.activePath) {
      throw new AppError(
        409,
        "active_session_must_be_deleted_before_purge",
        "Active sessions must be deleted before purge.",
      );
    }

    if (record.archivePath) {
      await rm(await assertManagedPath("archive", recordRoots.archiveRoot, record.archivePath), {
        force: true,
      });
    }

    if (record.snapshotPath) {
      await rm(await assertManagedPath("snapshot", recordRoots.snapshotRoot, record.snapshotPath), {
        force: true,
      });
    }

    repository.insertAudit("purge", id, record.archivePath, null, {
      snapshotPath: record.snapshotPath,
    });
    if (!record.isRemote) {
      await officialThreads.removeSession(readThreadId(record));
    }
    repository.deleteSession(id);
    return { purgedId: id };
  }

  async function batchArchiveSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(() => runBatch(sessionIds, archiveSessionUnsafe));
  }

  async function batchTrashSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(() => runBatch(sessionIds, deleteSessionUnsafe));
  }

  async function batchRestoreSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(() =>
      runBatch(sessionIds, async (sessionId) => {
        const restored = await restoreSessionUnsafe({
          sessionId,
          restoreMode: "resume_only",
        });
        return restored.record;
      }),
    );
  }

  async function batchPurgeSessions(
    sessionIds: string[],
  ): Promise<BatchSessionActionResponse> {
    return enqueueMutation(async () => {
      const uniqueIds = uniqueSessionIds(sessionIds);
      const failures: BatchSessionActionResponse["failures"] = [];

      for (const sessionId of uniqueIds) {
        try {
          await purgeSessionUnsafe(sessionId);
        } catch (error) {
          failures.push(mapBatchFailure(sessionId, error));
        }
      }

      return { records: [], failures };
    });
  }

  async function listHostContexts(): Promise<SessionHostContext[]> {
    const localHost = localSessionHost();
    const remoteHosts = await readRemoteHostManifests();

    return [
      {
        ...localHost,
        roots,
      },
      ...remoteHosts.map((remoteHost) => ({
        hostId: remoteHost.hostId,
        hostLabel: remoteHost.hostLabel,
        isRemote: true,
        roots: buildRemoteSessionRoots(roots.remoteRoot, remoteHost.hostId),
      })),
    ];
  }

  async function readRemoteHostManifests(): Promise<RemoteHostManifest[]> {
    await mkdir(roots.remoteRoot, { recursive: true });

    let entries;
    try {
      entries = await readdir(roots.remoteRoot, { withFileTypes: true });
    } catch {
      return [];
    }

    const manifests: RemoteHostManifest[] = [];

    for (const entry of entries) {
      if (!entry.isDirectory() || !isSafeRemoteHostId(entry.name)) {
        continue;
      }

      const remoteRoots = buildRemoteSessionRoots(roots.remoteRoot, entry.name);
      try {
        const manifest = JSON.parse(
          await readFile(remoteRoots.manifestPath, "utf8"),
        ) as Partial<RemoteHostManifest>;

        if (
          manifest.hostId === entry.name &&
          typeof manifest.hostLabel === "string" &&
          manifest.hostLabel.length > 0
        ) {
          manifests.push({
            hostId: manifest.hostId,
            hostLabel: manifest.hostLabel,
            codexHomePath:
              typeof manifest.codexHomePath === "string" && manifest.codexHomePath.length > 0
                ? manifest.codexHomePath
                : "~/.codex",
            lastImportedAt:
              typeof manifest.lastImportedAt === "string" && manifest.lastImportedAt.length > 0
                ? manifest.lastImportedAt
                : new Date(0).toISOString(),
          });
        }
      } catch {
        continue;
      }
    }

    return manifests.sort((left, right) => left.hostLabel.localeCompare(right.hostLabel));
  }

  async function writeRemoteHostManifest(manifest: RemoteHostManifest) {
    const remoteRoots = buildRemoteSessionRoots(roots.remoteRoot, manifest.hostId);
    await mkdir(remoteRoots.hostRoot, { recursive: true });
    await writeFile(
      remoteRoots.manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      "utf8",
    );
  }

  function managedRootsForRecord(record: Pick<SessionRecord, "hostId" | "isRemote">): ManagedSessionRoots {
    if (!record.isRemote) {
      return roots;
    }

    if (!isSafeRemoteHostId(record.hostId) || record.hostId === LOCAL_HOST_ID) {
      throw new AppError(
        400,
        "invalid_remote_host",
        "Remote session host metadata is invalid.",
        { host: record.hostId },
      );
    }

    return buildRemoteSessionRoots(roots.remoteRoot, record.hostId);
  }

  function localOfficialRecords(records: SessionRecord[]) {
    return records.filter((record) => !record.isRemote);
  }

  function normalizeCodexHomePath(value: unknown) {
    return typeof value === "string" && value.trim().length > 0
      ? value.trim()
      : "~/.codex";
  }

  async function readSessionFileForSync(sessionId: string) {
    const directEntry = directRemoteSessions.get(sessionId);
    if (directEntry) {
      return {
        relativePath: directEntry.relativePath,
        content: await remoteSessionFileReader({
          sshTarget: directEntry.sshTarget,
          codexHomePath: directEntry.codexHomePath,
          relativePath: directEntry.relativePath,
        }),
      };
    }

    const record = requireSession(sessionId);
    const sourcePath = record.activePath ?? record.archivePath ?? record.snapshotPath;

    if (!sourcePath) {
      throw new AppError(
        409,
        "session_has_no_file_to_delete",
        "Session has no file available to sync.",
      );
    }

    const recordRoots = managedRootsForRecord(record);
    const label = record.activePath
      ? "active"
      : record.archivePath
        ? "archive"
        : "snapshot";
    const managedSourcePath = await assertManagedPath(
      label,
      label === "active"
        ? recordRoots.sessionsRoot
        : label === "archive"
          ? recordRoots.archiveRoot
          : recordRoots.snapshotRoot,
      sourcePath,
    );

    return {
      relativePath:
        record.originalRelativePath ??
        buildFallbackRelativePath(record.startedAt, readThreadId(record)),
      content: await readFile(managedSourcePath),
    };
  }

  function normalizeSyncTarget(target: SessionSyncRequest["target"] | undefined) {
    if (!target) {
      throw new AppError(
        400,
        "remote_sync_target_required",
        "Session sync target is required.",
      );
    }

    if (target.kind === "local") {
      return { kind: "local" as const };
    }

    if (target.kind === "remote") {
      return {
        kind: "remote" as const,
        host: normalizeRemoteHostTarget(target.sshTarget),
        codexHomePath: normalizeCodexHomePath(target.codexHomePath),
      };
    }

    throw new AppError(
      400,
      "remote_sync_target_required",
      "Session sync target is required.",
    );
  }

  function mergeDirectRemoteRecords(
    records: SessionRecord[],
    filters: SessionFilters = {},
  ) {
    const directRecords = [...directRemoteSessions.values()]
      .map(directEntryToRecord)
      .filter((record) => sessionMatchesFilters(record, filters));
    const directHostThreadKeys = new Set(directRecords.map(sessionHostThreadKey));
    const persistedRecords = records.filter(
      (record) => !directHostThreadKeys.has(sessionHostThreadKey(record)),
    );
    const existingIds = new Set(persistedRecords.map((record) => record.id));

    return [
      ...persistedRecords,
      ...directRecords.filter((record) => !existingIds.has(record.id)),
    ].sort((left, right) => {
      const timeDelta = Date.parse(right.startedAt) - Date.parse(left.startedAt);
      return timeDelta === 0 ? left.id.localeCompare(right.id) : timeDelta;
    });
  }

  function clearDirectRemoteSessionsForHost(hostId: string) {
    for (const staleId of [...directRemoteSessions.keys()]) {
      const staleEntry = directRemoteSessions.get(staleId);
      if (staleEntry?.hostId === hostId) {
        directRemoteSessions.delete(staleId);
      }
    }
  }

  return {
    rescan,
    importRemoteSessions,
    previewRemoteSessions,
    syncSession,
    listSessions,
    getSessionDetail,
    getSessionTimelinePage,
    archiveSession,
    deleteSession,
    restoreSession,
    purgeSession,
    batchArchiveSessions,
    batchTrashSessions,
    batchRestoreSessions,
    batchPurgeSessions,
    repairOfficialThreads,
  };

  function enqueueMutation<T>(task: () => Promise<T>) {
    const next = mutationQueue.then(task, task);
    mutationQueue = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }

  async function ensureRoots() {
    await mkdir(roots.sessionsRoot, { recursive: true });
    await mkdir(roots.archiveRoot, { recursive: true });
    await mkdir(roots.snapshotRoot, { recursive: true });
    await mkdir(roots.remoteRoot, { recursive: true });
    await mkdir(config.managerHome, { recursive: true });
  }

  function requireSession(id: string) {
    const record = repository.getSession(id);
    if (!record) {
      throw new AppError(404, "unknown_session", `Unknown session: ${id}`, {
        sessionId: id,
      });
    }

    return record;
  }

  async function runBatch(
    sessionIds: string[],
    action: (sessionId: string) => Promise<SessionRecord>,
  ): Promise<BatchSessionActionResponse> {
    const uniqueIds = uniqueSessionIds(sessionIds);
    const records: SessionRecord[] = [];
    const failures: BatchSessionActionResponse["failures"] = [];

    for (const sessionId of uniqueIds) {
      try {
        records.push(await action(sessionId));
      } catch (error) {
        failures.push(mapBatchFailure(sessionId, error));
      }
    }

    return { records, failures };
  }

  async function validateRestoreTargetDirectory(targetCwd: string) {
    try {
      const targetStats = await stat(targetCwd);

      if (!targetStats.isDirectory()) {
        throw new AppError(
          400,
          "restore_target_not_directory",
          "目标项目目录不是文件夹，请重新选择目录。",
        );
      }

      if ((targetStats.mode & 0o555) === 0) {
        throw new AppError(
          400,
          "restore_target_permission_denied",
          "当前没有权限访问目标项目目录，请检查目录权限。",
        );
      }

      await access(targetCwd, constants.R_OK | constants.X_OK);
    } catch (error) {
      if (error instanceof AppError) {
        throw error;
      }

      if (isNodeErrorWithCode(error, "ENOENT")) {
        throw new AppError(
          400,
          "restore_target_missing_directory",
          "目标项目目录不存在，请先创建后再恢复。",
        );
      }

      if (isNodeErrorWithCode(error, "ENOTDIR")) {
        throw new AppError(
          400,
          "restore_target_not_directory",
          "目标项目目录不是文件夹，请重新选择目录。",
        );
      }

      if (isNodeErrorWithCode(error, "EACCES") || isNodeErrorWithCode(error, "EPERM")) {
        throw new AppError(
          400,
          "restore_target_permission_denied",
          "当前没有权限访问目标项目目录，请检查目录权限。",
        );
      }

      throw error;
    }
  }

  async function assertManagedCurrentPath(record: SessionRecord) {
    const recordRoots = managedRootsForRecord(record);

    if (record.activePath) {
      return assertManagedPath("active", recordRoots.sessionsRoot, record.activePath);
    }

    if (record.archivePath) {
      return assertManagedPath("archive", recordRoots.archiveRoot, record.archivePath);
    }

    throw new AppError(
      409,
      "session_has_no_file_to_delete",
      "Session has no file available to delete.",
    );
  }

  async function assertManagedRestoreSource(record: SessionRecord) {
    const recordRoots = managedRootsForRecord(record);

    if (record.archivePath) {
      return assertManagedPath("archive", recordRoots.archiveRoot, record.archivePath);
    }

    if (record.snapshotPath) {
      return assertManagedPath("snapshot", recordRoots.snapshotRoot, record.snapshotPath);
    }

    throw new AppError(
      409,
      "session_is_not_restorable",
      "Session is not restorable.",
    );
  }

  async function assertManagedPath(
    label: "active" | "archive" | "snapshot",
    root: string,
    candidate: string,
    options: {
      allowMissingTail?: boolean;
    } = {},
  ) {
    try {
      return await ensureInsideRealpath(root, candidate, options);
    } catch (error) {
      const pathDetails =
        error instanceof AppError &&
        error.details &&
        "managedRoot" in error.details &&
        typeof error.details.managedRoot === "string" &&
        "candidatePath" in error.details &&
        typeof error.details.candidatePath === "string" &&
        "resolvedCandidatePath" in error.details &&
        typeof error.details.resolvedCandidatePath === "string"
          ? {
              managedRoot: error.details.managedRoot,
              candidatePath: error.details.candidatePath,
              resolvedCandidatePath: error.details.resolvedCandidatePath,
            }
          : null;

      throw new AppError(
        400,
        "managed_session_path_outside",
        `会话 ${label} 文件路径超出了受管目录，已拒绝继续操作。`,
        {
          label,
          ...(pathDetails ?? {}),
        },
      );
    }
  }
}

function resolveCatalogStatus(
  activePath: string | null,
  archivePath: string | null,
  latestAuditAction?: string,
) {
  if (activePath) {
    return "active" as const;
  }

  if (archivePath) {
    return latestAuditAction === "delete"
      ? "deleted_pending_purge"
      : "archived";
  }

  return "restorable" as const;
}

function directEntryToRecord(entry: DirectRemoteSessionEntry): SessionRecord {
  const now = new Date().toISOString();

  return {
    id: entry.recordId,
    threadId: entry.threadId,
    hostId: entry.hostId,
    hostLabel: entry.hostLabel,
    isRemote: true,
    filePath: entry.activePath,
    activePath: entry.activePath,
    archivePath: null,
    snapshotPath: null,
    originalRelativePath: entry.originalRelativePath,
    cwd: entry.summary.cwd,
    startedAt: entry.summary.startedAt,
    originator: entry.summary.originator,
    source: entry.summary.source,
    cliVersion: entry.summary.cliVersion,
    modelProvider: entry.summary.modelProvider,
    sizeBytes: entry.summary.sizeBytes,
    lineCount: entry.summary.lineCount,
    eventCount: entry.summary.eventCount,
    toolCallCount: entry.summary.toolCallCount,
    userPromptExcerpt: entry.summary.userPromptExcerpt,
    latestAgentMessageExcerpt: entry.summary.latestAgentMessageExcerpt,
    status: entry.status,
    createdAt: now,
    updatedAt: now,
    indexedAt: now,
  };
}

function sessionMatchesFilters(record: SessionRecord, filters: SessionFilters) {
  if (filters.status) {
    const statusMatches =
      filters.status === "archived"
        ? record.status === "archived" || record.status === "restorable"
        : record.status === filters.status;

    if (!statusMatches) {
      return false;
    }
  }

  if (filters.cwd && record.cwd !== filters.cwd) {
    return false;
  }

  if (filters.hostId && record.hostId !== filters.hostId) {
    return false;
  }

  if (filters.query) {
    const normalizedQuery = filters.query.toLowerCase();
    return [
      record.id,
      record.threadId,
      record.hostLabel,
      record.cwd,
      record.userPromptExcerpt,
      record.latestAgentMessageExcerpt,
    ].some((value) => value.toLowerCase().includes(normalizedQuery));
  }

  return true;
}

function sessionHostThreadKey(record: Pick<SessionRecord, "hostId" | "threadId">) {
  return `${record.hostId}\u0000${record.threadId}`;
}

function normalizeSessionIds(sessionIds?: string[]) {
  if (!sessionIds || sessionIds.length === 0) {
    return undefined;
  }

  const uniqueIds = uniqueSessionIds(sessionIds);
  return uniqueIds.length > 0 ? uniqueIds : undefined;
}

function uniquePaths(candidates: Array<string | null | undefined>) {
  return [...new Set(candidates.filter((candidate): candidate is string => Boolean(candidate)))];
}

function createEmptyRepairStats() {
  return {
    createdThreads: 0,
    updatedThreads: 0,
    updatedSessionIndexEntries: 0,
    removedBrokenThreads: 0,
    hiddenSnapshotOnlySessions: 0,
  };
}

function readRelativePathFromAudit(
  candidate: string | null | undefined,
  roots: ManagedSessionRoots,
) {
  if (!candidate) {
    return null;
  }

  try {
    return path.relative(
      candidate.startsWith(roots.archiveRoot) ? roots.archiveRoot : roots.sessionsRoot,
      ensureInsidePath(
        candidate.startsWith(roots.archiveRoot) ? roots.archiveRoot : roots.sessionsRoot,
        candidate,
      ),
    );
  } catch {
    return null;
  }
}

async function rewriteSessionMetaCwd(filePath: string, targetCwd: string) {
  const raw = await readFile(filePath, "utf8");
  const lines = raw.split("\n");
  let updated = false;

  const nextLines = lines.map((line) => {
    if (updated || !line.trim()) {
      return line;
    }

    try {
      const entry = JSON.parse(line) as {
        type?: unknown;
        payload?: {
          cwd?: unknown;
        };
      };

      if (entry.type !== "session_meta" || !entry.payload || typeof entry.payload !== "object") {
        return line;
      }

      entry.payload.cwd = targetCwd;
      updated = true;
      return JSON.stringify(entry);
    } catch {
      return line;
    }
  });

  if (!updated) {
    throw new Error(`Session metadata is missing from ${filePath}`);
  }

  await writeFile(filePath, nextLines.join("\n"));
}

function mapBatchFailure(sessionId: string, error: unknown) {
  if (error instanceof AppError) {
    return {
      sessionId,
      code: error.code,
      error: error.message,
      details: error.details,
    };
  }

  return {
    sessionId,
    error: error instanceof Error ? error.message : "Unknown error",
  };
}

function isNodeErrorWithCode(error: unknown, code: string) {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as Error & { code?: unknown }).code === code
  );
}

function normalizeRestoreMode(value: RestoreRequest["restoreMode"]) {
  if (value === "resume_only") {
    return "resume_only" as const;
  }

  if (value === "rebind_cwd") {
    return "rebind_cwd" as const;
  }

  throw new AppError(
    400,
    "unsupported_restore_mode",
    "不支持的恢复模式，请刷新页面后重试。",
  );
}

function clampTimelineLimit(limit: number | undefined) {
  if (typeof limit !== "number" || !Number.isFinite(limit)) {
    return DEFAULT_TIMELINE_PAGE_SIZE;
  }

  return Math.min(Math.max(Math.trunc(limit), 1), MAX_TIMELINE_PAGE_SIZE);
}
