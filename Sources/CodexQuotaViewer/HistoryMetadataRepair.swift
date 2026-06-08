import Foundation
import SQLite3

private let defaultHistoryProvider = "openai"
private let defaultHistoryModel = "gpt-5"
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryMetadataRepairScope: String, Equatable, Sendable {
    case local
    case remote
    case all

    var includesLocal: Bool {
        self == .local || self == .all
    }

    var includesRemote: Bool {
        self == .remote || self == .all
    }
}

struct HistoryModelSettings: Equatable, Sendable {
    let provider: String
    let model: String
}

struct HistoryMetadataRepairSummary: Codable, Equatable, Sendable {
    var dbThreadsSeen: Int
    var dbThreadsUpdated: Int
    var rolloutFilesSeen: Int
    var rolloutFilesUpdated: Int
    var indexRowsSeen: Int
    var indexRowsUpdated: Int
    var malformedJSONLines: Int
    var backupPath: String?

    static let empty = HistoryMetadataRepairSummary(
        dbThreadsSeen: 0,
        dbThreadsUpdated: 0,
        rolloutFilesSeen: 0,
        rolloutFilesUpdated: 0,
        indexRowsSeen: 0,
        indexRowsUpdated: 0,
        malformedJSONLines: 0,
        backupPath: nil
    )

    var changed: Bool {
        dbThreadsUpdated > 0 || rolloutFilesUpdated > 0 || indexRowsUpdated > 0
    }

    static func + (lhs: HistoryMetadataRepairSummary, rhs: HistoryMetadataRepairSummary) -> HistoryMetadataRepairSummary {
        HistoryMetadataRepairSummary(
            dbThreadsSeen: lhs.dbThreadsSeen + rhs.dbThreadsSeen,
            dbThreadsUpdated: lhs.dbThreadsUpdated + rhs.dbThreadsUpdated,
            rolloutFilesSeen: lhs.rolloutFilesSeen + rhs.rolloutFilesSeen,
            rolloutFilesUpdated: lhs.rolloutFilesUpdated + rhs.rolloutFilesUpdated,
            indexRowsSeen: lhs.indexRowsSeen + rhs.indexRowsSeen,
            indexRowsUpdated: lhs.indexRowsUpdated + rhs.indexRowsUpdated,
            malformedJSONLines: lhs.malformedJSONLines + rhs.malformedJSONLines,
            backupPath: lhs.backupPath ?? rhs.backupPath
        )
    }
}

struct LocalHistoryMetadataRepairResult: Equatable {
    let restorePoint: RestorePointManifest
    let summary: HistoryMetadataRepairSummary
}

struct HistoryMetadataRepairOperationResult: Equatable {
    let scope: HistoryMetadataRepairScope
    let localResult: LocalHistoryMetadataRepairResult?
    let remoteResult: RemoteHistoryRepairResult?

    var totalSummary: HistoryMetadataRepairSummary {
        var summary = localResult?.summary ?? .empty
        for target in remoteResult?.targets ?? [] {
            summary = summary + target.summary
        }
        return summary
    }
}

enum HistoryMetadataRepairError: LocalizedError {
    case codexHomeMissing(String)
    case invalidConfig(String)
    case sqliteOpenFailed(String)
    case sqliteQueryFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexHomeMissing(let path):
            return AppLocalization.localized(
                en: "Codex home does not exist: \(path)",
                zh: "Codex 目录不存在：\(path)"
            )
        case .invalidConfig(let path):
            return AppLocalization.localized(
                en: "Config file is not valid UTF-8: \(path)",
                zh: "配置文件不是有效 UTF-8：\(path)"
            )
        case .sqliteOpenFailed(let message):
            return AppLocalization.localized(
                en: "Unable to open Codex history database: \(message)",
                zh: "无法打开 Codex 历史数据库：\(message)"
            )
        case .sqliteQueryFailed(let message):
            return AppLocalization.localized(
                en: "Codex history database query failed: \(message)",
                zh: "Codex 历史数据库查询失败：\(message)"
            )
        }
    }
}

protocol HistoryMetadataRepairing {
    func plannedMutationFiles(store: ProfileStore) throws -> [URL]
    func repair(store: ProfileStore, writer: FileDataWriting) throws -> HistoryMetadataRepairSummary
}

final class HistoryMetadataRepairer: HistoryMetadataRepairing {
    private let fileManager = FileManager.default

    func plannedMutationFiles(store: ProfileStore) throws -> [URL] {
        try deduplicatedStandardizedFileURLs(
            [
                store.currentConfigURL,
                store.stateDatabaseURL,
                store.stateDatabaseWALURL,
                store.stateDatabaseSHMURL,
                store.sessionIndexURL,
            ] + rolloutFiles(in: [store.sessionsRootURL, store.archivedSessionsRootURL])
        )
    }

    func repair(store: ProfileStore, writer: FileDataWriting = DirectFileDataWriter()) throws -> HistoryMetadataRepairSummary {
        guard fileManager.fileExists(atPath: store.codexHomeURL.path) else {
            throw HistoryMetadataRepairError.codexHomeMissing(store.codexHomeURL.path)
        }

        let settings = try loadHistoryModelSettings(configURL: store.currentConfigURL)
        var summary = HistoryMetadataRepairSummary.empty
        try syncStateDatabase(store: store, settings: settings, summary: &summary)
        try syncRolloutFiles(
            in: [store.sessionsRootURL, store.archivedSessionsRootURL],
            settings: settings,
            summary: &summary,
            writer: writer
        )
        try syncSessionIndex(store: store, settings: settings, summary: &summary, writer: writer)
        return summary
    }

    private func loadHistoryModelSettings(configURL: URL) throws -> HistoryModelSettings {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return HistoryModelSettings(provider: defaultHistoryProvider, model: defaultHistoryModel)
        }

        let data = try Data(contentsOf: configURL)
        let document: LightweightTOMLDocument
        do {
            document = try LightweightTOMLDocument(data: data)
        } catch LightweightTOMLDocumentError.invalidUTF8 {
            throw HistoryMetadataRepairError.invalidConfig(configURL.path)
        }

        let defaultsSection = document.section(named: "defaults")
        let provider = firstNonEmptyHistoryValue([
            document.rootAssignmentValue(forKey: "model_provider"),
            document.rootAssignmentValue(forKey: "modelProvider"),
            document.rootAssignmentValue(forKey: "provider"),
            defaultsSection?.assignmentValue(forKey: "model_provider"),
            defaultsSection?.assignmentValue(forKey: "provider"),
        ]) ?? defaultHistoryProvider
        let model = firstNonEmptyHistoryValue([
            document.rootAssignmentValue(forKey: "model"),
            defaultsSection?.assignmentValue(forKey: "model"),
        ]) ?? defaultHistoryModel

        return HistoryModelSettings(provider: provider, model: model)
    }

    private func syncStateDatabase(
        store: ProfileStore,
        settings: HistoryModelSettings,
        summary: inout HistoryMetadataRepairSummary
    ) throws {
        guard fileManager.fileExists(atPath: store.stateDatabaseURL.path) else {
            return
        }

        let database = try HistorySQLiteDatabase(url: store.stateDatabaseURL)
        try database.setBusyTimeout(milliseconds: 30_000)
        let columns = try database.tableColumns("threads")
        guard columns.isSuperset(of: ["id", "model_provider", "model"]) else {
            return
        }

        summary.dbThreadsSeen = try database.intScalar("SELECT COUNT(*) FROM threads")
        summary.dbThreadsUpdated = try database.intScalar(
            "SELECT COUNT(*) FROM threads WHERE model_provider IS NOT ? OR model IS NOT ?",
            bindings: [settings.provider, settings.model]
        )
        guard summary.dbThreadsUpdated > 0 else {
            return
        }

        do {
            try database.execute("BEGIN IMMEDIATE")
            try database.execute(
                "UPDATE threads SET model_provider = ?, model = ? WHERE model_provider IS NOT ? OR model IS NOT ?",
                bindings: [settings.provider, settings.model, settings.provider, settings.model]
            )
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func syncRolloutFiles(
        in roots: [URL],
        settings: HistoryModelSettings,
        summary: inout HistoryMetadataRepairSummary,
        writer: FileDataWriting
    ) throws {
        for fileURL in try rolloutFiles(in: roots) {
            summary.rolloutFilesSeen += 1
            guard let updatedContent = try updatedRolloutContentIfNeeded(fileURL, settings: settings) else {
                continue
            }
            try writer.write(updatedContent, to: fileURL)
            summary.rolloutFilesUpdated += 1
        }
    }

    private func syncSessionIndex(
        store: ProfileStore,
        settings: HistoryModelSettings,
        summary: inout HistoryMetadataRepairSummary,
        writer: FileDataWriting
    ) throws {
        let sessionIndexExists = fileManager.fileExists(atPath: store.sessionIndexURL.path)
        let stateDatabaseExists = fileManager.fileExists(atPath: store.stateDatabaseURL.path)
        guard sessionIndexExists || stateDatabaseExists else {
            return
        }

        let existingText = sessionIndexExists
            ? try String(contentsOf: store.sessionIndexURL, encoding: .utf8)
            : ""
        let existingLines = existingText.components(separatedBy: .newlines)
        var existingEntries: [String: [String: Any]] = [:]
        var existingOrder: [String] = []

        for line in existingLines {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                summary.malformedJSONLines += 1
                continue
            }

            let threadID = stringValue(record["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !threadID.isEmpty else {
                continue
            }

            summary.indexRowsSeen += 1
            existingEntries[threadID] = record
            existingOrder.append(threadID)
        }

        let output: [[String: Any]]
        if let databaseEntries = try readIndexEntriesFromDatabase(
            databaseURL: store.stateDatabaseURL,
            existingEntries: existingEntries
        ) {
            let databaseIDs = Set(databaseEntries.compactMap { stringValue($0["id"]) })
            let indexOnlyEntries = existingOrder
                .filter { !databaseIDs.contains($0) }
                .compactMap { existingEntries[$0] }
            output = (databaseEntries + indexOnlyEntries)
                .map { entry in
                    var next = entry
                    _ = applyHistoryModelFields(to: &next, settings: settings, addMissing: false)
                    return next
                }
                .sorted(by: historyIndexSort)
        } else {
            output = existingOrder.compactMap { threadID in
                guard var record = existingEntries[threadID] else {
                    return nil
                }
                _ = applyHistoryModelFields(to: &record, settings: settings, addMissing: false)
                return record
            }
        }

        let desiredLines = try output.map(jsonLine)
        var desiredText = desiredLines.joined(separator: "\n")
        if !desiredText.isEmpty {
            desiredText += "\n"
        }

        var normalizedExistingText = existingText
        if !normalizedExistingText.isEmpty, !normalizedExistingText.hasSuffix("\n") {
            normalizedExistingText += "\n"
        }

        guard desiredText != normalizedExistingText else {
            return
        }

        summary.indexRowsUpdated = output.count
        try writer.write(Data(desiredText.utf8), to: store.sessionIndexURL)
    }

    private func readIndexEntriesFromDatabase(
        databaseURL: URL,
        existingEntries: [String: [String: Any]]
    ) throws -> [[String: Any]]? {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        let database = try HistorySQLiteDatabase(url: databaseURL, readOnly: true)
        try database.setBusyTimeout(milliseconds: 30_000)
        let columns = try database.tableColumns("threads")
        guard columns.contains("id") else {
            return nil
        }

        var selected = ["id"]
        if columns.contains("title") {
            selected.append("title")
        }
        if columns.contains("updated_at") {
            selected.append("updated_at")
        }
        for column in ["cwd", "git_branch", "git_sha", "git_origin_url", "rollout_path"] where columns.contains(column) {
            selected.append(column)
        }

        let whereSQL = columns.contains("archived") ? "WHERE archived = 0" : ""
        let rows = try database.queryRows(
            "SELECT \(selected.joined(separator: ", ")) FROM threads \(whereSQL) ORDER BY id ASC"
        )

        return rows.compactMap { row in
            guard let threadID = row["id"], !threadID.isEmpty else {
                return nil
            }

            var entry = existingEntries[threadID] ?? [:]
            let title = nonEmpty(row["title"]) ?? threadID
            let updatedAt = row["updated_at"]
                .flatMap(historyISODateString)
                ?? stringValue(entry["updated_at"])
                ?? ""

            entry["id"] = threadID
            if nonEmpty(stringValue(entry["thread_name"])) == nil {
                entry["thread_name"] = title
            }
            entry["updated_at"] = updatedAt
            applyThreadMetadata(to: &entry, row: row)
            return entry
        }
    }

    private func updatedRolloutContentIfNeeded(
        _ fileURL: URL,
        settings: HistoryModelSettings
    ) throws -> Data? {
        let content = try Data(contentsOf: fileURL)
        guard let firstLineRange = content.firstLineRange,
              !content[firstLineRange.line].isEmpty,
              let firstLine = String(data: content[firstLineRange.line], encoding: .utf8),
              var record = try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              stringValue(record["type"]) == "session_meta" else {
            return nil
        }

        let changed: Bool
        if var payload = record["payload"] as? [String: Any] {
            changed = applyHistoryModelFields(to: &payload, settings: settings, addMissing: true)
            record["payload"] = payload
        } else {
            changed = applyHistoryModelFields(to: &record, settings: settings, addMissing: true)
        }

        guard changed else {
            return nil
        }

        let nextFirstLine = try jsonLine(record)
        var next = Data(nextFirstLine.utf8)
        next.append(0x0A)
        next.append(content[firstLineRange.rest])
        return next
    }

    private func rolloutFiles(in roots: [URL]) throws -> [URL] {
        var files: [URL] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                files.append(fileURL.standardizedFileURL)
            }
        }

        return files.sorted { $0.path < $1.path }
    }
}

private final class HistorySQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool = false) throws {
        var database: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) }
                ?? "sqlite3_open_v2 failed with code \(result)"
            if let database {
                sqlite3_close(database)
            }
            throw HistoryMetadataRepairError.sqliteOpenFailed(message)
        }
        handle = database
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func setBusyTimeout(milliseconds: Int32) throws {
        guard sqlite3_busy_timeout(handle, milliseconds) == SQLITE_OK else {
            throw HistoryMetadataRepairError.sqliteQueryFailed(errorMessage)
        }
    }

    func tableColumns(_ tableName: String) throws -> Set<String> {
        let rows = try queryRows("PRAGMA table_info(\(tableName))")
        return Set(rows.compactMap { $0["name"] })
    }

    func intScalar(_ sql: String, bindings: [String] = []) throws -> Int {
        let rows = try queryRows(sql, bindings: bindings)
        guard let firstValue = rows.first?.values.first,
              let value = Int(firstValue) else {
            return 0
        }
        return value
    }

    func execute(_ sql: String, bindings: [String] = []) throws {
        let statement = try prepare(sql)
        defer {
            sqlite3_finalize(statement)
        }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw HistoryMetadataRepairError.sqliteQueryFailed(errorMessage)
        }
    }

    func queryRows(_ sql: String, bindings: [String] = []) throws -> [[String: String]] {
        let statement = try prepare(sql)
        defer {
            sqlite3_finalize(statement)
        }
        try bind(bindings, to: statement)

        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw HistoryMetadataRepairError.sqliteQueryFailed(errorMessage)
            }

            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index) else {
                    continue
                }
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    continue
                }
                if let text = sqlite3_column_text(statement, index) {
                    row[String(cString: name)] = String(cString: text)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private var errorMessage: String {
        guard let handle,
              let message = sqlite3_errmsg(handle) else {
            return "unknown sqlite error"
        }
        return String(cString: message)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw HistoryMetadataRepairError.sqliteQueryFailed(errorMessage)
        }
        return statement
    }

    private func bind(_ values: [String], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let result = sqlite3_bind_text(statement, Int32(index + 1), value, -1, sqliteTransient)
            guard result == SQLITE_OK else {
                throw HistoryMetadataRepairError.sqliteQueryFailed(errorMessage)
            }
        }
    }
}

private func firstNonEmptyHistoryValue(_ values: [String?]) -> String? {
    values.lazy
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        return value
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}

private func applyHistoryModelFields(
    to record: inout [String: Any],
    settings: HistoryModelSettings,
    addMissing: Bool
) -> Bool {
    var changed = false
    let providerKeys = ["model_provider", "modelProvider", "provider"]
    let modelKeys = ["model", "model_name", "modelName"]

    for key in providerKeys where record.keys.contains(key) {
        if stringValue(record[key]) != settings.provider {
            record[key] = settings.provider
            changed = true
        }
    }
    for key in modelKeys where record.keys.contains(key) {
        if stringValue(record[key]) != settings.model {
            record[key] = settings.model
            changed = true
        }
    }

    if addMissing && !providerKeys.contains(where: { record.keys.contains($0) }) {
        record["model_provider"] = settings.provider
        changed = true
    }
    if addMissing && !modelKeys.contains(where: { record.keys.contains($0) }) {
        record["model"] = settings.model
        changed = true
    }
    return changed
}

private func applyThreadMetadata(to entry: inout [String: Any], row: [String: String]) {
    for key in ["cwd", "git_branch", "git_sha", "git_origin_url", "rollout_path"] {
        if let value = nonEmpty(row[key]) {
            entry[key] = value
        }
    }

    var gitMetadata: [String: String] = [:]
    if let value = nonEmpty(entry["git_branch"] as? String) {
        gitMetadata["branch"] = value
    }
    if let value = nonEmpty(entry["git_sha"] as? String) {
        gitMetadata["commit_hash"] = value
    }
    if let value = nonEmpty(entry["git_origin_url"] as? String) {
        gitMetadata["repository_url"] = value
    }

    guard !gitMetadata.isEmpty else {
        return
    }

    var git = entry["git"] as? [String: Any] ?? [:]
    for (key, value) in gitMetadata {
        git[key] = value
    }
    entry["git"] = git
}

private func historyISODateString(from rawValue: String) -> String? {
    guard var timestamp = Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    if timestamp > 10_000_000_000 {
        timestamp /= 1_000
    }
    return makeHistoryISOFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

private func historyIndexSort(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    let leftDate = historyIndexDate(from: stringValue(lhs["updated_at"]))
    let rightDate = historyIndexDate(from: stringValue(rhs["updated_at"]))
    if leftDate != rightDate {
        return leftDate < rightDate
    }
    return (stringValue(lhs["id"]) ?? "") < (stringValue(rhs["id"]) ?? "")
}

private func historyIndexDate(from value: String?) -> Date {
    guard let value,
          let date = makeHistoryISOFormatter().date(from: value) else {
        return Date(timeIntervalSince1970: 0)
    }
    return date
}

private func makeHistoryISOFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}

private func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

private extension Data {
    var firstLineRange: (line: Range<Data.Index>, rest: Range<Data.Index>)? {
        guard !isEmpty else {
            return nil
        }

        if let newlineIndex = firstIndex(of: 0x0A) {
            var lineEnd = newlineIndex
            if lineEnd > startIndex {
                let previous = index(before: lineEnd)
                if self[previous] == 0x0D {
                    lineEnd = previous
                }
            }
            return (startIndex..<lineEnd, index(after: newlineIndex)..<endIndex)
        }

        var lineEnd = endIndex
        if lineEnd > startIndex {
            let previous = index(before: lineEnd)
            if self[previous] == 0x0D {
                lineEnd = previous
            }
        }
        return (startIndex..<lineEnd, endIndex..<endIndex)
    }
}
