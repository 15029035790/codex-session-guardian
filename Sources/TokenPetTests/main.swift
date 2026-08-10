import Foundation
import TokenPetCore

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case let .assertion(value): return value }
    }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else { throw TestFailure.assertion("\(label): expected \(expected), got \(actual)") }
}

func testAggregation() throws {
    var state = RolloutState()
    _ = state.process(line: event(type: "session_meta", payload: ["id": "s1", "cwd": "/project-a"]))
    _ = state.process(line: event(type: "event_msg", payload: ["type": "task_started", "turn_id": "t1"]))
    _ = state.process(line: token(total: usage(100, 60, 10), last: usage(100, 60, 10)))
    let turn = state.process(line: token(total: usage(250, 160, 30), last: usage(150, 100, 20)))!
    try expect(turn.calls, 2, "provider calls")
    try expect(turn.usage.input, 250, "total input")
    try expect(turn.usage.cachedInput, 160, "cached subset")
    try expect(turn.usage.uncachedInput, 90, "uncached input")
    try expect(turn.usage.total, 280, "provider total")
    try expect(turn.quota?.remainingPercent, 75, "remaining quota")
    try expect(QuotaSnapshot(raw: ["primary": ["used_percent": 59.9]]).level, .healthy, "quota healthy boundary")
    try expect(QuotaSnapshot(raw: ["primary": ["used_percent": 60.0]]).level, .caution, "quota caution boundary")
    try expect(QuotaSnapshot(raw: ["primary": ["used_percent": 80.0]]).level, .critical, "quota critical boundary")
}

func testDuplicateAndReset() throws {
    var state = RolloutState()
    _ = state.process(line: event(type: "session_meta", payload: ["id": "s1", "cwd": "/p"]))
    _ = state.process(line: event(type: "event_msg", payload: ["type": "task_started"]))
    let value = token(total: usage(100, 50, 10), last: usage(100, 50, 10))
    _ = state.process(line: value)
    let duplicate = state.process(line: value)!
    try expect(duplicate.calls, 1, "duplicate call count")
    try expect(duplicate.usage.total, 110, "duplicate total")

    var resetState = RolloutState()
    _ = resetState.process(line: event(type: "session_meta", payload: ["id": "r", "cwd": "/p"]))
    _ = resetState.process(line: token(total: usage(500, 400, 20), last: usage(500, 400, 20)))
    _ = resetState.process(line: event(type: "event_msg", payload: ["type": "task_started"]))
    let reset = resetState.process(line: token(total: usage(50, 10, 5), last: usage(50, 10, 5)))!
    try expect(reset.usage.input, 50, "reset epoch input")
}

func testRiskAndBoundaries() throws {
    var state = RolloutState()
    _ = state.process(line: event(type: "session_meta", payload: ["id": "s1", "cwd": "/p"]))
    _ = state.process(line: event(type: "event_msg", payload: ["type": "task_started", "turn_id": "t1"]))
    let turn = state.process(line: token(total: usage(850, 800, 10), last: usage(850, 800, 10), window: 1_000))!
    try expect(turn.risk, .red, "risk")
    try expect(turn.contextPressure, 0.85, "context pressure")
    let completed = state.process(line: event(type: "event_msg", payload: ["type": "task_complete"]))!
    try expect(completed.status, .completed, "completion")
    try expect(state.active == nil, true, "active cleared")
}

func testIncrementalAndArchive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions/2026/08/09")
    let archive = home.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let log = sessions.appendingPathComponent("rollout-s1.jsonl")
    let initial = [
        event(type: "session_meta", payload: ["id": "s1", "cwd": "/project-a"]),
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "t1"]),
        token(total: usage(100, 50, 10), last: usage(100, 50, 10)),
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try Data(initial.utf8).write(to: log)
    let store = try SQLiteStore(path: root.appendingPathComponent("index.sqlite").path)
    let scanner = SessionScanner(store: store, codexHome: home)
    let first = try scanner.initialIndex()
    try expect(first.bytesRead, UInt64(initial.utf8.count), "initial bytes")
    try expect(try scanner.snapshot().active.first!.usage.total, 110, "initial total")

    let next = String(decoding: token(total: usage(250, 150, 25), last: usage(150, 100, 15)), as: UTF8.self)
    let split = next.index(next.startIndex, offsetBy: next.count / 2)
    try append(String(next[..<split]), to: log)
    _ = try scanner.refresh(activePaths: [log.path])
    try expect(try scanner.snapshot().active.first!.usage.total, 110, "partial line ignored")
    try append(String(next[split...]) + "\n" + String(decoding: event(type: "event_msg", payload: ["type": "task_complete"]), as: UTF8.self) + "\n", to: log)
    let completionRefresh = try scanner.refresh(activePaths: [log.path])
    let completed = try scanner.snapshot().recent.first!
    try expect(completionRefresh.activePaths.isEmpty, true, "completed rollout clears active watch set")
    try expect(try scanner.snapshot().active.isEmpty, true, "completion removes executing state immediately")
    try expect(completed.status, TurnStatus.completed, "incremental completion")
    try expect(completed.usage.input, 250, "incremental input")
    try expect(completed.usage.uncachedInput, 100, "incremental uncached")

    let archived = archive.appendingPathComponent(log.lastPathComponent)
    try FileManager.default.moveItem(at: log, to: archived)
    let count = try store.indexedFileCount()
    let moved = try scanner.initialIndex()
    try expect(moved.bytesRead, 0, "archive move no reread")
    try expect(try store.indexedFileCount(), count, "archive inode dedupe")
    try expect(try scanner.snapshot().recent.filter { $0.sessionID == "s1" }.count, 0, "archived session filtered")
}

func testProjectIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    for (id, cwd, input) in [("a", "/project-a", 10), ("b", "/project-b", 20)] {
        let content = [
            event(type: "session_meta", payload: ["id": id, "cwd": cwd]),
            event(type: "event_msg", payload: ["type": "task_started"]),
            token(total: usage(input, 0, 1), last: usage(input, 0, 1)),
        ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: sessions.appendingPathComponent("\(id).jsonl"))
    }
    let titleIndex = [
        "{\"id\":\"a\",\"thread_name\":\"<codex_delegation>\\n<input>继续改造 TokenPet 会话健康面板。\\n第二行说明</input>\\n</codex_delegation>\",\"updated_at\":\"2026-08-09T09:00:00Z\"}",
        "{\"id\":\"b\",\"thread_name\":\"任务 B\",\"updated_at\":\"2026-08-09T09:00:00Z\"}",
    ].joined(separator: "\n") + "\n"
    try Data(titleIndex.utf8).write(to: home.appendingPathComponent("session_index.jsonl"))
    let store = try SQLiteStore(path: root.appendingPathComponent("index.sqlite").path)
    let scanner = SessionScanner(store: store, codexHome: home)
    _ = try scanner.initialIndex()
    let active = try scanner.snapshot().active
    try expect(Set(active.map(\.cwd)), Set(["/project-a", "/project-b"]), "project cwd isolation")
    try expect(Set(active.map(\.sessionID)), Set(["a", "b"]), "session isolation")
    let snapshot = try scanner.snapshot()
    try expect(snapshot.sessionTitles["a"], "继续改造 TokenPet 会话健康面板。", "delegation title cleanup")
    try expect(snapshot.sessions.first?.turns.count, 1, "session grouping")
}

func testSubagentFilteringAndMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let topLog = sessions.appendingPathComponent("top.jsonl")
    let topContent = [
        event(type: "session_meta", payload: ["id": "top", "cwd": "/project"]),
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "top-turn"]),
        token(total: usage(100, 20, 5), last: usage(100, 20, 5)),
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try Data(topContent.utf8).write(to: topLog)

    let userChildLog = sessions.appendingPathComponent("user-child.jsonl")
    let userChildContent = [
        event(type: "session_meta", payload: [
            "id": "user-child", "cwd": "/project", "parent_thread_id": "top",
        ]),
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "child-turn"]),
        token(total: usage(150, 30, 6), last: usage(150, 30, 6)),
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try Data(userChildContent.utf8).write(to: userChildLog)

    let subLog = sessions.appendingPathComponent("sub.jsonl")
    let subContent = [
        event(type: "session_meta", payload: [
            "id": "sub", "cwd": "/project", "parent_thread_id": "top",
            "source": ["subagent": ["other": "guardian"]],
        ]),
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "sub-turn"]),
        token(total: usage(200, 40, 8), last: usage(200, 40, 8)),
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try Data(subContent.utf8).write(to: subLog)

    let store = try SQLiteStore(path: root.appendingPathComponent("index.sqlite").path)
    var legacyTurn = TurnRecord(
        sessionID: "sub", turnID: "legacy", ordinal: 1, cwd: "/project", startedAt: Date())
    legacyTurn.status = .completed
    try store.upsert(turn: legacyTurn)
    let attributes = try FileManager.default.attributesOfItem(atPath: subLog.path)
    let identity = "\((attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0):\((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)"
    var legacyCursor = FileCursor(identity: identity, path: subLog.path)
    legacyCursor.offset = UInt64(subContent.utf8.count)
    legacyCursor.state.sessionID = "sub"
    legacyCursor.state.cwd = "/project"
    try store.save(cursor: legacyCursor)

    let scanner = SessionScanner(store: store, codexHome: home)
    _ = try scanner.initialIndex()
    try expect(
        Set(try scanner.snapshot().sessions.map(\.sessionID)),
        Set(["top", "user-child"]),
        "only explicitly marked subagents excluded")
}

func testSidebarIndexedCoverage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions/2026/08/01")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let olderLog = sessions.appendingPathComponent("older-local.jsonl")
    let olderContent = [
        event(type: "session_meta", payload: ["id": "older-local", "cwd": "/projects/older"]),
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "older-turn"]),
        token(total: usage(120, 80, 10), last: usage(120, 80, 10)),
        event(type: "event_msg", payload: ["type": "task_complete"]),
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try Data(olderContent.utf8).write(to: olderLog)
    let delegatedLog = sessions.appendingPathComponent("delegated.jsonl")
    let delegatedContent = olderContent.replacingOccurrences(of: "older-local", with: "delegated")
    try Data(delegatedContent.utf8).write(to: delegatedLog)
    let database = home.appendingPathComponent("state_5.sqlite")
    let sql = """
    CREATE TABLE threads (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, archived INTEGER NOT NULL,
        source TEXT NOT NULL, rollout_path TEXT NOT NULL, thread_source TEXT
    );
    INSERT INTO threads VALUES ('older-local', '较早的本地会话', 0, 'vscode', '\(olderLog.path)', 'user');
    INSERT INTO threads VALUES ('internal', '内部任务', 0, '{"subagent":{"other":"guardian"}}', '\(olderLog.path)', 'subagent');
    INSERT INTO threads VALUES ('delegated', '委托任务', 0, 'vscode', '\(delegatedLog.path)', 'subagent');
    INSERT INTO threads VALUES ('archived', '已归档', 1, 'vscode', '\(olderLog.path)', 'user');
    """
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [database.path, sql]
    try sqlite.run()
    sqlite.waitUntilExit()
    try expect(sqlite.terminationStatus, 0, "metadata fixture created")

    let store = try SQLiteStore(path: root.appendingPathComponent("index.sqlite").path)
    let scanner = SessionScanner(store: store, codexHome: home)
    _ = try scanner.initialIndex()
    let snapshot = try scanner.snapshot()
    try expect(snapshot.sessions.map(\.sessionID), ["older-local"], "sidebar-visible rollout indexed")
    guard let session = snapshot.sessions.first else {
        throw TestFailure.assertion("sidebar-visible session missing")
    }
    try expect(session.activity, .stopped, "completed sidebar session state")
    try expect(session.usage.total, 130, "sidebar session real token facts")
}

func testSessionHealthAndActivity() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func makeTurn(
        session: String,
        ordinal: Int = 1,
        pressure: Double,
        compactions: Int = 0,
        fresh: Int = 1_000,
        status: TurnStatus = .running,
        activityAge: TimeInterval = 10
    ) -> TurnRecord {
        var turn = TurnRecord(
            sessionID: session,
            turnID: "\(session)-\(ordinal)",
            ordinal: ordinal,
            cwd: "/projects/\(session)",
            startedAt: now.addingTimeInterval(-activityAge),
            status: status)
        turn.contextWindow = 100_000
        turn.latestPromptInput = Int(pressure * 100_000)
        turn.compactions = compactions
        turn.usage.input = fresh
        turn.usage.uncachedInput = fresh
        turn.usage.total = fresh
        turn.lastActivityAt = now.addingTimeInterval(-activityAge)
        if status != .running { turn.completedAt = turn.lastActivityAt }
        return turn
    }

    let executing = makeTurn(session: "executing", pressure: 0.59, activityAge: 10)
    let waiting = makeTurn(session: "waiting", pressure: 0.60, activityAge: 90)
    let zombie = makeTurn(session: "zombie", pressure: 0.90, activityAge: 360)
    let stoppedRed = makeTurn(session: "resume-fresh", pressure: 0.80, status: .completed)
    let stoppedGreen = makeTurn(session: "recent", pressure: 0.20, status: .completed)
    let snapshot = DashboardSnapshot(
        active: [executing, waiting, zombie],
        recent: [stoppedRed, stoppedGreen],
        indexedFiles: 5,
        updatedAt: now)

    try expect(snapshot.activeSessions.map(\.sessionID), ["executing", "waiting"], "zombie excluded from active")
    try expect(snapshot.activeSessions.map(\.activity), [.executing, .waiting], "activity states")
    try expect(
        snapshot.activeSessions.allSatisfy { $0.activity == .executing || $0.activity == .waiting },
        true,
        "active grouping and badge state agree")
    try expect(snapshot.sessions.first(where: { $0.sessionID == "zombie" })?.activity, .interrupted, "stale running session interrupted")
    try expect(snapshot.activeSessions.map(\.risk), [.green, .amber], "60 percent boundary")
    try expect(snapshot.startFreshSessions.map(\.sessionID), ["resume-fresh", "zombie"], "stopped risk grouping")
    try expect(snapshot.recentHealthySessions.map(\.sessionID), ["recent"], "healthy recent grouping")
    try expect(snapshot.highestRisk, .amber, "historical red not realtime radar")

    var cacheHeavy = makeTurn(session: "cache-heavy", pressure: 0.20, fresh: 1_000, status: .completed)
    cacheHeavy.usage.input = 100_000
    cacheHeavy.usage.cachedInput = 99_000
    cacheHeavy.usage.uncachedInput = 1_000
    cacheHeavy.usage.total = 100_000
    let cacheHeavySummary = DashboardSnapshot(
        active: [], recent: [cacheHeavy], indexedFiles: 1, updatedAt: now).sessions.first!
    try expect(cacheHeavy.usage.cacheHitRate, 0.99, "high cache hit fixture")
    try expect(cacheHeavySummary.risk, .green, "cache hit alone does not imply session risk")
    let stoppedIdentity = cacheHeavySummary.renderIdentity
    let runningIdentity = DashboardSnapshot(
        active: [makeTurn(session: "cache-heavy", pressure: 0.20)],
        recent: [],
        indexedFiles: 1,
        updatedAt: now).sessions.first!.renderIdentity
    try expect(stoppedIdentity == runningIdentity, false, "card identity changes with activity state")

    let resumedTurn = makeTurn(session: "resume-fresh", ordinal: 2, pressure: 0.81, activityAge: 1)
    let resumedSnapshot = DashboardSnapshot(
        active: [resumedTurn], recent: [stoppedRed], indexedFiles: 1, updatedAt: now)
    try expect(
        resumedSnapshot.resumedGuardedSession(from: snapshot)?.sessionID,
        "resume-fresh",
        "guarded resume transition")

    let stoppedAmber = makeTurn(session: "resume-watch", pressure: 0.65, status: .completed)
    let previousAmber = DashboardSnapshot(
        active: [], recent: [stoppedAmber], indexedFiles: 1, updatedAt: now)
    let resumedAmber = makeTurn(session: "resume-watch", ordinal: 2, pressure: 0.66, activityAge: 1)
    let resumedAmberSnapshot = DashboardSnapshot(
        active: [resumedAmber], recent: [stoppedAmber], indexedFiles: 1, updatedAt: now)
    try expect(
        resumedAmberSnapshot.resumedGuardedSession(from: previousAmber)?.sessionID,
        nil,
        "amber resume does not trigger high-risk warning")

    let olderCompaction = makeTurn(
        session: "compacted", ordinal: 1, pressure: 0.30, compactions: 1, status: .completed, activityAge: 100)
    let latestAfterCompaction = makeTurn(
        session: "compacted", ordinal: 2, pressure: 0.76, status: .completed, activityAge: 1)
    let rebound = DashboardSnapshot(
        active: [], recent: [latestAfterCompaction, olderCompaction], indexedFiles: 2, updatedAt: now)
        .sessions.first!
    try expect(rebound.risk, .red, "post compaction rebound")
    try expect(rebound.postCompactionRebound, true, "rebound reason flag")

    var anomalyTurns = (1...4).map {
        makeTurn(session: "anomaly", ordinal: $0, pressure: 0.20, fresh: 1_000, status: .completed, activityAge: TimeInterval(100 + $0))
    }
    anomalyTurns.append(makeTurn(
        session: "anomaly", ordinal: 5, pressure: 0.20, fresh: 25_000, status: .completed, activityAge: 1))
    let anomaly = DashboardSnapshot(active: [], recent: anomalyTurns, indexedFiles: 1, updatedAt: now)
        .sessions.first!
    try expect(anomaly.risk, .amber, "fresh input anomaly risk")
    try expect(anomaly.freshInputAnomaly, true, "fresh input anomaly flag")

    let calibrationTurns = (1...20).map {
        makeTurn(
            session: "calibration-\($0)",
            pressure: 0.70,
            fresh: 2_000 + $0,
            status: .completed,
            activityAge: TimeInterval(1_000 + $0))
    }
    let learned = DashboardSnapshot(active: [], recent: calibrationTurns, indexedFiles: 20, updatedAt: now).healthPolicy
    try expect(learned.isCalibrated, true, "personal calibration activation")
    try expect(learned.effectiveSampleCount, 20, "effective local sample count")
    try expect(learned.freshInputReferenceThreshold, 20_000, "fresh input reference threshold")
    try expect(learned.amberContext, 0.65, "bounded learned amber threshold")
    try expect(learned.redContext, 0.82, "bounded learned red threshold")
}

func testPetAnimationState() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func makeTurn(
        session: String,
        pressure: Double = 0.2,
        status: TurnStatus = .running,
        activityAge: TimeInterval = 10
    ) -> TurnRecord {
        var turn = TurnRecord(
            sessionID: session,
            turnID: "\(session)-turn",
            ordinal: 1,
            cwd: "/projects/\(session)",
            startedAt: now.addingTimeInterval(-activityAge),
            status: status)
        turn.contextWindow = 100_000
        turn.latestPromptInput = Int(pressure * 100_000)
        turn.lastActivityAt = now.addingTimeInterval(-activityAge)
        if status != .running { turn.completedAt = turn.lastActivityAt }
        return turn
    }
    func snapshot(active: [TurnRecord] = [], recent: [TurnRecord] = []) -> DashboardSnapshot {
        DashboardSnapshot(active: active, recent: recent, indexedFiles: active.count + recent.count, updatedAt: now)
    }

    try expect(snapshot().petAnimationState(), .multitask, "idle session uses back-dance state")
    try expect(
        snapshot(active: [makeTurn(session: "working")]).petAnimationState(),
        .idle,
        "executing session uses front-dance state")
    try expect(
        snapshot(active: [makeTurn(session: "thinking", activityAge: 90)]).petAnimationState(),
        .working,
        "waiting session uses broom-dance state")
    try expect(
        snapshot(active: [makeTurn(session: "one"), makeTurn(session: "two")]).petAnimationState(),
        .idle,
        "executing state ignores active session count")
    try expect(
        snapshot(active: [makeTurn(session: "red", pressure: 0.81)]).petAnimationState(isCelebrating: true),
        .idle,
        "executing state wins over active risk")
    try expect(
        snapshot(active: [makeTurn(session: "amber", pressure: 0.65)]).petAnimationState(),
        .idle,
        "executing amber state still uses front dance")
    try expect(
        snapshot(active: [makeTurn(session: "waiting-risk", pressure: 0.65, activityAge: 90)]).petAnimationState(),
        .working,
        "risk score alone does not trigger high-risk prompt animation")
    try expect(
        snapshot(active: [makeTurn(session: "guarded", pressure: 0.81)]).petAnimationState(
            hasResumeWarning: true),
        .thinking,
        "high-risk resume warning wins over executing state")
    try expect(
        snapshot(active: [makeTurn(session: "red", pressure: 0.81)]).petAnimationState(isHovered: true),
        .guardian,
        "hover guardian wins over active risk")
    try expect(snapshot().petAnimationState(isCelebrating: true), .success, "completion state")

    let stopped = makeTurn(session: "completed", status: .completed)
    let interrupted = makeTurn(session: "interrupted", status: .interrupted)
    let stillActive = makeTurn(session: "active")
    try expect(
        snapshot(active: [stillActive], recent: [stopped, interrupted]).completedSessionIDs(
            previouslyActive: Set(["completed", "interrupted", "active", "missing"])),
        Set(["completed"]),
        "completed session transition excludes interruption")
}

func testHandoffContract() throws {
    let valid = """
    # 目标
    完成现有功能并保持范围不变。
    # 当前状态
    已有候选实现，等待继续验证。这里补充足够的上下文说明，确保摘要不是空壳。
    # 已验证完成及证据
    构建与核心测试已通过。
    # 关键决策与原因
    使用现有事实源，避免复制旧历史。
    # 不可改变的约束与风险
    不归档旧任务，不扩大权限。
    # 工作区、分支与已修改文件
    工作区和相关文件均已列明。
    # 下一步
    从运行态验证继续。
    """
    try expect(CodexHandoffMigrator.validateHandoff(valid), true, "valid handoff accepted")
    try expect(CodexHandoffMigrator.validateHandoff("# 目标\n只有一句"), false, "incomplete handoff rejected")

    let resumed: [String: Any] = [
        "thread": [
            "turns": [
                ["id": "done", "status": "completed"],
                ["id": "active", "status": "inProgress"],
            ],
        ],
    ]
    try expect(CodexHandoffMigrator.activeTurnID(in: resumed), "active", "active writer detection")
    try expect(
        CodexHandoffMigrator.activeTurnID(in: ["thread": ["turns": [["id": "done", "status": "completed"]]]]),
        nil,
        "idle thread detection")
}

func testFloatingPetAnchorStability() throws {
    let visibleFrame = CGRect(x: 0, y: 25, width: 1_440, height: 875)
    let petSize = CGSize(width: 116, height: 126)
    let expandedSize = CGSize(width: 640, height: 350)
    let collapsedSize = petSize

    // This location is valid for the pet but not for a fully visible 640pt
    // panel. The persistent anchor must therefore be governed by pet size.
    let draggedAnchor = CGPoint(x: 360, y: 700)
    let stableAnchor = FloatingPetGeometry.constrainedPetAnchor(
        draggedAnchor,
        petSize: petSize,
        visibleFrame: visibleFrame)
    try expect(stableAnchor, draggedAnchor, "expanded panel does not rewrite pet anchor")

    let expandedOrigin = FloatingPetGeometry.panelOrigin(
        forPetAnchor: stableAnchor,
        panelSize: expandedSize)
    let collapsedOrigin = FloatingPetGeometry.panelOrigin(
        forPetAnchor: stableAnchor,
        panelSize: collapsedSize)
    try expect(expandedOrigin.x + expandedSize.width, stableAnchor.x, "expanded trailing anchor")
    try expect(expandedOrigin.y, stableAnchor.y, "expanded bottom anchor")
    try expect(collapsedOrigin.x + collapsedSize.width, stableAnchor.x, "collapsed trailing anchor")
    try expect(collapsedOrigin.y, stableAnchor.y, "collapsed bottom anchor")

    let offscreenAnchor = CGPoint(x: -50, y: 950)
    let constrained = FloatingPetGeometry.constrainedPetAnchor(
        offscreenAnchor,
        petSize: petSize,
        visibleFrame: visibleFrame)
    try expect(constrained, CGPoint(x: 116, y: 774), "pet footprint remains visible")
}

func testFloatingSessionSnapshotStability() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func turn(sessionID: String, input: Int) -> TurnRecord {
        var value = TurnRecord(
            sessionID: sessionID,
            turnID: "\(sessionID)-turn",
            ordinal: 1,
            cwd: "/projects/\(sessionID)",
            startedAt: now.addingTimeInterval(-10),
            status: .running)
        value.latestPromptInput = input
        value.contextWindow = 100_000
        value.lastActivityAt = now.addingTimeInterval(-5)
        return value
    }

    let initial = DashboardSnapshot(
        active: [turn(sessionID: "first", input: 1_000), turn(sessionID: "second", input: 2_000)],
        recent: [],
        sessionTitles: ["first": "First", "second": "Second"],
        indexedFiles: 2,
        updatedAt: now).activeSessions
    let partial = DashboardSnapshot(
        active: [turn(sessionID: "first", input: 3_000)],
        recent: [],
        sessionTitles: ["first": "First"],
        indexedFiles: 2,
        updatedAt: now).activeSessions

    let stabilized = FloatingPetGeometry.stabilizedSessions(frozen: initial, current: partial)
    try expect(stabilized.map(\.sessionID), initial.map(\.sessionID), "partial refresh preserves card set")
    try expect(
        stabilized.first(where: { $0.sessionID == "first" })?.latestTurn?.latestPromptInput,
        3_000,
        "present session refreshes in place")
    try expect(
        stabilized.first(where: { $0.sessionID == "second" })?.latestTurn?.latestPromptInput,
        2_000,
        "temporarily missing session keeps last snapshot")
}

let tests: [(String, () throws -> Void)] = [
    ("aggregation and cache semantics", testAggregation),
    ("duplicate and cumulative reset", testDuplicateAndReset),
    ("turn boundaries and risk", testRiskAndBoundaries),
    ("incremental tail and archive move", testIncrementalAndArchive),
    ("cross-project isolation", testProjectIsolation),
    ("subagent filtering and migration", testSubagentFilteringAndMigration),
    ("sidebar-indexed coverage", testSidebarIndexedCoverage),
    ("session health, grouping, and activity", testSessionHealthAndActivity),
    ("pet animation event mapping", testPetAnimationState),
    ("handoff contract validation", testHandoffContract),
    ("floating pet anchor stability", testFloatingPetAnchorStability),
    ("floating session snapshot stability", testFloatingSessionSnapshotStability),
]

var failures = 0
for (name, test) in tests {
    do { try test(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("RESULT \(tests.count - failures)/\(tests.count) passed")
if failures > 0 { exit(1) }

private func usage(_ input: Int, _ cached: Int, _ output: Int, _ reasoning: Int = 0, _ cacheWrite: Int = 0) -> [String: Any] {
    ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": cacheWrite,
     "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output]
}
private func token(total: [String: Any], last: [String: Any], window: Int = 258_400) -> Data {
    event(type: "event_msg", payload: ["type": "token_count", "info": [
        "total_token_usage": total, "last_token_usage": last, "model_context_window": window],
        "rate_limits": ["primary": ["used_percent": 25, "window_minutes": 300]]])
}
private func event(type: String, payload: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["timestamp": "2026-08-09T09:00:00.000Z", "type": type, "payload": payload], options: [.sortedKeys])
}
private func append(_ string: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(string.utf8))
}
