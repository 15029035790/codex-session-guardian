import CSQLite3
import Foundation

public struct ScanResult: Sendable {
    public var scannedFiles = 0
    public var bytesRead: UInt64 = 0
    public var changedTurns = 0
    public var activePaths: [String] = []

    mutating func merge(_ other: Self) {
        scannedFiles += other.scannedFiles
        bytesRead += other.bytesRead
        changedTurns += other.changedTurns
        activePaths.append(contentsOf: other.activePaths)
    }
}

public final class SessionScanner: @unchecked Sendable {
    public let store: SQLiteStore
    public let codexHome: URL
    private let threadDatabasePath: String
    private let fileManager: FileManager

    public init(
        store: SQLiteStore,
        codexHome: URL,
        threadDatabasePath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.codexHome = codexHome
        self.threadDatabasePath = threadDatabasePath
            ?? codexHome.appendingPathComponent("state_5.sqlite").path
        self.fileManager = fileManager
    }

    public static func defaultCodexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func defaultDatabasePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let directory = environment["TOKEN_PET_DATA_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("token-pet.sqlite").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenPet", isDirectory: true)
            .appendingPathComponent("token-pet.sqlite").path
    }

    public func initialIndex() throws -> ScanResult {
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let discovered = discoverJSONL(roots: roots).sorted { modificationDate($0) > modificationDate($1) }
        let priority = threadMetadata().rolloutPaths
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { modificationDate($0) > modificationDate($1) }
        let priorityPaths = Set(priority.map(\.path))
        let all = priority + discovered.filter { !priorityPaths.contains($0.path) }
        let byteBudget: UInt64 = 256 * 1024 * 1024
        let minimumFiles = min(20, all.count)
        let maximumFiles = min(max(100, priority.count), all.count)
        var result = ScanResult()
        var available = try store.nonRunningTurnCount(limit: 50)
        for url in all {
            if result.scannedFiles >= maximumFiles { break }
            let size = fileSize(url)
            let isPriority = priorityPaths.contains(url.path)
            if !isPriority && result.scannedFiles >= minimumFiles && result.bytesRead + size > byteBudget { continue }
            result.merge(try scan(urls: [url]))
            available = try store.nonRunningTurnCount(limit: 50)
            if !isPriority && result.scannedFiles >= minimumFiles && available >= 50 { break }
        }
        return result
    }

    public func refresh(activePaths: [String], discoverNew: Bool = true) throws -> ScanResult {
        var candidates = activePaths.map(URL.init(fileURLWithPath:))
        if discoverNew {
            candidates.append(contentsOf: discoverJSONL(roots: [todaySessionsDirectory()]))
        }
        return try scan(urls: Array(Set(candidates)))
    }

    public func snapshot(limit: Int = 500) throws -> DashboardSnapshot {
        let metadata = threadMetadata()
        let archived = metadata.archived.union(try store.archivedSessionIDs())
        let excluded = archived.union(metadata.subagents)
        let active = try store.turns(status: .running, limit: 100)
            .filter { !excluded.contains($0.sessionID) }
        let recent = try store.turns(limit: limit)
            .filter { !excluded.contains($0.sessionID) }
        return DashboardSnapshot(
            active: active,
            recent: recent,
            sessionTitles: sessionTitles(stateTitles: metadata.titles),
            indexedFiles: try store.indexedFileCount(),
            updatedAt: Date())
    }

    public func scan(urls: [URL]) throws -> ScanResult {
        var result = ScanResult()
        for url in urls where url.pathExtension == "jsonl" && fileManager.fileExists(atPath: url.path) {
            let outcome = try scanFile(url)
            result.scannedFiles += 1
            result.bytesRead += outcome.bytesRead
            result.changedTurns += outcome.changedTurns
            if outcome.active { result.activePaths.append(url.path) }
        }
        return result
    }

    public func discoverJSONL(roots: [URL]) -> [URL] {
        var urls: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                urls.append(url)
            }
        }
        return urls
    }

    public func todaySessionsDirectory(now: Date = Date(), calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return codexHome.appendingPathComponent(
            String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            isDirectory: true)
    }

    private func scanFile(_ url: URL) throws -> (bytesRead: UInt64, changedTurns: Int, active: Bool) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let identity = "\(device):\(inode)"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
        let archived = url.path.contains("/archived_sessions/")
        let stale = modifiedAt < Date().addingTimeInterval(-15 * 60)
        var cursor = try store.loadCursor(identity: identity) ?? FileCursor(identity: identity, path: url.path)
        let pathChanged = cursor.path != url.path

        if size < cursor.offset {
            if let sessionID = cursor.state.sessionID { try store.deleteTurns(sessionID: sessionID) }
            cursor = FileCursor(identity: identity, path: url.path)
        }
        cursor.path = url.path

        if cursor.state.classificationVersion != 1 {
            let classification = sessionClassification(in: url)
            cursor.state.sessionID = classification.sessionID ?? cursor.state.sessionID
            if let cwd = classification.cwd, !cwd.isEmpty { cursor.state.cwd = cwd }
            cursor.state.parentThreadID = classification.parentThreadID
            cursor.state.isSubagent = classification.isSubagent
            cursor.state.classificationVersion = 1
        }

        if cursor.state.isSubagent == true {
            if let sessionID = cursor.state.sessionID { try store.deleteTurns(sessionID: sessionID) }
            cursor.state.active = nil
            cursor.offset = size
            cursor.remainder = Data()
            try store.save(cursor: cursor)
            return (0, 0, false)
        }

        if cursor.state.latestQuota == nil, let quota = latestQuota(in: url, size: size) {
            cursor.state.latestQuota = quota
            cursor.state.active?.quota = quota
            if let active = cursor.state.active { try store.upsert(turn: active) }
            try store.save(cursor: cursor)
        }

        if size == cursor.offset && !pathChanged {
            return (0, 0, cursor.state.active != nil && !stale)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        var remainder = cursor.remainder
        var bytesRead: UInt64 = 0
        var changed = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            bytesRead += UInt64(chunk.count)
            cursor.offset += UInt64(chunk.count)
            var buffer = remainder
            buffer.append(chunk)
            guard let newline = buffer.lastIndex(of: 0x0A) else {
                remainder = buffer
                continue
            }
            let complete = Data(buffer.prefix(through: newline))
            remainder = Data(buffer.suffix(from: buffer.index(after: newline)))
            try autoreleasepool {
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if let turn = cursor.state.process(line: Data(line)) {
                        try store.upsert(turn: turn)
                        changed += 1
                    }
                }
            }
        }
        cursor.remainder = remainder
        if var unfinished = cursor.state.active, archived || stale {
            unfinished.status = .interrupted
            unfinished.completedAt = modifiedAt
            unfinished.confidence = archived ? "interrupted-archived" : "interrupted-stale-log"
            try store.upsert(turn: unfinished)
            if archived { cursor.state.active = nil }
        }
        try store.save(cursor: cursor)
        return (bytesRead, changed, cursor.state.active != nil && !stale)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func fileSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func sessionClassification(in url: URL) -> (
        sessionID: String?, cwd: String?, parentThreadID: String?, isSubagent: Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil, false) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1024) else { return (nil, nil, nil, false) }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: Data(#""type":"session_meta""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            let parent = payload["parent_thread_id"] as? String
            let source = payload["source"] as? [String: Any]
            return (
                payload["id"] as? String,
                payload["cwd"] as? String,
                parent,
                source?["subagent"] != nil)
        }
        return (nil, nil, nil, false)
    }

    private func latestQuota(in url: URL, size: UInt64) -> QuotaSnapshot? {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let tailSize = min(size, 2 * 1_048_576)
        try? handle.seek(toOffset: size - tailSize)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard line.range(of: Data(#""rate_limits""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let raw = payload["rate_limits"] as? [String: Any]
            else { continue }
            return QuotaSnapshot(raw: raw)
        }
        return nil
    }

    private func sessionTitles(stateTitles: [String: String]) -> [String: String] {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        var titles = stateTitles
        if let data = try? Data(contentsOf: index) {
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = object["id"] as? String,
                    let title = object["thread_name"] as? String,
                    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                titles[id] = title
            }
        }
        return titles.mapValues(Self.displayTitle)
    }

    private static func displayTitle(_ rawTitle: String) -> String {
        var source = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = source.range(of: "<input>"),
           let end = source.range(of: "</input>", range: start.upperBound..<source.endIndex)
        {
            source = String(source[start.upperBound..<end.lowerBound])
        }
        let ignoredPrefixes = [
            "<codex_delegation", "<source_thread_id", "</", "# Files mentioned",
            "## My request", "The following is the Codex agent history",
        ]
        for rawLine in source.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !ignoredPrefixes.contains(where: line.hasPrefix) else { continue }
            line = line.replacingOccurrences(
                of: #"^(?:[-*]|\d+[.)])\s+"#,
                with: "",
                options: .regularExpression)
            if !line.isEmpty { return line }
        }
        return "Codex session"
    }

    private func threadMetadata() -> (
        titles: [String: String],
        archived: Set<String>,
        subagents: Set<String>,
        rolloutPaths: [URL]
    ) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(threadDatabasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            return ([:], [], [], [])
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, title, archived, source, rollout_path, thread_source FROM threads",
            -1,
            &statement,
            nil) == SQLITE_OK,
              let statement
        else { return ([:], [], [], []) }
        defer { sqlite3_finalize(statement) }

        var titles: [String: String] = [:]
        var archived = Set<String>()
        var subagents = Set<String>()
        var rolloutPaths: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idPointer)
            if let titlePointer = sqlite3_column_text(statement, 1) {
                let title = String(cString: titlePointer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { titles[id] = title }
            }
            if sqlite3_column_int(statement, 2) != 0 { archived.insert(id) }
            if let sourcePointer = sqlite3_column_text(statement, 3) {
                let source = String(cString: sourcePointer)
                if source == "subagent" {
                    subagents.insert(id)
                } else if let data = source.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["subagent"] != nil
                {
                    subagents.insert(id)
                }
            }
            if let threadSourcePointer = sqlite3_column_text(statement, 5),
               String(cString: threadSourcePointer) == "subagent"
            {
                subagents.insert(id)
            }
            if !archived.contains(id), !subagents.contains(id), titles[id] != nil,
               let pathPointer = sqlite3_column_text(statement, 4)
            {
                let path = String(cString: pathPointer)
                if !path.isEmpty { rolloutPaths.append(URL(fileURLWithPath: path)) }
            }
        }
        return (titles, archived, subagents, rolloutPaths)
    }
}
