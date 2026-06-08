import Foundation
import Testing

@testable import CodexQuotaViewer

@Test
func historyMetadataRepairerUpdatesDatabaseRolloutsAndSessionIndex() throws {
    let harness = try makeHarness()
    defer {
        try? FileManager.default.removeItem(at: harness.homeURL.deletingLastPathComponent())
    }
    let store = ProfileStore(
        baseURL: harness.appSupportURL,
        currentAuthURL: harness.codexHomeURL.appendingPathComponent("auth.json"),
        homeDirectoryOverride: harness.homeURL
    )
    try FileManager.default.createDirectory(at: store.codexHomeURL, withIntermediateDirectories: true)
    try Data("model_provider = \"openai\"\nmodel = \"gpt-5.1-codex\"\n".utf8)
        .write(to: store.currentConfigURL, options: .atomic)
    let rolloutURL = try writeHistoryRepairRollout(
        root: store.sessionsRootURL,
        id: "session-1",
        provider: "legacy",
        model: "old-model"
    )
    try Data(
        """
        {"id":"session-1","thread_name":"Existing Name","model_provider":"legacy","model":"old-model","custom_field":"keep-me","git":{"dirty":true}}
        """.utf8
    )
    .write(to: store.sessionIndexURL, options: .atomic)
    try runHistorySQLite(
        store.stateDatabaseURL,
        """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY,
          title TEXT,
          updated_at INTEGER,
          archived INTEGER,
          model_provider TEXT,
          model TEXT,
          cwd TEXT,
          git_branch TEXT,
          git_sha TEXT,
          git_origin_url TEXT,
          rollout_path TEXT
        );
        INSERT INTO threads VALUES (
          'session-1',
          'Database Name',
          1760000000,
          0,
          'legacy',
          'old-model',
          '/repo/codex-history-sync',
          'main',
          'abc123',
          'git@gitee.com:duke/codex-history-sync.git',
          'sessions/2026/05/13/rollout-session-1.jsonl'
        );
        """
    )

    let summary = try HistoryMetadataRepairer().repair(store: store, writer: DirectFileDataWriter())

    #expect(summary.dbThreadsSeen == 1)
    #expect(summary.dbThreadsUpdated == 1)
    #expect(summary.rolloutFilesSeen == 1)
    #expect(summary.rolloutFilesUpdated == 1)
    #expect(summary.indexRowsSeen == 1)
    #expect(summary.indexRowsUpdated == 1)
    #expect(
        try runHistorySQLite(
            store.stateDatabaseURL,
            "SELECT model_provider || '\t' || model FROM threads WHERE id = 'session-1';"
        )
        .trimmingCharacters(in: .whitespacesAndNewlines) == "openai\tgpt-5.1-codex"
    )

    let rolloutPayload = try historyRepairFirstPayload(from: rolloutURL)
    #expect(rolloutPayload["model_provider"] as? String == "openai")
    #expect(rolloutPayload["model"] as? String == "gpt-5.1-codex")

    let indexObject = try historyRepairFirstObject(from: store.sessionIndexURL)
    let index = try #require(indexObject)
    #expect(index["thread_name"] as? String == "Existing Name")
    #expect(index["custom_field"] as? String == "keep-me")
    #expect(index["model_provider"] as? String == "openai")
    #expect(index["model"] as? String == "gpt-5.1-codex")
    #expect(index["cwd"] as? String == "/repo/codex-history-sync")
    let git = try #require(index["git"] as? [String: Any])
    #expect(git["dirty"] as? Bool == true)
    #expect(git["branch"] as? String == "main")
    #expect(git["commit_hash"] as? String == "abc123")
    #expect(git["repository_url"] as? String == "git@gitee.com:duke/codex-history-sync.git")
}

private func writeHistoryRepairRollout(
    root: URL,
    id: String,
    provider: String,
    model: String
) throws -> URL {
    let folder = root
        .appendingPathComponent("2026", isDirectory: true)
        .appendingPathComponent("05", isDirectory: true)
        .appendingPathComponent("13", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileURL = folder.appendingPathComponent("rollout-\(id).jsonl", isDirectory: false)
    try Data(
        """
        {"type":"session_meta","id":"\(id)","payload":{"model_provider":"\(provider)","model":"\(model)"}}
        {"type":"event_msg","payload":{"message":"keep me"}}
        """.utf8
    )
    .write(to: fileURL, options: .atomic)
    return fileURL
}

private func historyRepairFirstPayload(from fileURL: URL) throws -> [String: Any] {
    let firstObject = try historyRepairFirstObject(from: fileURL)
    let object = try #require(firstObject)
    return try #require(object["payload"] as? [String: Any])
}

private func historyRepairFirstObject(from fileURL: URL) throws -> [String: Any]? {
    guard let firstLine = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n")
        .first else {
        return nil
    }
    return try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any]
}

@discardableResult
private func runHistorySQLite(_ databaseURL: URL, _ sql: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = stderr.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "HistoryMetadataRepairTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(data: error, encoding: .utf8) ?? "sqlite failed"]
        )
    }
    return String(data: output, encoding: .utf8) ?? ""
}
