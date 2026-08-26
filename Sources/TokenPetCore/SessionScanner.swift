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
    private let desktopStatePath: String
    private let fileManager: FileManager

    public init(
        store: SQLiteStore,
        codexHome: URL,
        threadDatabasePath: String? = nil,
        desktopStatePath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.codexHome = codexHome
        self.threadDatabasePath = threadDatabasePath
            ?? codexHome.appendingPathComponent("state_5.sqlite").path
        self.desktopStatePath = desktopStatePath
            ?? codexHome.appendingPathComponent(".codex-global-state.json").path
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
        let priority = Array(threadMetadata().rolloutPaths.values)
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

    public func indexHistory(
        since: Date,
        maximumFiles: Int = 2_000,
        byteBudget: UInt64 = 512 * 1024 * 1024
    ) throws -> ScanResult {
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let candidates = discoverJSONL(roots: roots)
            .filter { modificationDate($0) >= since }
            .sorted { modificationDate($0) > modificationDate($1) }
        var result = ScanResult()
        for url in candidates.prefix(max(0, maximumFiles)) {
            let size = fileSize(url)
            if result.scannedFiles > 0, result.bytesRead + size > byteBudget { continue }
            result.merge(try scan(urls: [url]))
            if result.bytesRead >= byteBudget { break }
        }
        return result
    }

    public func refresh(activePaths: [String], discoverNew: Bool = true) throws -> ScanResult {
        var candidates = activePaths.map(URL.init(fileURLWithPath:))
        if discoverNew {
            candidates.append(contentsOf: discoverJSONL(roots: [todaySessionsDirectory()]))
            // A Codex task can be resumed days after its rollout file was created.
            // Keep the sidebar-visible rollout paths discoverable so quota and turn
            // updates are not lost when an older task previously fell out of the
            // short-lived active watch set.
            candidates.append(contentsOf: threadMetadata().rolloutPaths.values)
        }
        return try scan(urls: Array(Set(candidates)))
    }

    public func snapshot(limit: Int = 500) throws -> DashboardSnapshot {
        let metadata = threadMetadata()
        let archived = metadata.archived.union(try store.archivedSessionIDs())
        let excluded = archived.union(metadata.internalSubagents)
        let sidebarSessionIDs = Set(metadata.rolloutPaths.keys)
        let sidebarTurns = try store.turns(sessionIDs: sidebarSessionIDs)
        let active = try store.turns(status: .running, limit: 100)
            .filter {
                $0.isSubagent != true &&
                    !excluded.contains($0.sessionID) &&
                    isSnapshotVisible(
                        $0,
                        sidebarSessionIDs: sidebarSessionIDs,
                        desktopStateAvailable: metadata.desktop != nil)
            }
        var recentByID = Dictionary(uniqueKeysWithValues: sidebarTurns.map { ($0.id, $0) })
        for turn in try store.turns(limit: limit) { recentByID[turn.id] = turn }
        let recent = recentByID.values
            .filter {
                $0.isSubagent != true &&
                    !excluded.contains($0.sessionID) &&
                    isSnapshotVisible(
                        $0,
                        sidebarSessionIDs: sidebarSessionIDs,
                        desktopStateAvailable: metadata.desktop != nil)
            }
        return DashboardSnapshot(
            active: active,
            recent: recent,
            sessionTitles: sessionTitles(stateTitles: metadata.titles),
            indexedFiles: try store.indexedFileCount(),
            updatedAt: Date())
    }

    public func economicsTurns(limit: Int = 10_000) throws -> [TurnRecord] {
        let metadata = threadMetadata()
        let visibleSessionIDs = Set(metadata.rolloutPaths.keys).subtracting(metadata.internalSubagents)
        guard !visibleSessionIDs.isEmpty else { return [] }
        return try store.turns(limit: limit).filter {
            $0.isSubagent != true && visibleSessionIDs.contains($0.sessionID)
        }
    }

    public func visibleRolloutPaths(sessionIDs: Set<String>) -> [String: String] {
        threadMetadata().rolloutPaths.reduce(into: [:]) { result, pair in
            if sessionIDs.contains(pair.key) { result[pair.key] = pair.value.path }
        }
    }

    /// Full-history lifecycle expectations used only for Hook diagnostics.
    /// This intentionally reads all indexed turns, including hidden
    /// subagents; the user-facing `snapshot` continues to filter them.
    public func subagentActivityEvidence(limit: Int = 10_000) throws -> (
        latestStartAt: Date?,
        latestStopAt: Date?,
        count: Int
    ) {
        let turns = try store.turns(limit: max(1, limit))
        let dispatches = turns.flatMap { $0.agentDispatches ?? [] }
        let startKeys = Set(dispatches.map { dispatch in
            "\(dispatch.callID ?? dispatch.taskName):\(dispatch.occurredAt.timeIntervalSinceReferenceDate)"
        })
        let latestStartAt = dispatches.map(\.occurredAt).max()
        let latestStopAt = turns
            .filter { $0.isSubagent == true && $0.status != .running }
            .compactMap(\.completedAt)
            .max()
        return (latestStartAt, latestStopAt, startKeys.count)
    }

    /// Derive lifecycle Hook health from the local configuration, the
    /// independent observation ledger, and rollout activity. The caller may
    /// pass the low-frequency `hooks/list` result when available; the local
    /// files remain the fallback so a temporary app-server outage does not
    /// hide a known untrusted state.
    public func subagentHookHealth(
        appServerHooks: [CodexHookMetadata] = [],
        now: Date = Date()
    ) throws -> SubagentHookHealthSnapshot {
        let configurations = SubagentHookConfigurationInspector.inspect(
            hooksFile: codexHome.appendingPathComponent("hooks.json"),
            configFile: codexHome.appendingPathComponent("config.toml"),
            appServerHooks: appServerHooks,
            now: now)
        let observations = try store.subagentHookObservations(limit: 5_000)
        let latestStart = observations.first(where: {
            $0.event == .start && $0.outcome == .parsed
        })?.observedAt
        let latestStop = observations.first(where: {
            $0.event == .stop && $0.outcome == .parsed
        })?.observedAt
        let activity = try subagentActivityEvidence()
        let startConfiguration = configurations.first(where: { $0.event == .start }) ??
            SubagentHookConfiguration(
                event: .start,
                installed: false,
                enabled: false,
                trusted: false,
                trustStatus: nil,
                command: nil,
                currentHash: nil,
                configSectionFound: false,
                trustConfiguredAt: nil,
                inspectedAt: now)
        let stopConfiguration = configurations.first(where: { $0.event == .stop }) ??
            SubagentHookConfiguration(
                event: .stop,
                installed: false,
                enabled: false,
                trusted: false,
                trustStatus: nil,
                command: nil,
                currentHash: nil,
                configSectionFound: false,
                trustConfiguredAt: nil,
                inspectedAt: now)
        let start = SubagentHookHealth.evaluate(
            configuration: startConfiguration,
            latestObservationAt: latestStart,
            latestSubagentActivityAt: activity.latestStartAt,
            now: now)
        let stop = SubagentHookHealth.evaluate(
            configuration: stopConfiguration,
            latestObservationAt: latestStop,
            latestSubagentActivityAt: activity.latestStopAt,
            now: now)
        return SubagentHookHealthSnapshot(
            start: start,
            stop: stop,
            subagentActivityCount: activity.count,
            observedAt: now)
    }

    public func recordShadowCompletions(
        from previous: DashboardSnapshot,
        to next: DashboardSnapshot
    ) throws {
        let previouslyRunning = Set(previous.active.map(\.id))
        guard !previouslyRunning.isEmpty else {
            try store.reconcilePendingHandoffCosts()
            return
        }
        let profile = try store.loadRoutingPreferenceProfile()
        let newlyTerminal = next.recent.filter {
            $0.status != .running && previouslyRunning.contains($0.id)
        }
        try recordRoutingOutcomes(from: newlyTerminal, routingPreferenceProfile: profile)
        try recordExecutionWasteObservations(from: newlyTerminal)
        let sessionsByID = Dictionary(uniqueKeysWithValues: next.sessions.map { ($0.sessionID, $0) })
        let newlyCompleted = newlyTerminal.filter { $0.status == .completed }
        for turn in newlyCompleted {
            guard let session = sessionsByID[turn.sessionID],
                  let decision = HandoffShadowPolicy.evaluate(session: session, completedTurn: turn)
            else { continue }
            try store.recordShadowCompletion(decision: decision, completedTurn: turn)
        }
        try store.reconcilePendingHandoffCosts()
    }

    public func backfillRoutingOutcomes(limit: Int = 10_000) throws {
        try recordRoutingOutcomes(
            from: economicsTurns(limit: limit),
            routingPreferenceProfile: try store.loadRoutingPreferenceProfile())
    }

    public func backfillExecutionWasteObservations(limit: Int = 10_000) throws {
        try recordExecutionWasteObservations(from: economicsTurns(limit: limit))
    }

    public func recordRoutingOutcomes(
        from turns: [TurnRecord],
        routingPreferenceProfile: RoutingPreferenceProfile?
    ) throws {
        for turn in turns {
            if let observation = RoutingOutcomeObservation.derive(
                from: turn,
                routingPreferenceProfile: routingPreferenceProfile) {
                try store.upsertRoutingOutcome(observation)
            }
        }
    }

    public func recordExecutionWasteObservations(from turns: [TurnRecord]) throws {
        for turn in turns {
            if let observation = ExecutionWasteObservation.derive(from: turn) {
                try store.upsertExecutionWasteObservation(observation)
            }
        }
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

        if cursor.state.classificationVersion != RolloutState.currentClassificationVersion {
            if let sessionID = cursor.state.sessionID { try store.deleteTurns(sessionID: sessionID) }
            cursor = FileCursor(identity: identity, path: url.path)
            let classification = sessionClassification(in: url)
            cursor.state.sessionID = classification.sessionID ?? cursor.state.sessionID
            if let cwd = classification.cwd, !cwd.isEmpty { cursor.state.cwd = cwd }
            cursor.state.parentThreadID = classification.parentThreadID
            cursor.state.isSubagent = classification.isSubagent
            cursor.state.agentPath = classification.agentPath
            cursor.state.classificationVersion = RolloutState.currentClassificationVersion
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
        sessionID: String?, cwd: String?, parentThreadID: String?, isSubagent: Bool, agentPath: String?
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil, nil, false, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1024) else { return (nil, nil, nil, false, nil) }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: Data(#""type":"session_meta""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            let parent = payload["parent_thread_id"] as? String
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            return (
                payload["id"] as? String,
                payload["cwd"] as? String,
                parent,
                source?["subagent"] != nil,
                spawn?["agent_path"] as? String)
        }
        return (nil, nil, nil, false, nil)
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
                  let raw = payload["rate_limits"] as? [String: Any],
                  QuotaSnapshot.isValid(raw: raw)
            else { continue }
            let observedAt = (object["timestamp"] as? String).flatMap(Self.parseTimestamp)
            return QuotaSnapshot(raw: raw, observedAt: observedAt)
        }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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

    private struct DesktopSidebarState {
        var visibleThreadIDs: Set<String>
        var projectRoots: [String]
    }

    private func desktopSidebarState() -> DesktopSidebarState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: desktopStatePath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["local-projects"] as? [String: Any]
        else { return nil }

        let validProjectIDs = Set(projects.keys)
        let roots = projects.values.flatMap { raw -> [String] in
            guard let project = raw as? [String: Any] else { return [] }
            return project["rootPaths"] as? [String] ?? []
        }
        var visible = Set(object["projectless-thread-ids"] as? [String] ?? [])
        visible.formUnion(object["pinned-thread-ids"] as? [String] ?? [])
        if let assignments = object["thread-project-assignments"] as? [String: Any] {
            for (threadID, raw) in assignments {
                guard let assignment = raw as? [String: Any],
                      assignment["projectKind"] as? String == "local",
                      let projectID = assignment["projectId"] as? String,
                      validProjectIDs.contains(projectID)
                else { continue }
                visible.insert(threadID)
            }
        }
        return DesktopSidebarState(visibleThreadIDs: visible, projectRoots: roots)
    }

    private func isSnapshotVisible(
        _ turn: TurnRecord,
        sidebarSessionIDs: Set<String>,
        desktopStateAvailable: Bool
    ) -> Bool {
        // Without Codex Desktop's state file there is no sidebar fact source;
        // preserve the scanner's historical local-only behavior.
        guard desktopStateAvailable else { return true }
        if sidebarSessionIDs.contains(turn.sessionID) { return true }
        // Desktop can persist a new assignment just after the rollout starts.
        // Preserve only a genuinely fresh running task during that short lag.
        guard turn.status == .running, let activity = turn.lastActivityAt else { return false }
        return Date().timeIntervalSince(activity) < 5 * 60
    }

    private func isDesktopSidebarThread(
        threadID: String,
        cwd: String,
        hasPreview: Bool,
        desktop: DesktopSidebarState?
    ) -> Bool {
        guard let desktop else { return true }
        if desktop.visibleThreadIDs.contains(threadID) { return true }
        // Desktop's normal project view also groups top-level threads by their
        // CWD. `preview` is the database's visible-thread marker; without it,
        // old rollouts can retain a matching CWD after leaving the sidebar.
        if hasPreview, belongsToDesktopProject(cwd, projectRoots: desktop.projectRoots) { return true }
        // Codex also shows normal continuation tasks that run inside its
        // managed worktrees. They have no database preview, so recognize only
        // a worktree whose repository name maps back to a visible project.
        return isManagedWorktree(ofVisibleProject: cwd, projectRoots: desktop.projectRoots)
    }

    private func belongsToDesktopProject(_ cwd: String, projectRoots: [String]) -> Bool {
        let standardizedCWD = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return projectRoots.contains { root in
            let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            return standardizedCWD == standardizedRoot || standardizedCWD.hasPrefix(standardizedRoot + "/")
        }
    }

    private func isManagedWorktree(ofVisibleProject cwd: String, projectRoots: [String]) -> Bool {
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        let components = url.pathComponents
        guard let worktreesIndex = components.lastIndex(of: "worktrees"),
              components.indices.contains(worktreesIndex - 1),
              components[worktreesIndex - 1] == ".codex",
              components.count > worktreesIndex + 2
        else { return false }
        let repositoryName = components[worktreesIndex + 2]
        return projectRoots.contains {
            URL(fileURLWithPath: $0).standardizedFileURL.lastPathComponent == repositoryName
        }
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
        internalSubagents: Set<String>,
        rolloutPaths: [String: URL],
        desktop: DesktopSidebarState?
    ) {
        let desktop = desktopSidebarState()
        var database: OpaquePointer?
        guard sqlite3_open_v2(threadDatabasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            return ([:], [], [], [:], desktop)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let previewSQL = "SELECT id, title, archived, source, rollout_path, thread_source, cwd, preview FROM threads"
        let legacySQL = "SELECT id, title, archived, source, rollout_path, thread_source, cwd FROM threads"
        let supportsPreview = sqlite3_prepare_v2(database, previewSQL, -1, &statement, nil) == SQLITE_OK
        if !supportsPreview {
            if statement != nil { sqlite3_finalize(statement) }
            statement = nil
            guard sqlite3_prepare_v2(database, legacySQL, -1, &statement, nil) == SQLITE_OK else {
                return ([:], [], [], [:], desktop)
            }
        }
        guard let statement else { return ([:], [], [], [:], desktop) }
        defer { sqlite3_finalize(statement) }

        var titles: [String: String] = [:]
        var archived = Set<String>()
        var internalSubagents = Set<String>()
        var rolloutPaths: [String: URL] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idPointer)
            let title = sqlite3_column_text(statement, 1)
                .map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if !title.isEmpty { titles[id] = title }
            if sqlite3_column_int(statement, 2) != 0 { archived.insert(id) }
            if let sourcePointer = sqlite3_column_text(statement, 3) {
                let source = String(cString: sourcePointer)
                if source == "subagent" || source == "exec" {
                    internalSubagents.insert(id)
                } else if let data = source.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["subagent"] != nil
                {
                    internalSubagents.insert(id)
                }
            }
            let threadSource = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
            if threadSource.caseInsensitiveCompare("subagent") == .orderedSame,
               title.hasPrefix("<codex_delegation>") {
                // Keep delegated tasks when Desktop presents them as a normal
                // task; omit only its implementation wrapper entry.
                internalSubagents.insert(id)
            }
            let cwd = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            let hasPreview = supportsPreview && (sqlite3_column_text(statement, 7)
                .map { !String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
            if !archived.contains(id), !internalSubagents.contains(id),
               titles[id] != nil,
               isDesktopSidebarThread(
                threadID: id,
                cwd: cwd,
                hasPreview: hasPreview,
                desktop: desktop),
               let pathPointer = sqlite3_column_text(statement, 4)
            {
                let path = String(cString: pathPointer)
                if !path.isEmpty { rolloutPaths[id] = URL(fileURLWithPath: path) }
            }
        }
        return (titles, archived, internalSubagents, rolloutPaths, desktop)
    }
}
