import Foundation
import TokenPetCore

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case let .assertion(value): return value }
    }
}

final class ReplayCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingRoutingReplay?
    func set(_ replay: PendingRoutingReplay) { lock.lock(); value = replay; lock.unlock() }
    func get() -> PendingRoutingReplay? { lock.lock(); defer { lock.unlock() }; return value }
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
    try expect(QuotaSnapshot.isValid(raw: [:]), false, "missing primary quota is rejected")
    try expect(
        QuotaSnapshot.isValid(raw: ["primary": ["window_minutes": 10_080]]),
        false,
        "missing used percent is rejected")

    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    var codexTurn = TurnRecord(
        sessionID: "codex-limit", turnID: "codex-turn", ordinal: 1,
        cwd: "/project", startedAt: older)
    codexTurn.quota = QuotaSnapshot(raw: [
        "limit_id": "codex",
        "primary": ["used_percent": 14.0],
    ], observedAt: older)
    var alternateTurn = TurnRecord(
        sessionID: "alternate-limit", turnID: "alternate-turn", ordinal: 1,
        cwd: "/project", startedAt: newer)
    alternateTurn.quota = QuotaSnapshot(raw: [
        "limit_id": "codex_bengalfox",
        "primary": ["used_percent": 0.0],
    ], observedAt: newer)
    let quotaSnapshot = DashboardSnapshot(
        active: [alternateTurn], recent: [codexTurn], indexedFiles: 2, updatedAt: newer)
    try expect(quotaSnapshot.latestQuota?.remainingPercent, 86, "canonical Codex quota wins over newer alternate bucket")
    try expect(quotaSnapshot.latestQuota?.limitID, "codex", "canonical quota identity is retained")
}

func testTaskConfigurationCaptureAndEconomics() throws {
    var state = RolloutState()
    _ = state.process(line: event(type: "session_meta", payload: ["id": "config", "cwd": "/project"]))
    _ = state.process(line: event(type: "event_msg", payload: ["type": "task_started", "turn_id": "t1"]))
    let configured = state.process(line: event(type: "turn_context", payload: [
        "turn_id": "t1", "cwd": "/project", "model": "gpt-5.6-terra", "effort": "high",
    ]))!
    try expect(configured.model, "gpt-5.6-terra", "turn model captured")
    try expect(configured.reasoningEffort, "high", "turn effort captured")
    _ = state.process(line: token(total: usage(100, 20, 10), last: usage(100, 20, 10)))
    let first = state.process(line: event(type: "event_msg", payload: ["type": "task_complete"]))!

    var second = TurnRecord(
        sessionID: "config",
        turnID: "t2",
        ordinal: 2,
        cwd: "/project",
        startedAt: Date())
    second.status = .completed
    second.model = "gpt-5.6-sol"
    second.reasoningEffort = "medium"
    second.usage = TokenUsage(raw: ["input_tokens": 200, "output_tokens": 20, "total_tokens": 220])

    var third = TurnRecord(
        sessionID: "other",
        turnID: "t3",
        ordinal: 1,
        cwd: "/other",
        startedAt: Date())
    third.status = .completed
    third.model = "gpt-5.6-terra"
    third.reasoningEffort = "high"
    third.usage = TokenUsage(raw: ["input_tokens": 300, "output_tokens": 30, "total_tokens": 330])

    var unknown = TurnRecord(
        sessionID: "legacy",
        turnID: "t4",
        ordinal: 1,
        cwd: "/legacy",
        startedAt: Date())
    unknown.status = .completed
    unknown.usage = TokenUsage(raw: ["input_tokens": 50, "output_tokens": 5, "total_tokens": 55])

    let audit = TaskEconomicsAudit.build(from: [first, second, third, unknown])
    try expect(audit.completedTurns, 4, "audit completed turns")
    try expect(audit.tokenObservedTurns, 4, "audit token coverage")
    try expect(audit.configuredTurns, 3, "audit configured turns")
    try expect(audit.unknownConfigurationTurns, 1, "audit unknown configuration")
    try expect(audit.configurationSwitches, 1, "audit model switch count")
    try expect(audit.routingRecommendationsReady, false, "audit does not infer routing before quality evidence")
    let terra = audit.configurations.first { $0.model == "gpt-5.6-terra" }!
    try expect(terra.completedTurns, 2, "configuration aggregate turns")
    try expect(terra.sessions, 2, "configuration aggregate sessions")
    try expect(terra.usage.total, first.usage.total + third.usage.total, "configuration aggregate usage")
}

func testTaskShapeAndRoutingShadow() throws {
    var state = RolloutState()
    _ = state.process(line: event(type: "session_meta", payload: ["id": "profile", "cwd": "/secret/project"]))
    _ = state.process(line: event(type: "turn_context", payload: [
        "turn_id": "turn-secret", "model": "gpt-5.6-sol", "effort": "high",
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "read_file", "arguments": "PRIVATE_ARGUMENT",
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "functions.exec", "call_id": "verify-1",
        "input": #"{"cmd":"swift build && PRIVATE_COMMAND"}"#,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call_output", "call_id": "verify-1",
        "output": [["type": "input_text", "text": "Process exited with code 0\nPRIVATE_TOOL_OUTPUT"]],
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "exec_command", "call_id": "verify-failed",
        "arguments": #"{"cmd":"swift test"}"#,
    ]))
    let failedVerification = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "verify-failed",
        "output": "Process exited with code 1",
    ]))!
    try expect(failedVerification.executionProfile?.failureSignals, 1, "failed verification is visible")
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "exec_command", "call_id": "verify-retry",
        "arguments": #"{"cmd":"swift test"}"#,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "verify-retry",
        "output": "Process exited with code 0",
    ]))
    _ = state.process(line: event(type: "event_msg", payload: [
        "type": "patch_apply_end", "changes": ["a.swift": [:], "b.swift": [:]],
    ]))
    _ = state.process(line: token(total: usage(100, 20, 10), last: usage(100, 20, 10)))
    let parsed = state.process(line: event(type: "event_msg", payload: ["type": "task_complete"]))!
    try expect(parsed.executionProfile?.readActions, 1, "profile read action")
    try expect(parsed.executionProfile?.commandActions, 3, "generic exec calls remain normalized")
    try expect(parsed.executionProfile?.editActions, 2, "patch file count")
    try expect(parsed.executionProfile?.verificationActions, 2, "successful verification attempts counted")
    try expect(parsed.executionProfile?.failureSignals, 0, "later success resolves transient verification failure")
    try expect(TaskShape.classify(parsed.executionProfile), .implementation, "behavioral task shape")

    let comparable = (0..<5).map { index -> TurnRecord in
        var turn = parsed
        turn.sessionID = "private-session-\(index)"
        turn.turnID = "private-turn-\(index)"
        turn.ordinal = index + 1
        turn.model = "gpt-5.6-sol"
        turn.reasoningEffort = "medium"
        return turn
    }
    let profile = RoutingPreferenceProfile.currentHabits(updatedAt: Date(timeIntervalSince1970: 100))
    let audit = TaskEconomicsAudit.build(from: comparable, routingPreferenceProfile: profile)
    try expect(audit.profiledTurns, 5, "profile coverage count")
    try expect(audit.taskShapes.first?.shape, .implementation, "shape aggregate")
    try expect(audit.routingRecommendationsReady, false, "preference match does not imply task-lane fit")
    try expect(audit.outsideHabitBaselineTurns, 0, "habit baseline coverage")
    let controller = audit.routingRouteMap.first { $0.lane == .controllerArchitecture }!
    try expect(controller.observedTurns, 5, "controller habit observations")
    try expect(controller.explicitlyVerifiedTurns, 5, "habit route validation evidence")
    try expect(controller.baselineStatus, .observedHabit, "habit is not a recommendation")
    try expect(controller.officialModelRole, .frontierCapability, "official Sol role")
    try expect(controller.taskShapes.first?.shape, .implementation, "route map retains behavioral shape")
    try expect(audit.routingRouteMap.first { $0.lane == .frozenExecution }?.observedTurns, 0, "unobserved route remains visible")
    let decision = audit.shadowDecisions[0]
    try expect(decision.state, .habitBaselineNeedsEvaluation, "habit still needs evaluation")
    try expect(decision.proposedModel, nil, "no scalar model downgrade")
    try expect(decision.proposedReasoningEffort, nil, "sol low is not inferred")
    try expect(decision.matchedHabitLanes, [.controllerArchitecture], "habit lane is explicit")
    try expect(decision.confidence, "habit-only", "confidence names its evidence source")
    let controllerEval = audit.effortEvaluationCandidates.first { $0.habitLane == .controllerArchitecture }!
    try expect(controllerEval.state, .baselineAccepted, "medium is an official balanced baseline")
    try expect(controllerEval.comparisonEffort, nil, "sol low is not inferred without a latency workload")
    let lunaEval = audit.effortEvaluationCandidates.first { $0.habitLane == .frozenExecution }!
    try expect(lunaEval.state, .noHistoricalSamples, "luna max needs representative samples")
    try expect(lunaEval.comparisonEffort, "xhigh", "official max comparison is xhigh")
    let terraEval = audit.effortEvaluationCandidates.first { $0.habitLane == .judgmentDenseExecution }!
    try expect(terraEval.comparisonEffort, "medium", "high must prove gain over balanced baseline")

    let encoded = String(decoding: try JSONEncoder().encode(audit), as: UTF8.self)
    try expect(encoded.contains("PRIVATE_ARGUMENT"), false, "tool arguments not persisted")
    try expect(encoded.contains("PRIVATE_COMMAND"), false, "command content not persisted")
    try expect(encoded.contains("PRIVATE_TOOL_OUTPUT"), false, "tool output not persisted")
    try expect(encoded.contains("private-session"), false, "session identifiers not emitted")

    let insufficient = TaskEconomicsAudit.build(from: Array(comparable.prefix(4)))
    try expect(insufficient.routingRecommendationsReady, false, "unconfirmed profile remains observation only")
    try expect(insufficient.shadowDecisions[0].reasonCode, "habit_baseline_not_recorded", "habit gap is explicit")

    var outside = parsed
    outside.model = "gpt-5.6-sol"
    outside.reasoningEffort = "low"
    let mismatch = TaskEconomicsAudit.build(from: [outside], routingPreferenceProfile: profile)
    try expect(mismatch.outsideHabitBaselineTurns, 1, "configuration outside habits is counted")
    try expect(mismatch.shadowDecisions[0].state, .outsideHabitBaseline, "other configuration is not auto-recommended")
    try expect(mismatch.shadowDecisions[0].proposedModel, nil, "profile mismatch does not invent replacement")
}

func testExecutionWasteShadowLedger() throws {
    var state = RolloutState()
    _ = state.process(line: event(type: "session_meta", payload: [
        "id": "private-session", "cwd": "/private/workspace",
    ]))
    _ = state.process(line: event(type: "turn_context", payload: [
        "turn_id": "private-turn", "model": "gpt-5.6-terra", "effort": "high",
    ]))

    let privateReadArguments = #"{"path":"/private/workspace/Secret.swift"}"#
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "read_file", "call_id": "read-1",
        "arguments": privateReadArguments,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "read-1", "output": "PRIVATE_READ_OUTPUT",
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "read_file", "call_id": "read-2",
        "arguments": privateReadArguments,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "read-2", "output": "PRIVATE_READ_OUTPUT",
    ]))
    let privateReadWrapper = #"const r = await tools.exec_command({"cmd":"rg -n PRIVATE_SHELL_PATH Sources"}); text(r.output);"#
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "wrapped-read-1",
        "input": privateReadWrapper,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call_output", "call_id": "wrapped-read-1",
        "output": "PRIVATE_WRAPPED_READ_OUTPUT",
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "wrapped-read-2",
        "input": privateReadWrapper,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call_output", "call_id": "wrapped-read-2",
        "output": "PRIVATE_WRAPPED_READ_OUTPUT",
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "wrapped-read-changed",
        "input": privateReadWrapper,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call_output", "call_id": "wrapped-read-changed",
        "output": "PRIVATE_CHANGED_READ_OUTPUT",
    ]))
    for index in 1...2 {
        _ = state.process(line: event(type: "response_item", payload: [
            "type": "custom_tool_call", "name": "list_agents", "call_id": "dynamic-list-\(index)",
            "input": "{}",
        ]))
        _ = state.process(line: event(type: "response_item", payload: [
            "type": "custom_tool_call_output", "call_id": "dynamic-list-\(index)",
            "output": "PRIVATE_DYNAMIC_STATE",
        ]))
    }
    let dynamicStatusWrapper = #"const r = await tools.exec_command({"cmd":"python3 wf.py status run | sed -n '1,20p'"}); text(r.output);"#
    for index in 1...2 {
        _ = state.process(line: event(type: "response_item", payload: [
            "type": "custom_tool_call", "name": "exec", "call_id": "dynamic-status-\(index)",
            "input": dynamicStatusWrapper,
        ]))
        _ = state.process(line: event(type: "response_item", payload: [
            "type": "custom_tool_call_output", "call_id": "dynamic-status-\(index)",
            "output": "PRIVATE_DYNAMIC_STATUS",
        ]))
    }
    let mixedWrapper = #"const r = await tools.exec_command({"cmd":"rg -n PRIVATE_MIXED Sources && swift build"}); text(r.output);"#
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "mixed-1", "input": mixedWrapper,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "mixed-2", "input": mixedWrapper,
    ]))
    _ = state.process(line: event(type: "event_msg", payload: [
        "type": "patch_apply_end", "changes": ["Secret.swift": ["type": "update"]],
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "read_file", "call_id": "read-after-progress",
        "arguments": privateReadArguments,
    ]))

    let privateRetryArguments = #"{"cmd":"swift test PRIVATE_TARGET"}"#
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "exec_command", "call_id": "retry-1",
        "arguments": privateRetryArguments,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "retry-1",
        "output": "Process exited with code 1\nPRIVATE_FAILURE",
    ]))
    let changedRetry = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "exec_command", "call_id": "retry-changed",
        "arguments": #"{"cmd":"swift test PRIVATE_TARGET --filter changed"}"#,
    ]))!
    try expect(
        changedRetry.executionWasteProfile?.unchangedRetryCount,
        0,
        "changed retry input is not an unchanged retry")
    let restrictedWrapper = #"const r = await tools.exec_command({"cmd":"swift build PRIVATE_WRAPPED_TARGET","workdir":"/private/workspace"}); text(r.output);"#
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "restricted-wrapper",
        "input": restrictedWrapper,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call_output", "call_id": "restricted-wrapper",
        "output": "Process exited with code 1\nPRIVATE_SANDBOX_FAILURE",
    ]))
    let escalatedWrapper = #"const r = await tools.exec_command({"cmd":"swift build PRIVATE_WRAPPED_TARGET","workdir":"/private/workspace","sandbox_permissions":"require_escalated"}); text(r.output);"#
    let recovered = state.process(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "exec", "call_id": "escalated-wrapper",
        "input": escalatedWrapper,
    ]))!
    try expect(
        recovered.executionWasteProfile?.unchangedRetryCount,
        0,
        "sandbox escalation changes the execution operation fingerprint")
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "exec_command", "call_id": "retry-2",
        "arguments": privateRetryArguments,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "retry-2",
        "output": "Process exited with code 0\nPRIVATE_SUCCESS",
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "exec_command", "call_id": "retry-after-progress",
        "arguments": privateRetryArguments,
    ]))

    let privateLargeOutput = String(repeating: "PRIVATE_TOOL_OUTPUT_", count: 4_000)
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "remote_tool", "call_id": "large-output",
        "arguments": #"{"opaque":"PRIVATE_ARGUMENT"}"#,
    ]))
    _ = state.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "large-output", "output": privateLargeOutput,
    ]))
    _ = state.process(line: token(total: usage(1_000, 700, 100), last: usage(1_000, 700, 100)))

    let activeStateData = try JSONEncoder().encode(state)
    let activeEncoding = String(decoding: activeStateData, as: UTF8.self)
    try expect(activeEncoding.contains("Secret.swift"), false, "active tracker hashes read target")
    try expect(activeEncoding.contains("PRIVATE_TARGET"), false, "active tracker hashes retry command")
    try expect(activeEncoding.contains("PRIVATE_WRAPPED_TARGET"), false, "active tracker hashes wrapped execution context")
    try expect(activeEncoding.contains("PRIVATE_SHELL_PATH"), false, "active tracker hashes wrapped read command")
    try expect(activeEncoding.contains("PRIVATE_DYNAMIC_STATE"), false, "active tracker excludes dynamic state output")
    try expect(activeEncoding.contains("PRIVATE_TOOL_OUTPUT"), false, "active tracker excludes tool output")

    let completed = state.process(line: event(type: "event_msg", payload: ["type": "task_complete"]))!
    let profile = completed.executionWasteProfile!
    try expect(profile.repeatedReadCount, 2, "direct and conservative wrapped reads repeat before progress")
    try expect(profile.unchangedRetryCount, 1, "exact failed operation retry before progress")
    try expect(profile.bloatedOutputCount, 1, "large measured tool output")
    try expect(profile.largestToolOutputBytes, privateLargeOutput.utf8.count, "output bytes measured exactly")
    try expect(profile.reasons, [.repeatedRead, .retryWithoutChange, .outputBloat], "stable waste reason order")
    try expect(profile.occurrences?.count, 4, "anonymous review trace records each detected occurrence")
    try expect(
        profile.occurrences?.map(\.evidenceCode),
        [
            .exactReadRepeatedWithoutProgress,
            .exactReadRepeatedWithoutProgress,
            .exactRetryAfterExplicitFailure,
            .singleOutputThresholdExceeded,
        ],
        "review trace preserves stable structural evidence")
    try expect(
        profile.occurrences?.allSatisfy { occurrence in
            occurrence.operationHash == nil || occurrence.operationHash?.count == 64
        },
        true,
        "review trace stores only operation hashes")

    var structuredState = RolloutState()
    _ = structuredState.process(line: event(type: "turn_context", payload: ["turn_id": "structured-output-turn"]))
    _ = structuredState.process(line: event(type: "response_item", payload: [
        "type": "function_call", "name": "remote_tool", "call_id": "structured-output",
        "arguments": "{}",
    ]))
    let structuredText = "actual UTF-8 文本"
    _ = structuredState.process(line: event(type: "response_item", payload: [
        "type": "function_call_output", "call_id": "structured-output",
        "output": [["type": "input_text", "text": structuredText]],
    ]))
    let structuredCompleted = structuredState.process(
        line: event(type: "event_msg", payload: ["type": "task_complete"]))!
    try expect(
        structuredCompleted.executionWasteProfile?.totalToolOutputBytes,
        structuredText.utf8.count,
        "structured output counts text bytes without JSON wrapper metadata")

    var cumulativeState = RolloutState()
    _ = cumulativeState.process(line: event(type: "turn_context", payload: ["turn_id": "cumulative-output-turn"]))
    let mediumOutput = String(repeating: "x", count: 50 * 1_024)
    for callID in ["medium-output-1", "medium-output-2"] {
        _ = cumulativeState.process(line: event(type: "response_item", payload: [
            "type": "function_call", "name": "remote_tool", "call_id": callID,
            "arguments": #"{"same":"operation"}"#,
        ]))
        _ = cumulativeState.process(line: event(type: "response_item", payload: [
            "type": "function_call_output", "call_id": callID, "output": mediumOutput,
        ]))
    }
    let cumulativeCompleted = cumulativeState.process(
        line: event(type: "event_msg", payload: ["type": "task_complete"]))!
    try expect(
        cumulativeCompleted.executionWasteProfile?.bloatedOutputCount,
        1,
        "repeated medium outputs cross the cumulative threshold")
    try expect(
        cumulativeCompleted.executionWasteProfile?.occurrences?.last?.evidenceCode,
        .cumulativeOutputThresholdExceeded,
        "cumulative threshold has explicit review evidence")

    let observation = ExecutionWasteObservation.derive(from: completed)!
    try expect(observation.qualityEvidence, .verifiedSuccess, "quality remains independent from waste evidence")
    try expect(observation.evidence.map(\.reason), profile.reasons, "ledger preserves reason order")
    try expect(observation.id == completed.id, false, "ledger does not persist raw turn identity")
    var legacyObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(observation)) as! [String: Any]
    legacyObject.removeValue(forKey: "occurrences")
    legacyObject["schemaVersion"] = 1
    let legacyObservation = try JSONDecoder().decode(
        ExecutionWasteObservation.self,
        from: JSONSerialization.data(withJSONObject: legacyObject))
    try expect(legacyObservation.occurrences, nil, "schema v1 observations remain decodable")
    var legacyStateObject = try JSONSerialization.jsonObject(with: activeStateData) as! [String: Any]
    var removedLegacyPendingKind = false
    var removedLegacyReadHash = false
    if var tracker = legacyStateObject["executionWasteTracker"] as? [String: Any],
       var pending = tracker["pending"] as? [String: Any],
       let pendingKey = pending.keys.sorted().first,
       var pendingOperation = pending[pendingKey] as? [String: Any]
    {
        pendingOperation.removeValue(forKey: "kind")
        removedLegacyPendingKind = true
        pending[pendingKey] = pendingOperation
        tracker["pending"] = pending
        legacyStateObject["executionWasteTracker"] = tracker
    }
    if var tracker = legacyStateObject["executionWasteTracker"] as? [String: Any],
       var seenReads = tracker["seenReads"] as? [String: Any],
       let readKey = seenReads.keys.sorted().first,
       var readResult = seenReads[readKey] as? [String: Any]
    {
        readResult.removeValue(forKey: "outputHash")
        removedLegacyReadHash = true
        seenReads[readKey] = readResult
        tracker["seenReads"] = seenReads
        legacyStateObject["executionWasteTracker"] = tracker
    }
    _ = try JSONDecoder().decode(
        RolloutState.self,
        from: JSONSerialization.data(withJSONObject: legacyStateObject))
    try expect(removedLegacyPendingKind, true, "legacy cursor fixture contains a pending operation")
    try expect(removedLegacyReadHash, true, "legacy cursor fixture contains a read result")
    let persistedJSON = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
    for secret in [
        "private-session", "private-turn", "/private/workspace", "Secret.swift",
        "PRIVATE_TARGET", "PRIVATE_WRAPPED_TARGET", "PRIVATE_SHELL_PATH", "PRIVATE_MIXED", "PRIVATE_ARGUMENT",
        "PRIVATE_TOOL_OUTPUT", "PRIVATE_WRAPPED_READ_OUTPUT", "PRIVATE_CHANGED_READ_OUTPUT",
        "PRIVATE_DYNAMIC_STATE", "PRIVATE_DYNAMIC_STATUS", "PRIVATE_FAILURE",
    ] {
        try expect(persistedJSON.contains(secret), false, "ledger excludes private value \(secret)")
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(path: root.appendingPathComponent("guardian.sqlite").path)
    try store.upsertExecutionWasteObservation(observation)
    try store.upsertExecutionWasteObservation(observation)
    try expect(try store.executionWasteObservations(limit: 10).count, 1, "waste ledger upsert is idempotent")
    try expect(
        try store.executionWasteObservations(limit: 10, onlyWithEvidence: true),
        [observation],
        "evidence-only shadow query")
    var priorPolicyObservation = observation
    priorPolicyObservation.id = String(repeating: "a", count: 64)
    priorPolicyObservation.policyVersion = "execution-waste-v1"
    try store.upsertExecutionWasteObservation(priorPolicyObservation)

    var invalidRationaleRejected = false
    do {
        _ = try ExecutionWasteReviewLabel(
            observationID: observation.id,
            reason: .repeatedRead,
            verdict: .confirmedWaste,
            rationale: .necessaryEvidence,
            recordedAt: Date(timeIntervalSince1970: 2_000))
    } catch ExecutionWasteReviewValidationError.incompatibleRationale {
        invalidRationaleRejected = true
    }
    try expect(invalidRationaleRejected, true, "verdict and rationale compatibility is enforced")
    var invalidIDRejected = false
    do {
        _ = try ExecutionWasteReviewLabel(
            observationID: String(repeating: "Z", count: 64),
            reason: .repeatedRead,
            verdict: .confirmedWaste,
            rationale: .confirmedRedundant,
            recordedAt: Date(timeIntervalSince1970: 2_000))
    } catch ExecutionWasteReviewValidationError.invalidObservationID {
        invalidIDRejected = true
    }
    try expect(invalidIDRejected, true, "review label accepts only lowercase SHA-256 IDs")

    let repeatedLabel = try ExecutionWasteReviewLabel(
        observationID: observation.id,
        reason: .repeatedRead,
        verdict: .confirmedWaste,
        rationale: .confirmedRedundant,
        recordedAt: Date(timeIntervalSince1970: 2_001))
    let retryLabel = try ExecutionWasteReviewLabel(
        observationID: observation.id,
        reason: .retryWithoutChange,
        verdict: .justified,
        rationale: .necessaryRecovery,
        recordedAt: Date(timeIntervalSince1970: 2_002))
    let outputLabel = try ExecutionWasteReviewLabel(
        observationID: observation.id,
        reason: .outputBloat,
        verdict: .unclear,
        rationale: .insufficientContext,
        recordedAt: Date(timeIntervalSince1970: 2_003))
    try store.upsertExecutionWasteReviewLabel(repeatedLabel)
    try store.upsertExecutionWasteReviewLabel(repeatedLabel)
    try store.upsertExecutionWasteReviewLabel(retryLabel)
    try store.upsertExecutionWasteReviewLabel(outputLabel)
    try expect(try store.executionWasteReviewLabels().count, 3, "review labels upsert per observation and reason")
    let reviewItems = try store.executionWasteReviewItems(limit: 10)
    try expect(reviewItems.count, 1, "review query returns evidence samples")
    try expect(reviewItems[0].isFullyLabeled, true, "each observed category is independently labeled")
    try expect(
        try store.executionWasteReviewItems(limit: 10, onlyUnlabeled: true).isEmpty,
        true,
        "fully labeled samples leave the review queue")
    let accuracy = try store.executionWasteAccuracySummary(
        minimumConclusiveSamples: 2,
        precisionTarget: 0.8,
        generatedAt: Date(timeIntervalSince1970: 2_100))
    try expect(accuracy.state, .precisionBelowTarget, "conclusive labels can expose a low precision result")
    try expect(accuracy.overall.detectedSamples, 3, "accuracy denominator counts observation-category samples")
    try expect(accuracy.overall.detectedOccurrences, 4, "accuracy also reports raw occurrence volume")
    try expect(accuracy.overall.labeledSamples, 3, "all category samples are labeled")
    try expect(accuracy.overall.conclusiveSamples, 2, "unclear labels stay outside precision denominator")
    try expect(accuracy.overall.precision, 0.5, "precision uses confirmed over conclusive labels")
    try expect(
        accuracy.categories.map(\.reason),
        [.repeatedRead, .retryWithoutChange, .outputBloat],
        "accuracy categories preserve stable reason order")
    let collectingAccuracy = try store.executionWasteAccuracySummary(
        minimumConclusiveSamples: 3,
        precisionTarget: 0.5,
        generatedAt: Date(timeIntervalSince1970: 2_101))
    try expect(collectingAccuracy.state, .collectingLabels, "sample gate runs before precision target")
    let targetMetAccuracy = try store.executionWasteAccuracySummary(
        minimumConclusiveSamples: 2,
        precisionTarget: 0.5,
        generatedAt: Date(timeIntervalSince1970: 2_102))
    try expect(targetMetAccuracy.state, .precisionTargetMet, "precision target state requires enough evidence")
    try expect(
        ExecutionWasteCalibrationMilestone.derive(from: targetMetAccuracy) == nil,
        true,
        "milestone also requires conclusive coverage of every waste reason")
    var coveredAccuracy = targetMetAccuracy
    coveredAccuracy.categories = ExecutionWasteReason.allCases.map { reason in
        ExecutionWasteAccuracyMetrics(
            reason: reason,
            detectedSamples: 1,
            detectedOccurrences: 1,
            labeledSamples: 1,
            confirmedWaste: 1,
            justified: 0,
            unclear: 0,
            conclusiveSamples: 1,
            labelCoverage: 1,
            precision: 1)
    }
    coveredAccuracy.overall.conclusiveSamples = 3
    coveredAccuracy.overall.confirmedWaste = 3
    coveredAccuracy.overall.precision = 1
    coveredAccuracy.minimumConclusiveSamples = 3
    let readyMilestone = ExecutionWasteCalibrationMilestone.derive(from: coveredAccuracy)
    try expect(readyMilestone?.outcome, .semanticContinuityReady, "covered precision target emits ready milestone")
    try expect(readyMilestone?.id, "execution-waste-calibration:\(coveredAccuracy.policyVersion)", "milestone identity is policy-version stable")
    coveredAccuracy.overall.precision = 0.49
    let shadowMilestone = ExecutionWasteCalibrationMilestone.derive(from: coveredAccuracy)
    try expect(shadowMilestone?.outcome, .continueShadow, "covered sample gate below precision continues shadow")
    let labelEncoding = String(decoding: try JSONEncoder().encode(repeatedLabel), as: UTF8.self)
    try expect(labelEncoding.contains("PRIVATE_"), false, "review label stores no raw evidence")

    var cleanTurn = completed
    cleanTurn.turnID = "clean-turn"
    cleanTurn.ordinal = 2
    cleanTurn.executionWasteProfile = ExecutionWasteProfile()
    let clean = ExecutionWasteObservation.derive(from: cleanTurn)!
    try store.upsertExecutionWasteObservation(clean)
    try expect(try store.executionWasteObservations(limit: 10).count, 3, "negative and prior-policy samples retained")
    try expect(
        try store.executionWasteObservations(limit: 10, onlyWithEvidence: true).count,
        2,
        "evidence filter excludes clean samples but retains prior policy history")
    var unobservedReasonRejected = false
    do {
        let invalid = try ExecutionWasteReviewLabel(
            observationID: clean.id,
            reason: .repeatedRead,
            verdict: .confirmedWaste,
            rationale: .confirmedRedundant,
            recordedAt: Date(timeIntervalSince1970: 2_200))
        try store.upsertExecutionWasteReviewLabel(invalid)
    } catch ExecutionWasteReviewValidationError.reasonNotObserved {
        unobservedReasonRejected = true
    }
    try expect(unobservedReasonRejected, true, "labels cannot invent evidence on a clean sample")
    var revisedObservation = observation
    revisedObservation.evidence.removeAll { $0.reason == .repeatedRead }
    revisedObservation.occurrences?.removeAll { $0.reason == .repeatedRead }
    try store.upsertExecutionWasteObservation(revisedObservation)
    try expect(
        try store.executionWasteReviewLabels().map(\.reason).contains(.repeatedRead),
        false,
        "labels are removed when a rescanned observation no longer contains that evidence")
}

func testRoutingOutcomeObservation() throws {
    var base = TurnRecord(
        sessionID: "PRIVATE_SESSION",
        turnID: "PRIVATE_TURN",
        ordinal: 1,
        cwd: "/PRIVATE/PROJECT",
        startedAt: Date(timeIntervalSince1970: 100))
    base.completedAt = Date(timeIntervalSince1970: 112)
    base.lastActivityAt = base.completedAt
    base.status = .completed
    base.model = "gpt-5.6-luna"
    base.reasoningEffort = "max"
    base.calls = 3
    base.usage = TokenUsage(raw: ["input_tokens": 80, "output_tokens": 20, "total_tokens": 100])
    var execution = TurnExecutionProfile()
    execution.editActions = 2
    execution.commandActions = 1
    base.executionProfile = execution
    let routingProfile = RoutingPreferenceProfile.currentHabits()

    let unverified = RoutingOutcomeObservation.derive(
        from: base,
        routingPreferenceProfile: routingProfile)!
    try expect(unverified.qualityEvidence, .completedUnverified, "completion is not quality success")
    try expect(unverified.matchedHabitLanes, [.frozenExecution], "configured habit lane retained")
    try expect(unverified.taskShape, .implementation, "privacy-safe task shape")
    try expect(unverified.durationSeconds, 12, "bounded duration")

    var verified = base
    verified.turnID = "PRIVATE_VERIFIED_TURN"
    verified.executionProfile?.verificationActions = 1
    let success = RoutingOutcomeObservation.derive(from: verified, routingPreferenceProfile: routingProfile)!
    try expect(success.qualityEvidence, .verifiedSuccess, "successful explicit verification is decisive")

    var failed = verified
    failed.turnID = "PRIVATE_FAILED_TURN"
    failed.executionProfile?.failureSignals = 1
    let failure = RoutingOutcomeObservation.derive(from: failed, routingPreferenceProfile: routingProfile)!
    try expect(failure.qualityEvidence, .verifiedFailure, "failure wins over prior verification success")

    var interrupted = verified
    interrupted.turnID = "PRIVATE_INTERRUPTED_TURN"
    interrupted.status = .interrupted
    let stopped = RoutingOutcomeObservation.derive(from: interrupted, routingPreferenceProfile: routingProfile)!
    try expect(stopped.qualityEvidence, .interrupted, "interruption remains distinct")

    let unverifiedPostflight = RoutingPostflightAssessment.evaluate(unverified)
    try expect(unverifiedPostflight.quality, .insufficientEvidence, "completion alone never proves routing quality")
    try expect(unverifiedPostflight.action, .requireVerification, "unverified work cannot train a cheaper route")
    let successfulPostflight = RoutingPostflightAssessment.evaluate(success)
    try expect(successfulPostflight.quality, .passed, "verified success retains the route")
    try expect(successfulPostflight.usage.total, 100, "postflight retains exact provider usage")
    let failedPostflight = RoutingPostflightAssessment.evaluate(failure)
    try expect(failedPostflight.quality, .failed, "failed verification remains visible")
    try expect(failedPostflight.action, .reviewTaskContract, "failure does not infer a route for a future task")

    let summary = RoutingOutcomeSummary.build(from: [unverified, success, failure, stopped])
    try expect(summary.decisiveSamples, 2, "only verified pass or failure is decisive")
    try expect(summary.completedUnverified, 1, "unverified completion counted")
    try expect(summary.interrupted, 1, "interruption counted")

    let controlledGate = RoutingEvaluationGateResult(
        state: .candidateTrialReady,
        baselineEffort: "max",
        candidateEffort: "xhigh",
        comparablePairs: 1,
        distinctTaskContracts: 1,
        minimumComparablePairs: 3,
        minimumDistinctTaskContracts: 2,
        baselineTotalTokens: 200,
        candidateTotalTokens: 100,
        tokenSavingsRatio: 0.5,
        baselineDurationSeconds: 20,
        candidateDurationSeconds: 10,
        latencySavingsRatio: 0.5)
    let observing = RoutingOnlineLearningGate.evaluate(
        controlledGate: controlledGate,
        candidateOutcomes: [success])
    try expect(observing.state, .qualityObserving, "one real success raises candidate confidence")
    let withdrawn = RoutingOnlineLearningGate.evaluate(
        controlledGate: controlledGate,
        candidateOutcomes: [success, failure])
    try expect(withdrawn.state, .withdrawn, "one real quality failure withdraws candidate")
    var secondClass = success
    secondClass.id = "opaque-second"
    secondClass.taskClassFingerprint = "second-class"
    var thirdSuccess = secondClass
    thirdSuccess.id = "opaque-third"
    let personalized = RoutingOnlineLearningGate.evaluate(
        controlledGate: controlledGate,
        candidateOutcomes: [success, secondClass, thirdSuccess])
    try expect(personalized.state, .personalizationReady, "diverse real successes promote candidate")
    try expect(personalized.distinctTaskClasses, 2, "task class diversity guards promotion")

    let encoded = String(decoding: try JSONEncoder().encode([unverified, success, failure, stopped]), as: UTF8.self)
    try expect(encoded.contains("PRIVATE_SESSION"), false, "outcome excludes session identifier")
    try expect(encoded.contains("PRIVATE_TURN"), false, "outcome excludes turn identifier")
    try expect(encoded.contains("PRIVATE/PROJECT"), false, "outcome excludes cwd")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(path: root.appendingPathComponent("routing-outcomes.sqlite").path)
    try store.upsertRoutingOutcome(success)
    try store.upsertRoutingOutcome(success)
    try expect(try store.routingOutcomes(), [success], "routing outcome upsert is idempotent")
}

func testRoutingPreferencePersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(path: root.appendingPathComponent("routing.sqlite").path)
    try expect(try store.loadRoutingPreferenceProfile(), nil, "routing profile starts unconfirmed")
    let profile = RoutingPreferenceProfile.currentHabits(updatedAt: Date(timeIntervalSince1970: 123))
    try store.saveRoutingPreferenceProfile(profile)
    try expect(try store.loadRoutingPreferenceProfile(), profile, "routing profile round trip")
    try expect(profile.routes.count, 3, "controller worker preset route count")
    try expect(profile.source, "observedHabit", "habit source is not quality confirmation")
    try expect(profile.routes.allSatisfy { $0.effectiveStatus == .observedHabit }, true, "routes start unvalidated")
    try expect(profile.routes[0].reasoningEffort, "medium", "controller uses user-confirmed effort")
    try expect(profile.routes[1].reasoningEffort, "max", "frozen worker uses user-confirmed effort")
    try expect(profile.routes[2].reasoningEffort, "high", "judgment-dense worker uses user-confirmed effort")

    var usage = TokenUsage()
    usage.input = 100
    usage.cachedInput = 80
    usage.uncachedInput = 20
    usage.output = 12
    usage.reasoningOutput = 5
    usage.total = 112
    let sample = RoutingEvaluationSample(
        id: "comparison:max",
        comparisonID: "comparison",
        recordedAt: Date(timeIntervalSince1970: 456),
        taskContractFingerprint: "contract-hash",
        environmentFingerprint: "environment-hash",
        implementationFingerprint: "implementation-hash",
        policyVersion: CodexQuotaRouterPolicy.policyVersion,
        habitLane: .frozenExecution,
        model: "gpt-5.6-luna",
        reasoningEffort: "max",
        qualityPassed: true,
        passedChecks: 28,
        totalChecks: 28,
        durationSeconds: 12.5,
        toolCalls: 3,
        usage: usage,
        evidenceBoundary: "controlled fixture")
    try store.upsertRoutingEvaluation(sample)
    try store.upsertRoutingEvaluation(sample)
    try expect(try store.routingEvaluations(), [sample], "routing evaluation upsert is idempotent")

    var candidate = sample
    candidate.id = "comparison:xhigh"
    candidate.reasoningEffort = "xhigh"
    candidate.durationSeconds = 6
    candidate.usage.total = 50
    let onePair = RoutingEvaluationGate.evaluate(
        [sample, candidate],
        baselineEffort: "max",
        candidateEffort: "xhigh")
    try expect(onePair.state, .candidateTrialReady, "one successful pair can propose another real-task trial")
    try expect(onePair.comparablePairs, 1, "comparable pair counted")
    try expect(onePair.tokenSavingsRatio > 0.5, true, "pair still reports measured savings")

    var failedCandidate = candidate
    failedCandidate.qualityPassed = false
    let failed = RoutingEvaluationGate.evaluate(
        [sample, failedCandidate],
        baselineEffort: "max",
        candidateEffort: "xhigh")
    try expect(failed.state, .candidateFailedQuality, "quality failure rejects candidate before sample threshold")

    var sufficient: [RoutingEvaluationSample] = []
    for index in 0..<3 {
        var baseline = sample
        baseline.id = "pair-\(index):max"
        baseline.comparisonID = "pair-\(index)"
        baseline.taskContractFingerprint = "contract-\(index % 2)"
        var lower = candidate
        lower.id = "pair-\(index):xhigh"
        lower.comparisonID = baseline.comparisonID
        lower.taskContractFingerprint = baseline.taskContractFingerprint
        sufficient.append(contentsOf: [baseline, lower])
    }
    let ready = RoutingEvaluationGate.evaluate(
        sufficient,
        baselineEffort: "max",
        candidateEffort: "xhigh")
    try expect(ready.state, .candidateReadyForPersonalization, "diverse paired evidence can personalize the local default")
    try expect(ready.distinctTaskContracts, 2, "task diversity is measured")
}

func testEvaluationTaskProtocol() throws {
    let thread = CodexEvaluationTaskRunner.threadStartParams(
        cwd: "/private/tmp/eval-arm",
        model: "gpt-5.6-terra")
    try expect(thread["cwd"] as? String, "/private/tmp/eval-arm", "evaluation cwd")
    try expect(thread["model"] as? String, "gpt-5.6-terra", "evaluation model")
    try expect(thread["ephemeral"] as? Bool, false, "evaluation task remains inspectable")
    try expect(thread["approvalPolicy"] as? String, "never", "evaluation never waits for user approval")
    try expect(thread["sandbox"] as? String, "workspace-write", "evaluation is limited to its fixture")

    let turn = CodexEvaluationTaskRunner.turnStartParams(
        threadID: "eval-thread",
        prompt: "frozen prompt",
        reasoningEffort: "medium")
    try expect(turn["threadId"] as? String, "eval-thread", "evaluation thread id")
    try expect(turn["effort"] as? String, "medium", "evaluation effort")
    let input = turn["input"] as? [[String: String]]
    try expect(input?.first?["text"], "frozen prompt", "evaluation prompt")

    let commandApproval = CodexEvaluationTaskRunner.approvalResponse(
        requestID: 41,
        method: "item/commandExecution/requestApproval")
    try expect(commandApproval?["id"] as? Int, 41, "approval response preserves server request id")
    let commandResult = commandApproval?["result"] as? [String: Any]
    try expect(commandResult?["decision"] as? String, "decline", "evaluation never stalls on command approval")

    let permissionApproval = CodexEvaluationTaskRunner.approvalResponse(
        requestID: 42,
        method: "item/permissions/requestApproval")
    let permissionResult = permissionApproval?["result"] as? [String: Any]
    try expect(permissionResult?["scope"] as? String, "turn", "permission denial is turn scoped")
    try expect((permissionResult?["permissions"] as? [String: Any])?.isEmpty, true, "evaluation grants no extra permissions")
    try expect(CodexEvaluationTaskRunner.approvalResponse(
        requestID: 43,
        method: "item/completed") == nil, true, "notifications do not receive fake responses")
}

func testCodexQuotaRouterPolicy() throws {
    let ambiguous = CodexQuotaRouterPolicy.decide(.init(decisionChangingAmbiguity: true))
    try expect(ambiguous.action, .clarifyBeforeExecution, "ambiguity stops execution")
    try expect(ambiguous.model, "gpt-5.6-sol", "controller owns clarification")
    try expect(ambiguous.reasoningEffort, "medium", "controller effort is explicit")

    let luna = CodexQuotaRouterPolicy.decide(.init(
        contractFrozen: true,
        mechanicallyVerifiable: true,
        delegationHasClearValue: true))
    try expect(luna.action, .delegateToLuna, "frozen mechanical work uses Luna lane")
    try expect(luna.model, "gpt-5.6-luna", "Luna model")
    try expect(luna.reasoningEffort, "max", "declared Luna effort")

    let terra = CodexQuotaRouterPolicy.decide(.init(
        contractFrozen: true,
        mechanicallyVerifiable: true,
        judgmentDense: true,
        crossModule: true,
        lunaRepairRiskMateriallyHigher: true,
        delegationHasClearValue: true))
    try expect(terra.action, .delegateToTerra, "concrete repair risk selects Terra")
    try expect(terra.model, "gpt-5.6-terra", "Terra model")
    try expect(terra.reasoningEffort, "high", "declared Terra effort")

    let noMismatch = CodexQuotaRouterPolicy.decide(.init(
        contractFrozen: true,
        mechanicallyVerifiable: true,
        judgmentDense: true,
        crossModule: true,
        delegationHasClearValue: true))
    try expect(noMismatch.action, .delegateToLuna, "Terra is not selected without evidenced Luna mismatch")

    let protected = CodexQuotaRouterPolicy.decide(.init(
        contractFrozen: true,
        mechanicallyVerifiable: true,
        delegationHasClearValue: true,
        externalMutation: true))
    try expect(protected.action, .keepInController, "external mutation authority stays in controller")
    try expect(protected.reasonCodes.contains("authority_not_delegated"), true, "authority boundary is explained")
    try expect(protected.evidenceStatus, "declared-policy-not-token-validated", "policy is not mislabeled as optimal")
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
    let storedSubagent = try store.turns(limit: 20).first { $0.sessionID == "sub" }
    try expect(storedSubagent?.isSubagent, true, "subagent remains indexed for execution audit")
}

func testMultiAgentExecutionAudit() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var parent = TurnRecord(
        sessionID: "parent", turnID: "parent-turn", ordinal: 1,
        cwd: "/project", startedAt: now)
    parent.agentDispatches = [AgentDispatchRecord(
        taskName: "start_iter2_readiness",
        agentType: "worker",
        forkTurns: "all",
        model: nil,
        reasoningEffort: nil,
        occurredAt: now.addingTimeInterval(1))]

    var child = TurnRecord(
        sessionID: "child", turnID: "child-turn", ordinal: 1,
        cwd: "/project", startedAt: now.addingTimeInterval(2))
    child.isSubagent = true
    child.parentThreadID = "parent"
    child.agentPath = "/root/start_iter2_readiness"
    child.usage = TokenUsage(raw: [
        "input_tokens": 12_000_000,
        "cached_input_tokens": 9_000_000,
        "output_tokens": 100_000,
        "reasoning_output_tokens": 50_000,
        "total_tokens": 12_100_000,
    ])

    let activeFindings = MultiAgentAuditPolicy.evaluate(turns: [parent, child])
    try expect(
        Set(activeFindings.map(\.reason)),
        Set([.genericWorkerInheritedFullHistory, .largeTokenBurn]),
        "generic full-history worker and token burn are attributed")
    try expect(
        Set(activeFindings.map(\.severity)),
        Set([.observeDuringExecution]),
        "active findings remain observation-only")
    try expect(
        Set(activeFindings.map(\.costAttribution)),
        Set([.observedUsageOnly]),
        "single-run usage is not mislabeled as avoidable cost")
    try expect(
        activeFindings.allSatisfy { $0.estimatedAvoidableProviderTokens == nil },
        true,
        "avoidable tokens require a matched baseline")

    child.status = .completed
    child.completedAt = now.addingTimeInterval(10)
    let completedFindings = MultiAgentAuditPolicy.evaluate(turns: [parent, child])
    try expect(
        Set(completedFindings.map(\.severity)),
        Set([.reviewAfterCompletion]),
        "completed work becomes postflight advice")

    parent.agentDispatches?[0].forkTurns = "none"
    child.usage = TokenUsage()
    try expect(
        MultiAgentAuditPolicy.evaluate(turns: [parent, child]).isEmpty,
        true,
        "bounded context without token burn stays quiet")

    var parsed = RolloutState()
    _ = parsed.process(line: event(type: "session_meta", payload: ["id": "parser-parent", "cwd": "/project"]))
    _ = parsed.process(line: event(type: "event_msg", payload: ["type": "task_started", "turn_id": "turn"]))
    let failedAttempt = parsed.process(line: event(type: "response_item", payload: [
        "type": "function_call",
        "name": "spawn_agent",
        "call_id": "failed-call",
        "arguments": #"{"task_name":"rejected-all","agent_type":"worker","fork_turns":"all"}"#,
    ]))
    _ = parsed.process(line: event(type: "response_item", payload: [
        "type": "function_call_output",
        "call_id": "failed-call",
        "output": "fork_turns: all is unsupported",
    ]))
    try expect(failedAttempt?.agentDispatches, nil, "spawn call remains pending before output")
    try expect(
        parsed.active?.agentDispatches?.isEmpty ?? true,
        true,
        "failed spawn does not create a dispatch record")

    let successCall = parsed.process(line: event(type: "response_item", payload: [
        "type": "function_call",
        "name": "spawn_agent",
        "call_id": "success-call",
        "arguments": #"{"task_name":"bounded","agent_type":"luna_worker","fork_turns":"none"}"#,
    ]))
    try expect(successCall?.agentDispatches, nil, "successful spawn remains pending until started")
    let started = parsed.process(line: event(type: "event_msg", payload: [
        "type": "sub_agent_activity",
        "event_id": "success-call",
        "agent_thread_id": "child-thread",
        "agent_path": "/root/bounded",
        "kind": "started",
    ]))
    try expect(started?.agentDispatches?.first?.taskName, "bounded", "started activity confirms dispatch")
    try expect(started?.agentDispatches?.first?.forkTurns, "none", "fork scope is preserved")
    try expect(started?.agentDispatches?.first?.callID, "success-call", "call id joins started activity")
    try expect(started?.agentDispatches?.first?.agentThreadID, "child-thread", "child thread id is retained")
    try expect(started?.agentDispatches?.first?.agentPath, "/root/bounded", "agent path is retained")

    _ = parsed.process(line: event(type: "response_item", payload: [
        "type": "function_call",
        "name": "spawn_agent",
        "call_id": "output-call",
        "arguments": #"{"task_name":"output-confirmed","agent_type":"luna_worker"}"#,
    ]))
    let outputConfirmed = parsed.process(line: event(type: "response_item", payload: [
        "type": "function_call_output",
        "call_id": "output-call",
        "output": #"{"task_name":"/root/output-confirmed"}"#,
    ]))
    try expect(outputConfirmed?.agentDispatches?.last?.taskName, "output-confirmed", "successful output confirms dispatch")
    try expect(outputConfirmed?.agentDispatches?.last?.forkTurns, nil, "missing fork scope stays unknown")

    var childState = RolloutState()
    let parsedChild = childState.process(line: event(type: "session_meta", payload: [
        "id": "parser-child",
        "cwd": "/project",
        "parent_thread_id": "parser-parent",
        "source": ["subagent": ["thread_spawn": ["agent_path": "/root/bounded"]]],
    ]))
    _ = parsedChild
    let childTurn = childState.process(line: event(type: "event_msg", payload: [
        "type": "task_started", "turn_id": "child-turn",
    ]))
    try expect(childTurn?.isSubagent, true, "child session classification is preserved")
    try expect(childTurn?.agentPath, "/root/bounded", "child agent path is preserved")

    var inheritedHistoryState = RolloutState()
    _ = inheritedHistoryState.process(line: event(type: "session_meta", payload: [
        "id": "real-child", "parent_thread_id": "real-parent",
        "source": ["subagent": ["thread_spawn": ["agent_path": "/root/bounded"]]],
    ]))
    _ = inheritedHistoryState.process(line: event(type: "session_meta", payload: [
        "id": "real-parent", "source": "vscode",
    ]))
    let inheritedTurn = inheritedHistoryState.process(line: event(type: "event_msg", payload: [
        "type": "task_started", "turn_id": "inherited-turn",
    ]))
    try expect(inheritedTurn?.sessionID, "real-child", "inherited parent metadata cannot replace child identity")
    try expect(inheritedTurn?.isSubagent, true, "inherited parent metadata cannot erase child classification")
}

func testSubagentHookLedger() throws {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let startPayload: [String: Any] = [
        "hook_event_name": "SubagentStart",
        "session_id": "private-parent-session",
        "turn_id": "private-parent-turn",
        "agent_id": "private-child-agent",
        "agent_type": "luna_worker",
        "model": "gpt-5.6-luna",
        "permission_mode": "default",
        "cwd": "/secret/project/path",
        "transcript_path": "/secret/parent.jsonl",
    ]
    let start = SubagentHookObservation.parse(
        try JSONSerialization.data(withJSONObject: startPayload),
        now: now)
    try expect(start.event, .start, "subagent start event is parsed")
    try expect(start.outcome, .parsed, "complete lifecycle input is accepted")
    try expect(start.agentType, "luna_worker", "safe agent type is retained")
    try expect(start.forkTurns, nil, "Hook payload does not invent missing fork scope")
    try expect(start.hasTranscriptPath, true, "path presence is retained without its value")

    let encodedStart = String(decoding: try JSONEncoder().encode(start), as: UTF8.self)
    for secret in ["private-parent-session", "private-parent-turn", "private-child-agent", "/secret/project/path", "/secret/parent.jsonl"] {
        try expect(encodedStart.contains(secret), false, "subagent ledger omits raw private value")
    }

    let stopPayload: [String: Any] = [
        "hook_event_name": "SubagentStop",
        "session_id": "private-parent-session",
        "turn_id": "private-parent-turn",
        "agent_id": "private-child-agent",
        "agent_type": "luna_worker",
        "model": "gpt-5.6-luna",
        "permission_mode": "default",
        "cwd": "/secret/project/path",
        "transcript_path": "/secret/parent.jsonl",
        "agent_transcript_path": "/secret/child.jsonl",
        "last_assistant_message": "PRIVATE FINAL ANSWER",
        "stop_hook_active": false,
    ]
    let stop = SubagentHookObservation.parse(
        try JSONSerialization.data(withJSONObject: stopPayload),
        now: now.addingTimeInterval(12))
    try expect(stop.event, .stop, "subagent stop event is parsed")
    try expect(stop.agentHash, start.agentHash, "start and stop pair by opaque agent hash")
    try expect(stop.hasAgentTranscriptPath, true, "child transcript presence is retained")
    let encodedStop = String(decoding: try JSONEncoder().encode(stop), as: UTF8.self)
    try expect(encodedStop.contains("PRIVATE FINAL ANSWER"), false, "assistant message is never persisted")
    try expect(encodedStop.contains("/secret/child.jsonl"), false, "child transcript path is never persisted")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteStore(path: root.appendingPathComponent("ledger.sqlite").path)
    try store.recordSubagentHookObservation(start)
    try store.recordSubagentHookObservation(stop)
    let stored = try store.subagentHookObservations(limit: 10)
    try expect(stored.count, 2, "subagent lifecycle observations round-trip")

    let hooks = root.appendingPathComponent("hooks.json")
    let originalStopCommand = "existing-stop-observer"
    let original: [String: Any] = [
        "hooks": [
            "SessionStart": [["hooks": [["command": "start-hook", "type": "command"]]]],
            "SubagentStop": [["hooks": [["command": originalStopCommand, "type": "command"]]]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: hooks)
    let backup = try SubagentObservationHookInstaller.install(
        command: "/Applications/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli",
        hooksFile: hooks,
        now: now)
    try expect(backup != nil, true, "subagent hook install creates a backup")
    let installedRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as! [String: Any]
    let installedEvents = installedRoot["hooks"] as! [String: Any]
    let starts = installedEvents["SubagentStart"] as! [[String: Any]]
    let stops = installedEvents["SubagentStop"] as! [[String: Any]]
    try expect(starts.count, 1, "start observer is installed")
    try expect(stops.count, 2, "existing stop observer is preserved")
    let originalStopHooks = stops[0]["hooks"] as! [[String: Any]]
    try expect(originalStopHooks[0]["command"] as? String, originalStopCommand, "existing stop command is unchanged")
    let secondBackup = try SubagentObservationHookInstaller.install(
        command: "/ignored",
        hooksFile: hooks,
        now: now.addingTimeInterval(1))
    try expect(secondBackup == nil, true, "subagent hook install is idempotent")
}

func testConfigurationHookHealth() throws {
    let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try expect(
        ConfigurationHookHealth.evaluate(
            installed: false, hookModifiedAt: nil, latestPreflightAt: nil,
            latestUserTurnAt: nil, now: installedAt),
        .notInstalled,
        "missing configuration hook")
    try expect(
        ConfigurationHookHealth.evaluate(
            installed: true, hookModifiedAt: installedAt, latestPreflightAt: nil,
            latestUserTurnAt: installedAt.addingTimeInterval(20), now: installedAt.addingTimeInterval(120)),
        .staleAfterInstallation,
        "post-install user activity without hook events is diagnosed")
    try expect(
        ConfigurationHookHealth.evaluate(
            installed: true, hookModifiedAt: installedAt,
            latestPreflightAt: installedAt.addingTimeInterval(30),
            latestUserTurnAt: installedAt.addingTimeInterval(20), now: installedAt.addingTimeInterval(120)),
        .healthy,
        "post-install hook event proves the chain")
}

func testSubagentHookHealthAndTrustInspection() throws {
    let now = Date(timeIntervalSince1970: 1_800_200_000)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hooks = root.appendingPathComponent("hooks.json")
    let config = root.appendingPathComponent("config.toml")
    let command = "'/Applications/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli' --subagent-lifecycle-hook"
    let hooksObject: [String: Any] = [
        "hooks": [
            "SubagentStart": [["hooks": [["command": command, "type": "command"]]]],
            "SubagentStop": [["hooks": [["command": command, "type": "command"]]]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: hooksObject).write(to: hooks)
    let configText = """
    [hooks.state.\"hooks.json:subagent_stop:0:0\"]
    trusted_hash = \"sha256:stop\"
    """
    try Data(configText.utf8).write(to: config)

    let local = SubagentHookConfigurationInspector.inspect(
        hooksFile: hooks,
        configFile: config,
        now: now)
    try expect(local.first(where: { $0.event == .start })?.installed, true, "start hook is installed")
    try expect(local.first(where: { $0.event == .start })?.trusted, false, "missing start trust is untrusted")
    try expect(local.first(where: { $0.event == .start })?.configSectionFound, false, "missing start trust section is visible")
    try expect(local.first(where: { $0.event == .stop })?.trusted, true, "stop trust hash is recognized")

    let appServer = [
        CodexHookMetadata(
            key: "hooks.json:subagent_start:0:0",
            eventName: "SubagentStart",
            command: command,
            enabled: true,
            currentHash: "sha256:start",
            trustStatus: "untrusted"),
        CodexHookMetadata(
            key: "hooks.json:subagent_stop:0:0",
            eventName: "SubagentStop",
            command: command,
            enabled: true,
            currentHash: "sha256:stop",
            trustStatus: "trusted"),
    ]
    let resolved = SubagentHookConfigurationInspector.inspect(
        hooksFile: hooks,
        configFile: config,
        appServerHooks: appServer,
        now: now)
    try expect(resolved.first(where: { $0.event == .start })?.trustStatus, "untrusted", "hooks/list trust status wins")
    try expect(resolved.first(where: { $0.event == .stop })?.trustStatus, "trusted", "hooks/list trusted status is retained")

    let startUntrusted = SubagentHookHealth.evaluate(
        configuration: resolved.first(where: { $0.event == .start })!,
        latestObservationAt: nil,
        latestSubagentActivityAt: nil,
        now: now)
    try expect(startUntrusted.state, .installedButUntrusted, "installed but untrusted state")
    try expect(startUntrusted.reason, .hookUntrusted, "untrusted reason is distinct")

    let stopAwaiting = SubagentHookHealth.evaluate(
        configuration: resolved.first(where: { $0.event == .stop })!,
        latestObservationAt: nil,
        latestSubagentActivityAt: nil,
        now: now)
    try expect(stopAwaiting.state, .awaitingFirstEvent, "trusted empty ledger awaits first event")
    try expect(stopAwaiting.reason, .noSubagentActivity, "empty ledger reason is distinct")

    let stopInactive = SubagentHookHealth.evaluate(
        configuration: resolved.first(where: { $0.event == .stop })!,
        latestObservationAt: nil,
        latestSubagentActivityAt: now.addingTimeInterval(5),
        now: now.addingTimeInterval(10))
    try expect(stopInactive.state, .stale, "rollout activity without hook event is stale")
    try expect(stopInactive.reason, .hookInactive, "inactive hook reason is distinct")

    let trustedAfterPriorActivity = SubagentHookConfiguration(
        event: .start,
        installed: true,
        enabled: true,
        trusted: true,
        trustStatus: "trusted",
        command: command,
        currentHash: "sha256:start",
        configSectionFound: true,
        trustConfiguredAt: now.addingTimeInterval(20),
        inspectedAt: now.addingTimeInterval(20))
    let awaitingAfterTrust = SubagentHookHealth.evaluate(
        configuration: trustedAfterPriorActivity,
        latestObservationAt: nil,
        latestSubagentActivityAt: now.addingTimeInterval(5),
        now: now.addingTimeInterval(25))
    try expect(awaitingAfterTrust.state, .awaitingFirstEvent, "activity before new trust does not mark the Hook stale")

    let stopHealthy = SubagentHookHealth.evaluate(
        configuration: resolved.first(where: { $0.event == .stop })!,
        latestObservationAt: now.addingTimeInterval(8),
        latestSubagentActivityAt: now.addingTimeInterval(5),
        now: now.addingTimeInterval(10))
    try expect(stopHealthy.state, .healthy, "recent lifecycle event is healthy")
}

func testSubagentHookHealthWithRolloutActivity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("codex")
    let sessions = home.appendingPathComponent("sessions/2026/08/21")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let hooks = home.appendingPathComponent("hooks.json")
    let config = home.appendingPathComponent("config.toml")
    let command = "guardian --subagent-lifecycle-hook"
    let hooksObject: [String: Any] = [
        "hooks": [
            "SubagentStart": [["hooks": [["command": command, "type": "command"]]]],
            "SubagentStop": [["hooks": [["command": command, "type": "command"]]]],
        ],
    ]
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: hooksObject).write(to: hooks)
    let configText = """
    [hooks.state.\"hooks.json:subagent_start:0:0\"]
    trusted_hash = \"sha256:start\"
    [hooks.state.\"hooks.json:subagent_stop:0:0\"]
    trusted_hash = \"sha256:stop\"
    """
    try Data(configText.utf8).write(to: config)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_784_102_400)],
        ofItemAtPath: config.path)
    let child = sessions.appendingPathComponent("child.jsonl")
    let childContent = [
        event(type: "session_meta", payload: [
            "id": "child-health", "cwd": "/project", "parent_thread_id": "parent-health",
            "source": ["subagent": ["thread_spawn": ["agent_path": "/root/health-child"]]],
        ]),
        event(type: "event_msg", payload: [
            "type": "sub_agent_activity", "event_id": "call-health",
            "agent_thread_id": "child-health", "agent_path": "/root/health-child", "kind": "started",
        ]),
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "child-turn"]),
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try Data(childContent.utf8).write(to: child)
    let store = try SQLiteStore(path: root.appendingPathComponent("guardian.sqlite").path)
    let scanner = SessionScanner(store: store, codexHome: home)
    _ = try scanner.initialIndex()
    let snapshot = try scanner.subagentHookHealth(now: Date(timeIntervalSince1970: 1_800_300_000))
    try expect(snapshot.subagentActivityCount, 1, "rollout subagent activity is counted")
    try expect(snapshot.start.state, .stale, "zero start Hook events with rollout activity is stale")
    try expect(snapshot.start.reason, .hookInactive, "rollout activity distinguishes inactive Hook")
    try expect(snapshot.stop.state, .stale, "zero stop Hook events with rollout activity is stale")
    try store.recordSubagentHookHealthDiagnostic(SubagentHookHealthDiagnostic(snapshot: snapshot))
    try expect(
        try store.subagentHookHealthDiagnostics(limit: 1).first?.snapshot,
        snapshot,
        "health state has an independent diagnostic ledger")
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
    let hiddenLog = sessions.appendingPathComponent("hidden-legacy.jsonl")
    let hiddenContent = olderContent.replacingOccurrences(of: "older-local", with: "hidden-legacy")
    try Data(hiddenContent.utf8).write(to: hiddenLog)
    let unassignedLog = sessions.appendingPathComponent("unassigned-legacy.jsonl")
    let unassignedContent = olderContent.replacingOccurrences(of: "older-local", with: "unassigned-legacy")
    try Data(unassignedContent.utf8).write(to: unassignedLog)
    let projectVisibleLog = sessions.appendingPathComponent("project-visible.jsonl")
    try Data(olderContent.replacingOccurrences(of: "older-local", with: "project-visible").utf8).write(to: projectVisibleLog)
    let worktreeVisibleLog = sessions.appendingPathComponent("worktree-visible.jsonl")
    let worktreeVisibleContent = olderContent
        .replacingOccurrences(of: "older-local", with: "worktree-visible")
        .replacingOccurrences(of: "/projects/older", with: "/home/test/.codex/worktrees/abc/older")
    try Data(worktreeVisibleContent.utf8).write(to: worktreeVisibleLog)
    let automaticLog = sessions.appendingPathComponent("automatic-handoff.jsonl")
    try Data(olderContent.replacingOccurrences(of: "older-local", with: "automatic-handoff").utf8).write(to: automaticLog)
    let wrapperLog = sessions.appendingPathComponent("delegation-wrapper.jsonl")
    try Data(olderContent.replacingOccurrences(of: "older-local", with: "delegation-wrapper").utf8).write(to: wrapperLog)
    let desktopState = """
    {
      "local-projects": {
        "visible-project": {"id":"visible-project","rootPaths":["/projects/older"]}
      },
      "thread-project-assignments": {
        "older-local": {"projectKind":"local","projectId":"visible-project"},
        "hidden-legacy": {"projectKind":"local","projectId":"removed-project"},
        "delegated": {"projectKind":"local","projectId":"visible-project"},
        "internal": {"projectKind":"local","projectId":"visible-project"}
      },
      "projectless-thread-ids": []
    }
    """
    try Data(desktopState.utf8).write(to: home.appendingPathComponent(".codex-global-state.json"))
    let database = home.appendingPathComponent("state_5.sqlite")
    let sql = """
    CREATE TABLE threads (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, archived INTEGER NOT NULL,
        source TEXT NOT NULL, rollout_path TEXT NOT NULL, thread_source TEXT, cwd TEXT,
        preview TEXT NOT NULL DEFAULT ''
    );
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('older-local', '较早的本地会话', 0, 'vscode', '\(olderLog.path)', 'user', '/projects/older', 'visible');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('hidden-legacy', '侧边栏已移除', 0, 'vscode', '\(hiddenLog.path)', 'user', '/projects/older', '');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('unassigned-legacy', '仅因目录匹配的历史会话', 0, 'vscode', '\(unassignedLog.path)', 'user', '/projects/older', '');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('project-visible', '项目分组可见会话', 0, 'vscode', '\(projectVisibleLog.path)', 'user', '/projects/older', 'visible');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('worktree-visible', '工作树续接会话', 0, 'vscode', '\(worktreeVisibleLog.path)', 'user', '/home/test/.codex/worktrees/abc/older', '');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('automatic-handoff', '自动交接', 0, 'exec', '\(automaticLog.path)', 'user', '/projects/older', 'visible');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('delegation-wrapper', '<codex_delegation>内部包装</codex_delegation>', 0, 'vscode', '\(wrapperLog.path)', 'subagent', '/projects/older', 'visible');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('internal', '内部任务', 0, '{"subagent":{"other":"guardian"}}', '\(olderLog.path)', 'subagent', '/projects/older', 'visible');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('delegated', '委托任务', 0, 'vscode', '\(delegatedLog.path)', 'subagent', '/projects/older', 'visible');
    INSERT INTO threads (id, title, archived, source, rollout_path, thread_source, cwd, preview) VALUES ('archived', '已归档', 1, 'vscode', '\(olderLog.path)', 'user', '/projects/older', 'visible');
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
    let visibleSessions = Set(["older-local", "delegated", "project-visible", "worktree-visible"])
    try expect(Set(snapshot.sessions.map(\.sessionID)), visibleSessions, "desktop-visible rollouts indexed")
    guard let session = snapshot.sessions.first(where: { $0.sessionID == "older-local" }) else {
        throw TestFailure.assertion("sidebar-visible session missing")
    }
    try expect(session.activity, .stopped, "completed sidebar session state")
    try expect(session.usage.total, 130, "sidebar session real token facts")

    // The global recent-turn budget must not push an explicitly visible but
    // older sidebar task out of the menu-bar snapshot.
    let now = Date()
    for index in 0...500 {
        var offSidebar = TurnRecord(
            sessionID: "off-sidebar-\(index)",
            turnID: "turn-\(index)",
            ordinal: 1,
            cwd: "/projects/off-sidebar",
            startedAt: now.addingTimeInterval(Double(index)))
        offSidebar.status = .completed
        offSidebar.completedAt = offSidebar.startedAt
        try store.upsert(turn: offSidebar)
    }
    try expect(
        Set(try scanner.snapshot().sessions.map(\.sessionID)),
        visibleSessions,
        "sidebar-visible history survives the global recent-turn budget")

    let refreshedQuota = event(type: "event_msg", payload: [
        "type": "token_count",
        "info": [
            "total_token_usage": usage(140, 90, 12),
            "last_token_usage": usage(20, 10, 2),
            "model_context_window": 258_400,
        ],
        "rate_limits": ["primary": [
            "used_percent": 2,
            "window_minutes": 10_080,
            "resets_at": 1_800_123_456,
        ]],
    ])
    let resumed = [
        event(type: "event_msg", payload: ["type": "task_started", "turn_id": "resumed-turn"]),
        refreshedQuota,
    ].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    try append(resumed, to: olderLog)
    _ = try scanner.refresh(activePaths: [], discoverNew: true)
    let refreshed = try scanner.snapshot()
    try expect(refreshed.latestQuota?.remainingPercent, 98, "resumed older rollout refreshes quota")
    try expect(
        refreshed.latestQuota?.resetsAt,
        Date(timeIntervalSince1970: 1_800_123_456),
        "resumed older rollout refreshes reset time")
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
    try expect(
        snapshot.sessions.filter { $0.risk == .red }.allSatisfy { $0.advice == .watch },
        true,
        "context pressure alone never recommends migration")
    try expect(snapshot.recentHealthySessions.map(\.sessionID), ["recent"], "healthy recent grouping")
    try expect(snapshot.highestRisk, .amber, "historical red not realtime radar")

    let recentFirst = DashboardSnapshot(
        active: [makeTurn(session: "old-active", pressure: 0.20, activityAge: 50)],
        recent: [
            makeTurn(session: "new-healthy", pressure: 0.20, status: .completed, activityAge: 2),
            makeTurn(session: "middle-risk", pressure: 0.80, status: .completed, activityAge: 20),
        ],
        indexedFiles: 3,
        updatedAt: now)
    try expect(
        recentFirst.sessions.map(\.sessionID),
        ["new-healthy", "middle-risk", "old-active"],
        "all menu sessions are sorted by most recent execution")

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
        resumedSnapshot.resumedGuardedSession(
            from: snapshot,
            requiringUserAttention: ["resume-fresh"])?.sessionID,
        nil,
        "executing task never triggers resume warning")

    let protectedCompaction = makeTurn(
        session: "protected", ordinal: 1, pressure: 0.30, compactions: 1,
        status: .completed, activityAge: 200)
    let protectedStopped = makeTurn(
        session: "protected", ordinal: 2, pressure: 0.81,
        status: .completed, activityAge: 100)
    let protectedPrevious = DashboardSnapshot(
        active: [], recent: [protectedStopped, protectedCompaction], indexedFiles: 1, updatedAt: now)
    let protectedWaiting = makeTurn(
        session: "protected", ordinal: 3, pressure: 0.82, activityAge: 90)
    let protectedResumed = DashboardSnapshot(
        active: [protectedWaiting], recent: [protectedStopped, protectedCompaction],
        indexedFiles: 1, updatedAt: now)
    try expect(
        protectedResumed.resumedGuardedSession(
            from: protectedPrevious,
            requiringUserAttention: ["protected"])?.sessionID,
        nil,
        "same long task never warns from pressure and rebound alone")
    try expect(
        protectedResumed.resumedGuardedSession(
            from: protectedPrevious,
            requiringUserAttention: [])?.sessionID,
        nil,
        "idle-age heuristic alone never triggers resume warning")
    try expect(
        protectedResumed.resumedGuardedSession(
            from: protectedPrevious,
            excluding: ["protected"],
            requiringUserAttention: ["protected"])?.sessionID,
        nil,
        "guardian-owned or dismissed session is excluded")

    let recoveredWaiting = makeTurn(
        session: "resume-fresh", ordinal: 2, pressure: 0.65, activityAge: 90)
    let recoveredSnapshot = DashboardSnapshot(
        active: [recoveredWaiting], recent: [stoppedRed], indexedFiles: 1, updatedAt: now)
    try expect(
        recoveredSnapshot.resumedGuardedSession(
            from: snapshot,
            requiringUserAttention: ["resume-fresh"])?.sessionID,
        nil,
        "historical red state is rechecked against current risk")

    let stoppedAmber = makeTurn(session: "resume-watch", pressure: 0.65, status: .completed)
    let previousAmber = DashboardSnapshot(
        active: [], recent: [stoppedAmber], indexedFiles: 1, updatedAt: now)
    let resumedAmber = makeTurn(session: "resume-watch", ordinal: 2, pressure: 0.66, activityAge: 1)
    let resumedAmberSnapshot = DashboardSnapshot(
        active: [resumedAmber], recent: [stoppedAmber], indexedFiles: 1, updatedAt: now)
    try expect(
        resumedAmberSnapshot.resumedGuardedSession(
            from: previousAmber,
            requiringUserAttention: ["resume-watch"])?.sessionID,
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

    let recentCompactions = DashboardSnapshot(
        active: [],
        recent: [
            makeTurn(session: "recent-compactions", ordinal: 3, pressure: 0.30, status: .completed, activityAge: 1),
            makeTurn(session: "recent-compactions", ordinal: 2, pressure: 0.30, compactions: 1, status: .completed, activityAge: 2),
            makeTurn(session: "recent-compactions", ordinal: 1, pressure: 0.30, compactions: 1, status: .completed, activityAge: 3),
        ],
        indexedFiles: 1,
        updatedAt: now).sessions.first!
    try expect(recentCompactions.compactions, 2, "lifetime compactions retained for display")
    try expect(recentCompactions.recentCompactions, 2, "recent compaction window")
    try expect(recentCompactions.risk, .amber, "compaction count alone never becomes red")

    let oldCompactions = DashboardSnapshot(
        active: [],
        recent: [
            makeTurn(session: "old-compactions", ordinal: 5, pressure: 0.30, status: .completed, activityAge: 1),
            makeTurn(session: "old-compactions", ordinal: 4, pressure: 0.30, status: .completed, activityAge: 2),
            makeTurn(session: "old-compactions", ordinal: 3, pressure: 0.30, status: .completed, activityAge: 3),
            makeTurn(session: "old-compactions", ordinal: 2, pressure: 0.30, compactions: 1, status: .completed, activityAge: 4),
            makeTurn(session: "old-compactions", ordinal: 1, pressure: 0.30, compactions: 1, status: .completed, activityAge: 5),
        ],
        indexedFiles: 1,
        updatedAt: now).sessions.first!
    try expect(oldCompactions.compactions, 2, "old lifetime compactions retained")
    try expect(oldCompactions.recentCompactions, 0, "old compactions expire from risk window")
    try expect(oldCompactions.risk, .green, "old compactions do not create permanent risk")

    var suppressions = ResumeWarningSuppressions()
    suppressions.suppress("protected")
    suppressions.reconcile(with: protectedResumed.sessions)
    try expect(suppressions.isSuppressed("protected"), true, "dismissal persists while risk remains")
    let protectedHealthy = DashboardSnapshot(
        active: [],
        recent: [makeTurn(session: "protected", ordinal: 4, pressure: 0.20, status: .completed)],
        indexedFiles: 1,
        updatedAt: now).sessions
    suppressions.reconcile(with: protectedHealthy)
    try expect(suppressions.isSuppressed("protected"), false, "healthy state clears dismissal suppression")

    var warningBudget = ResumeWarningBudget(maximumWarningsPerHour: 2, perSessionCooldown: 600)
    try expect(warningBudget.consumeIfAllowed(sessionID: "one", at: now), true, "first warning allowed")
    try expect(
        warningBudget.consumeIfAllowed(sessionID: "one", at: now.addingTimeInterval(599)),
        false,
        "per-session warning cooldown")
    try expect(
        warningBudget.consumeIfAllowed(sessionID: "two", at: now.addingTimeInterval(1)),
        true,
        "second session within hourly budget")
    try expect(
        warningBudget.consumeIfAllowed(sessionID: "three", at: now.addingTimeInterval(2)),
        false,
        "global hourly warning budget")
    try expect(
        warningBudget.consumeIfAllowed(sessionID: "one", at: now.addingTimeInterval(3_601)),
        true,
        "warning budget recovers after an hour")

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
        .success,
        "explicit completion feedback wins over a briefly stale executing snapshot")
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

    func live(_ kind: LiveActivityKind, age: TimeInterval = 0) -> SessionLiveActivity {
        SessionLiveActivity(event: LiveActivityEvent(
            kind: kind,
            occurredAt: now.addingTimeInterval(-age)))
    }
    let activeTurn = makeTurn(session: "live")
    try expect(
        snapshot(active: [activeTurn]).petAnimationState(liveActivities: ["live": live(.readingFile)]),
        .thinking,
        "reading activity drives review animation")
    try expect(
        snapshot(active: [activeTurn]).petAnimationState(liveActivities: ["live": live(.runningCommand)]),
        .idle,
        "command activity drives running animation")
    try expect(
        snapshot(active: [activeTurn]).petAnimationState(liveActivities: ["live": live(.waitingForUser)]),
        .working,
        "waiting activity drives waiting animation")
    try expect(
        snapshot(active: [activeTurn]).petAnimationState(liveActivities: ["live": live(.completed)]),
        .success,
        "live completion drives immediate success animation")
    let secondActive = makeTurn(session: "other")
    try expect(
        snapshot(active: [activeTurn, secondActive]).petAnimationState(liveActivities: [
            "live": live(.waitingForUser, age: 10),
            "other": live(.runningCommand),
        ]),
        .working,
        "user attention wins across multiple tasks")
    try expect(
        snapshot(active: [activeTurn]).petAnimationState(
            liveActivities: ["live": live(.failed)],
            isHovered: true),
        .guardian,
        "direct hover remains the highest pet interaction")

    let stopped = makeTurn(session: "completed", status: .completed)
    let interrupted = makeTurn(session: "interrupted", status: .interrupted)
    let stillActive = makeTurn(session: "active")
    try expect(
        snapshot(active: [stillActive], recent: [stopped, interrupted]).completedSessionIDs(
            previouslyActive: Set(["completed", "interrupted", "active", "missing"])),
        Set(["completed"]),
        "completed session transition excludes interruption")
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

    let leftScreen = CGRect(x: 0, y: 25, width: 1_440, height: 875)
    let rightScreen = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
    let crossDisplayAnchor = CGPoint(x: 1_700, y: 240)
    let petScreen = FloatingPetGeometry.visibleFrame(
        forPetAnchor: crossDisplayAnchor,
        petSize: petSize,
        screenVisibleFrames: [leftScreen, rightScreen])
    try expect(petScreen, rightScreen, "expanded card does not select a display from its leading edge")
    let crossDisplayOrigin = FloatingPetGeometry.panelOrigin(
        forPetAnchor: crossDisplayAnchor,
        panelSize: expandedSize)
    try expect(
        crossDisplayOrigin.x + expandedSize.width,
        crossDisplayAnchor.x,
        "cross-display expansion keeps the pet as the fixed trailing anchor")
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
    try expect(
        stabilized.map(\.sessionID),
        partial.map(\.sessionID) + ["second"],
        "partial refresh preserves current ordering and missing frozen cards")
    try expect(
        stabilized.first(where: { $0.sessionID == "first" })?.latestTurn?.latestPromptInput,
        3_000,
        "present session refreshes in place")
    try expect(
        stabilized.first(where: { $0.sessionID == "second" })?.latestTurn?.latestPromptInput,
        2_000,
        "temporarily missing session keeps last snapshot")

    let newlyDiscovered = DashboardSnapshot(
        active: [turn(sessionID: "third", input: 4_000), turn(sessionID: "first", input: 5_000)],
        recent: [],
        sessionTitles: ["third": "Third", "first": "First"],
        indexedFiles: 2,
        updatedAt: now).activeSessions
    let withNewSession = FloatingPetGeometry.stabilizedSessions(
        frozen: [initial.first(where: { $0.sessionID == "first" })!],
        current: newlyDiscovered)
    try expect(
        withNewSession.map(\.sessionID),
        newlyDiscovered.map(\.sessionID),
        "newly discovered sessions appear immediately in scanner order")
}

func testFloatingVisibilityPreservesFrameAfterRestore() throws {
    var lifecycle = FloatingPetVisibilityLifecycle()
    try expect(
        lifecycle.nextShowPlacement(),
        .initializeFromSavedAnchor,
        "first show initializes from the persisted anchor")
    try expect(
        lifecycle.nextShowPlacement(),
        .preserveCurrentFrame,
        "show after hiding preserves the current panel frame")
    try expect(
        lifecycle.nextShowPlacement(),
        .preserveCurrentFrame,
        "later visibility toggles keep preserving the frame")
}

func testSessionRefreshCadence() throws {
    try expect(
        SessionRefreshCadence.interval(statusPanelVisible: false, floatingWorkspaceVisible: false),
        10,
        "collapsed background cadence")
    try expect(
        SessionRefreshCadence.interval(statusPanelVisible: true, floatingWorkspaceVisible: false),
        2,
        "menu panel fast cadence")
    try expect(
        SessionRefreshCadence.interval(statusPanelVisible: false, floatingWorkspaceVisible: true),
        2,
        "floating workspace fast cadence")
}

func testXiaoxinSpeechScheduling() throws {
    try expect(
        XiaoxinSpeechCatalog.lines(for: .welcome, intensity: .off),
        [],
        "disabled personality has no lines")
    try expect(
        XiaoxinSpeechCatalog.lines(for: .hover, intensity: .light).count,
        2,
        "light mode includes hover feedback")
    let activeHover = XiaoxinSpeechCatalog.lines(for: .hover, intensity: .active)
    try expect(activeHover.count, 4, "active mode adds hover quips")
    try expect(
        XiaoxinSpeechCatalog.lines(for: .drag, intensity: .light).count,
        2,
        "light mode includes drag feedback")
    try expect(
        XiaoxinSpeechCatalog.lines(for: .doubleClick, intensity: .active).count,
        4,
        "active mode includes double-click quips")
    try expect(
        XiaoxinSpeechCatalog.lines(for: .calibrationReady, intensity: .light).count,
        1,
        "calibration milestone has one low-noise speech line")
    try expect(
        activeHover.allSatisfy { $0.localizationKey.hasPrefix("pet.speech.") },
        true,
        "speech uses semantic localization keys")
    let semanticContexts: [XiaoxinSpeechContext] = [
        .thinking, .reading, .runningCommand, .callingTool, .editing,
        .waitingForUser, .responding, .failed,
    ]
    try expect(
        semanticContexts.allSatisfy {
            !XiaoxinSpeechCatalog.lines(for: $0, intensity: .light).isEmpty
        },
        true,
        "every live semantic stage has a light-mode line")
    try expect(LiveActivityKind.waitingForUser.needsUserAttention, true, "waiting requires attention")
    try expect(LiveActivityKind.failed.needsUserAttention, true, "failure requires attention")
    try expect(LiveActivityKind.editingFiles.speechContext, .editing, "editing speech mapping")

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var scheduler = XiaoxinSpeechScheduler()
    let first = scheduler.nextLine(
        for: .working,
        intensity: .active,
        now: start)
    let blockedByGap = scheduler.nextLine(
        for: .working,
        intensity: .active,
        now: start.addingTimeInterval(2))
    let second = scheduler.nextLine(
        for: .working,
        intensity: .active,
        now: start.addingTimeInterval(9))
    let blockedByCooldown = scheduler.nextLine(
        for: .working,
        intensity: .active,
        now: start.addingTimeInterval(18))
    let availableAfterCooldown = scheduler.nextLine(
        for: .working,
        intensity: .active,
        now: start.addingTimeInterval(610))

    try expect(first?.localizationKey, "pet.speech.working.my_turn", "first working line")
    try expect(blockedByGap == nil, true, "global speech gap")
    try expect(second?.localizationKey, "pet.speech.working.watch_me", "rotation uses another line")
    try expect(blockedByCooldown == nil, true, "recent lines do not repeat")
    try expect(availableAfterCooldown != nil, true, "line returns after cooldown")

    var interactiveScheduler = XiaoxinSpeechScheduler()
    let hoverOne = interactiveScheduler.nextLine(
        for: .hover,
        intensity: .light,
        now: start,
        minimumGap: 20,
        bypassRepeatCooldown: true)
    let hoverTooSoon = interactiveScheduler.nextLine(
        for: .hover,
        intensity: .light,
        now: start.addingTimeInterval(10),
        minimumGap: 20,
        bypassRepeatCooldown: true)
    let hoverTwo = interactiveScheduler.nextLine(
        for: .hover,
        intensity: .light,
        now: start.addingTimeInterval(21),
        minimumGap: 20,
        bypassRepeatCooldown: true)
    try expect(hoverOne?.localizationKey, "pet.speech.hover.oh", "first hover feedback")
    try expect(hoverTooSoon == nil, true, "hover feedback respects interaction cooldown")
    try expect(hoverTwo?.localizationKey, "pet.speech.hover.hey", "hover feedback rotates")
}

func testLiveActivityPrivacyAndMapping() throws {
    let parser = LiveActivityParser()
    let command = parser.parse(line: event(type: "response_item", payload: [
        "type": "custom_tool_call", "name": "functions.exec", "input": "TOP-SECRET --token abc",
    ]))
    try expect(command?.kind, .runningCommand, "command stage")
    try expect(command?.publicSummary == nil, true, "tool arguments never become a summary")

    let output = parser.parse(line: event(type: "response_item", payload: [
        "type": "custom_tool_call_output", "output": "TOP-SECRET raw output",
    ]))
    try expect(output == nil, true, "tool output ignored")
    let reasoning = parser.parse(line: event(type: "response_item", payload: [
        "type": "reasoning", "summary": ["private chain"], "encrypted_content": "ciphertext",
    ]))
    try expect(reasoning == nil, true, "reasoning ignored")

    let patch = parser.parse(line: event(type: "event_msg", payload: [
        "type": "patch_apply_end", "changes": ["a.swift": [:], "b.swift": [:]],
        "stdout": "private output", "stderr": "private error",
    ]))
    try expect(patch?.kind, .editingFiles, "patch stage")
    try expect(patch?.detailCount, 2, "patch file count")

    let publicText = String(repeating: "可公开进展 ", count: 40) + "```private command```<oai-mem-citation>hidden</oai-mem-citation>"
    let response = parser.parse(line: event(type: "event_msg", payload: [
        "type": "agent_message", "message": publicText,
    ]))
    try expect(response?.kind, .responding, "response stage")
    try expect((response?.publicSummary?.count ?? 0) <= LiveActivityParser.maximumSummaryCharacters + 1, true, "summary truncation")
    try expect(response?.publicSummary?.contains("private command") == false, true, "code block removed")
    try expect(response?.publicSummary?.contains("oai-mem-citation") == false, true, "memory citation removed")

    let completed = parser.parse(line: event(type: "event_msg", payload: [
        "type": "task_complete", "last_agent_message": "最终公开答复",
    ]))
    try expect(completed?.kind, .completed, "completion stage")
    try expect(completed?.publicSummary, "最终公开答复", "completion summary")
}

func testLiveActivityFragmentationAndIsolation() throws {
    let lineA = event(type: "response_item", payload: ["type": "function_call", "name": "read_file"])
    let lineB = event(type: "event_msg", payload: ["type": "agent_message", "message": "会话 B 的公开输出"])
    var cursorA = LiveActivityStreamCursor()
    var cursorB = LiveActivityStreamCursor()
    let split = lineA.count / 2
    try expect(cursorA.consume(lineA.prefix(split)).isEmpty, true, "partial JSONL held")
    var remainderA = Data(lineA.suffix(from: split))
    remainderA.append(0x0A)
    let eventsA = cursorA.consume(remainderA)
    var completeB = lineB
    completeB.append(0x0A)
    let eventsB = cursorB.consume(completeB)
    try expect(eventsA.map(\.kind), [.readingFile], "session A stage")
    try expect(eventsB.map(\.kind), [.responding], "session B stage")
    try expect(eventsB.first?.publicSummary, "会话 B 的公开输出", "session B summary isolated")
}

func testLiveActivityTruncationAndPartialFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("rollout.jsonl")
    var started = event(type: "event_msg", payload: ["type": "task_started"])
    started.append(0x0A)
    try started.write(to: log)
    var cursor = LiveActivityStreamCursor()
    try expect(try cursor.readAvailable(at: log).map(\.kind), [.thinking], "initial file replay")

    let response = event(type: "event_msg", payload: ["type": "agent_message", "message": "分片完成"])
    let split = response.count / 2
    try append(String(decoding: response.prefix(split), as: UTF8.self), to: log)
    try expect(try cursor.readAvailable(at: log).isEmpty, true, "partial file line held")
    try append(String(decoding: response.suffix(from: split), as: UTF8.self) + "\n", to: log)
    try expect(try cursor.readAvailable(at: log).map(\.kind), [.responding], "partial file line completed")

    var completed = event(type: "event_msg", payload: ["type": "task_complete"])
    completed.append(0x0A)
    try completed.write(to: log, options: .atomic)
    try expect(try cursor.readAvailable(at: log).map(\.kind), [.completed], "rotation or truncation resets cursor")
}

func testLiveActivityMonitorLatency() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("live.jsonl")
    var started = event(type: "event_msg", payload: ["type": "task_started"])
    started.append(0x0A)
    try started.write(to: log)

    let received = DispatchSemaphore(value: 0)
    let monitor = SessionLiveActivityMonitor { sessionID, event in
        if sessionID == "latency", event.kind == .responding { received.signal() }
    }
    monitor.synchronize(pathsBySessionID: ["latency": log.path])
    Thread.sleep(forTimeInterval: 0.3)
    let began = Date()
    var response = event(type: "event_msg", payload: ["type": "agent_message", "message": "实时更新"])
    response.append(0x0A)
    try append(String(decoding: response, as: UTF8.self), to: log)
    let result = received.wait(timeout: .now() + 1.0)
    let elapsed = Date().timeIntervalSince(began)
    monitor.stop()
    try expect(result == .success, true, "monitor delivered within one second")
    try expect(elapsed < 1.0, true, "monitor measured latency")
}

func testHandoffShadowTelemetry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(path: root.appendingPathComponent("shadow.sqlite").path)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeCompletedTurn(
        session: String,
        ordinal: Int,
        pressure: Double,
        compactions: Int = 0
    ) -> TurnRecord {
        var turn = TurnRecord(
            sessionID: session,
            turnID: "\(session)-\(ordinal)",
            ordinal: ordinal,
            cwd: "/private/secret/project",
            startedAt: now.addingTimeInterval(Double(ordinal) - 1),
            status: .completed)
        turn.completedAt = now.addingTimeInterval(Double(ordinal))
        turn.lastActivityAt = turn.completedAt
        turn.contextWindow = 100_000
        turn.latestPromptInput = Int(pressure * 100_000)
        turn.compactions = compactions
        turn.usage.input = 1_000 + ordinal
        turn.usage.cachedInput = 600
        turn.usage.cacheWriteInput = 100
        turn.usage.uncachedInput = 300 + ordinal
        turn.usage.output = 50
        turn.usage.reasoningOutput = 20
        turn.usage.total = turn.usage.input + turn.usage.output
        return turn
    }

    var completedTurns: [TurnRecord] = []
    for ordinal in 1...6 {
        let turn = makeCompletedTurn(session: "shadow", ordinal: ordinal, pressure: 0.20)
        completedTurns.append(turn)
        let snapshot = DashboardSnapshot(
            active: [],
            recent: completedTurns,
            indexedFiles: 1,
            updatedAt: now.addingTimeInterval(100))
        let session = snapshot.sessions.first!
        let decision = HandoffShadowPolicy.evaluate(session: session, completedTurn: turn)!
        try expect(decision.recommendation, .continueCurrent, "healthy shadow recommendation")
        try store.recordShadowCompletion(decision: decision, completedTurn: turn)
        if ordinal == 2 {
            try store.recordShadowCompletion(decision: decision, completedTurn: turn)
        }
    }

    let decisions = try store.shadowDecisions(limit: 20)
    try expect(decisions.count, 6, "shadow decision idempotency")
    let first = decisions.first { $0.turnOrdinal == 1 }!
    try expect(first.completedTurnsObserved, 5, "five follow-up turns observed")
    try expect(Set(first.outcomes.keys), Set([1, 3, 5]), "one three five outcome windows")
    try expect(first.outcomes[5]?.usage.total ?? 0 > 0, true, "follow-up token usage accumulated")
    let encodedDecision = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
    try expect(encodedDecision.contains("/private/secret/project"), false, "shadow decision excludes cwd")

    let compacted = makeCompletedTurn(
        session: "rebound", ordinal: 1, pressure: 0.30, compactions: 1)
    let reboundTurn = makeCompletedTurn(session: "rebound", ordinal: 2, pressure: 0.81)
    let reboundSnapshot = DashboardSnapshot(
        active: [], recent: [reboundTurn, compacted], indexedFiles: 1, updatedAt: now)
    let reboundDecision = HandoffShadowPolicy.evaluate(
        session: reboundSnapshot.sessions.first!,
        completedTurn: reboundTurn)!
    try expect(reboundDecision.recommendation, .prepareHandoff, "rebound shadow recommendation")
    try expect(reboundDecision.reasons.contains(.postCompactionRebound), true, "rebound reason code")

    var source = makeCompletedTurn(session: "source", ordinal: 1, pressure: 0.80)
    source.usage.input = 100
    source.usage.cachedInput = 60
    source.usage.cacheWriteInput = 10
    source.usage.uncachedInput = 30
    source.usage.output = 20
    source.usage.reasoningOutput = 5
    source.usage.total = 120
    var destination = makeCompletedTurn(session: "destination", ordinal: 1, pressure: 0.20)
    destination.usage.input = 50
    destination.usage.cachedInput = 10
    destination.usage.cacheWriteInput = 5
    destination.usage.uncachedInput = 35
    destination.usage.output = 5
    destination.usage.reasoningOutput = 1
    destination.usage.total = 55
    try store.upsert(turn: source)
    try store.upsert(turn: destination)
    let secretPayload = "private handoff body should not be stored"
    let pending = HandoffCostRecord(
        sourceSessionID: "source",
        destinationSessionID: "destination",
        sourceSummaryTurnID: source.turnID!,
        destinationAcknowledgementTurnID: destination.turnID!,
        preparationMethod: .fullSourceSummary,
        startedAt: now,
        payload: secretPayload)
    try store.upsertHandoffCost(pending)
    try expect(try store.handoffCosts().first?.status, .pending, "handoff cost starts pending")
    try store.reconcilePendingHandoffCosts(at: now.addingTimeInterval(10))
    let cost = try store.handoffCosts().first!
    try expect(cost.status, .acknowledged, "visible acknowledgement is not continuation")
    try expect(cost.completedAt, nil, "acknowledgement does not claim continuation")
    try expect(cost.totalUsage.input, 150, "handoff exact input")
    try expect(cost.totalUsage.cachedInput, 70, "handoff exact cached input")
    try expect(cost.totalUsage.cacheWriteInput, 15, "handoff exact cache-write input")
    try expect(cost.totalUsage.uncachedInput, 65, "handoff exact uncached input")
    try expect(cost.totalUsage.output, 25, "handoff exact output")
    try expect(cost.payloadCharacters, secretPayload.count, "handoff payload character count")
    let encodedCost = String(decoding: try JSONEncoder().encode(cost), as: UTF8.self)
    try expect(encodedCost.contains(secretPayload), false, "handoff ledger excludes payload body")

    let summary = try store.shadowTelemetrySummary()
    try expect(summary.decisionCount, 6, "shadow aggregate decision count")
    try expect(summary.acknowledgedHandoffCosts, 1, "shadow aggregate acknowledged handoff")
    try expect(summary.continuedHandoffCosts, 0, "shadow aggregate has no false continuation")
    try expect(summary.handoffUsage.total, 175, "shadow aggregate handoff tokens")

    let quickPending = HandoffCostRecord(
        sourceSessionID: "source-quick",
        destinationSessionID: "destination",
        sourceSummaryTurnID: nil,
        destinationAcknowledgementTurnID: destination.turnID!,
        preparationMethod: .quickCapsule,
        startedAt: now.addingTimeInterval(20),
        payload: "local capsule")
    try store.upsertHandoffCost(quickPending)
    try store.reconcilePendingHandoffCosts()
    let quickCost = try store.handoffCosts().first { $0.id == quickPending.id }!
    try expect(quickCost.status, .acknowledged, "quick handoff records visible acknowledgement")
    try expect(quickCost.sourceUsage, TokenUsage(), "quick handoff source cost is zero")
    try expect(quickCost.totalUsage.total, destination.usage.total, "quick handoff counts destination only")
    let updatedSummary = try store.shadowTelemetrySummary()
    try expect(updatedSummary.quickCapsuleHandoffs, 1, "quick handoff aggregate count")
    try expect(updatedSummary.fullSummaryHandoffs, 1, "full-summary handoff aggregate count")
    try expect(updatedSummary.acknowledgementTurnHandoffs, 2, "legacy delivery aggregate count")

    let injected = HandoffCostRecord(
        sourceSessionID: "source-injected",
        destinationSessionID: "destination-injected",
        sourceSummaryTurnID: nil,
        destinationAcknowledgementTurnID: nil,
        preparationMethod: .quickCapsule,
        deliveryMethod: .historyInjection,
        startedAt: now.addingTimeInterval(30),
        payload: "local capsule")
    try expect(injected.status, .seeded, "history injection is only seeded initially")
    try expect(injected.sourceUsage, TokenUsage(), "injected source cost is zero")
    try expect(injected.destinationUsage, TokenUsage(), "injected destination cost is zero")
    try expect(injected.totalUsage.total, 0, "zero-model handoff total is zero")
    try store.upsertHandoffCost(injected)
    let fullInjected = HandoffCostRecord(
        sourceSessionID: "source",
        destinationSessionID: "destination-injected-full",
        sourceSummaryTurnID: source.turnID!,
        destinationAcknowledgementTurnID: nil,
        preparationMethod: .fullSourceSummary,
        deliveryMethod: .historyInjection,
        startedAt: now.addingTimeInterval(31),
        payload: "bounded summary")
    try expect(fullInjected.status, .seeded, "full summary injection remains seeded while usage reconciles")
    try store.upsertHandoffCost(fullInjected)
    try store.reconcilePendingHandoffCosts()
    let reconciledFullInjection = try store.handoffCosts().first { $0.id == fullInjected.id }!
    try expect(reconciledFullInjection.status, .seeded, "source usage does not imply destination readiness")
    try expect(reconciledFullInjection.destinationUsage, TokenUsage(), "injected destination remains zero")
    try expect(reconciledFullInjection.totalUsage, source.usage, "full injection cost equals source summary")
    var syntheticBootstrap = makeCompletedTurn(
        session: "destination-injected-full", ordinal: 1, pressure: 0.10)
    syntheticBootstrap.turnID = "auto-compact-1"
    syntheticBootstrap.startedAt = now.addingTimeInterval(35)
    syntheticBootstrap.completedAt = nil
    syntheticBootstrap.status = .running
    try store.upsert(turn: syntheticBootstrap)
    try store.reconcilePendingHandoffCosts()
    let afterBootstrap = try store.handoffCosts().first { $0.id == fullInjected.id }!
    try expect(afterBootstrap.status, .seeded, "auto-compact bootstrap is not a real continuation")
    var firstContinuation = makeCompletedTurn(
        session: "destination-injected-full", ordinal: 2, pressure: 0.10)
    firstContinuation.startedAt = now.addingTimeInterval(40)
    firstContinuation.completedAt = now.addingTimeInterval(41)
    try store.upsert(turn: firstContinuation)
    try store.reconcilePendingHandoffCosts()
    let continuedInjection = try store.handoffCosts().first { $0.id == fullInjected.id }!
    try expect(continuedInjection.status, .continued, "first real destination turn proves continuation")
    try expect(
        continuedInjection.completedAt,
        firstContinuation.startedAt,
        "continued timestamp uses the real destination turn start")
    let injectionSummary = try store.shadowTelemetrySummary()
    try expect(injectionSummary.historyInjectionHandoffs, 2, "history injection aggregate count")
    try expect(injectionSummary.seededHandoffCosts, 1, "unused injected task remains seeded")
    try expect(injectionSummary.continuedHandoffCosts, 1, "used injected task becomes continued")

    let encodedLegacy = try JSONEncoder().encode(pending)
    var legacyObject = try JSONSerialization.jsonObject(with: encodedLegacy) as! [String: Any]
    legacyObject.removeValue(forKey: "deliveryMethod")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let decodedLegacy = try JSONDecoder().decode(HandoffCostRecord.self, from: legacyData)
    try expect(decodedLegacy.deliveryMethod, .acknowledgementTurn, "legacy cost defaults to acknowledgement")
}

func testRoutingPreflightPolicy() throws {
    try expect(
        CodexManagedHandoff.instruction,
        "总结必要上下文，开启新的会话任务",
        "fresh-task control surface is one exact Codex instruction")
    let inputJSON = Data(#"{"session_id":"session-1","transcript_path":"/private/rollout.jsonl","cwd":"/workspace","model":"gpt-5.6-sol","permission_mode":"default","turn_id":"turn-1","prompt":"翻译为英文：测试提交前配置拦截。"}"#.utf8)
    let input = try JSONDecoder().decode(RoutingPreflightHookInput.self, from: inputJSON)
    try expect(input.sessionID, "session-1", "hook snake-case session id")
    try expect(input.prompt, "翻译为英文：测试提交前配置拦截。", "hook prompt")

    let expensive = RoutingSelection(model: "gpt-5.6-sol", reasoningEffort: "xhigh")
    let simple = RoutingPreflightPolicy.localDecision(input: input, selection: expensive)
    try expect(simple?.shouldBlock, true, "obvious simple work is blocked before expensive execution")
    try expect(simple?.recommendedModel, "gpt-5.6-luna", "simple work uses efficient model")
    try expect(simple?.recommendedEffort, "medium", "simple work uses balanced effort")
    try expect(simple?.hookResponse?["decision"], "block", "hook response uses official block contract")
    try expect(simple?.hookResponse?["reason"]?.contains(input.prompt), false, "block response does not echo prompt")

    let alreadyEfficient = RoutingPreflightPolicy.localDecision(
        input: input,
        selection: RoutingSelection(model: "gpt-5.6-luna", reasoningEffort: "medium"))
    try expect(alreadyEfficient == nil, true, "sufficient route is not interrupted")

    var internalInput = input
    internalInput.prompt = "\(RoutingPreflightPolicy.internalSentinel) classify"
    let recursion = RoutingPreflightPolicy.localDecision(input: internalInput, selection: expensive)
    try expect(recursion?.shouldBlock, false, "classifier sentinel prevents hook recursion")

    var uncertain = input
    uncertain.prompt = "继续"
    try expect(
        RoutingPreflightPolicy.localDecision(input: uncertain, selection: expensive) == nil,
        true,
        "uncertain prompt is delegated or fails open")
    try expect(RoutingPreflightPolicy.needsBoundedModel(expensive), true, "expensive uncertain task may use bounded classifier")
    try expect(
        RoutingPreflightPolicy.needsBoundedModel(.init(model: "gpt-5.6-sol", reasoningEffort: "medium")),
        false,
        "controller baseline has zero-token preflight")
    try expect(
        RoutingPreflightPolicy.isSupportedSelection(
            .init(model: "codex-auto-review", reasoningEffort: "medium")),
        false,
        "internal reviewer models never enter user routing")

    var frozenInput = input
    frozenInput.prompt = "需求已明确，只修改解析器并运行测试，测试通过即可。"
    let frozenDecision = RoutingPreflightPolicy.localDecision(
        input: frozenInput,
        selection: .init(model: "gpt-5.6-sol", reasoningEffort: "medium"))
    try expect(frozenDecision?.recommendedModel, "gpt-5.6-luna", "default controller routes frozen mechanical work")
    try expect(frozenDecision?.recommendedEffort, "max", "frozen worker route follows local router")

    var terraInput = input
    terraInput.prompt = "需求已明确，范围已冻结。这是判断密集的跨模块实现，luna 返工风险已有证据。"
    let terraDecision = RoutingPreflightPolicy.localDecision(
        input: terraInput,
        selection: .init(model: "gpt-5.6-sol", reasoningEffort: "medium"))
    try expect(terraDecision?.recommendedModel, "gpt-5.6-terra", "explicit repair risk routes to Terra")
    try expect(terraDecision?.recommendedEffort, "high", "Terra route effort")

    var architectureInput = input
    architectureInput.prompt = "请设计这个系统的架构并分析关键权衡。"
    let architectureDecision = RoutingPreflightPolicy.localDecision(
        input: architectureInput,
        selection: .init(model: "gpt-5.6-terra", reasoningEffort: "medium"))
    try expect(architectureDecision?.recommendedModel, "gpt-5.6-sol", "architecture upgrades Terra to Sol")
    try expect(architectureDecision?.recommendedEffort, "medium", "architecture keeps balanced Sol effort")
    try expect(
        RoutingPreflightPolicy.isUpgrade(
            .init(model: "gpt-5.6-sol", reasoningEffort: "medium"),
            from: .init(model: "gpt-5.6-terra", reasoningEffort: "high")),
        true,
        "quality ladder places Sol medium after Terra high")

    var denseInput = input
    denseInput.prompt = "实现这个判断密集的跨模块功能，验收标准已经明确。"
    let denseDecision = RoutingPreflightPolicy.localDecision(
        input: denseInput,
        selection: .init(model: "gpt-5.6-terra", reasoningEffort: "medium"))
    try expect(denseDecision?.recommendedModel, "gpt-5.6-terra", "dense work keeps Terra model first")
    try expect(denseDecision?.recommendedEffort, "high", "dense work upgrades Terra effort")

    let modelJSON = #"{"shouldBlock":true,"recommendedModel":"gpt-5.6-terra","recommendedEffort":"high","confidence":0.96,"reasonCode":"clear_implementation_task","upgradeCondition":"架构边界发生变化","classifier":"boundedModel"}"#
    let decoded = RoutingPreflightPolicy.decodeModelDecision(modelJSON)!
    let validated = RoutingPreflightPolicy.validateModelDecision(decoded, current: expensive)
    try expect(validated.shouldBlock, true, "high-confidence cheaper model response is accepted")
    var lowConfidence = decoded
    lowConfidence.confidence = 0.89
    try expect(
        RoutingPreflightPolicy.validateModelDecision(lowConfidence, current: expensive).shouldBlock,
        false,
        "model response below threshold fails open")
    var lowUpgradeConfidence = decoded
    lowUpgradeConfidence.recommendedModel = "gpt-5.6-sol"
    lowUpgradeConfidence.recommendedEffort = "medium"
    lowUpgradeConfidence.confidence = 0.94
    try expect(
        RoutingPreflightPolicy.validateModelDecision(
            lowUpgradeConfidence,
            current: .init(model: "gpt-5.6-terra", reasoningEffort: "medium")).shouldBlock,
        false,
        "upgrades require the stricter confidence threshold")

    let preflightParams = CodexEvaluationTaskRunner.preflightThreadStartParams(cwd: "/workspace")
    try expect(preflightParams["ephemeral"] as? Bool, true, "classifier task is ephemeral")
    try expect(preflightParams["sandbox"] as? String, "read-only", "classifier cannot mutate workspace")
    try expect(preflightParams["approvalPolicy"] as? String, "never", "classifier cannot ask for approval")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SQLiteStore(path: root.appendingPathComponent("guardian.sqlite").path)
    let codexState = root.appendingPathComponent("state_5.sqlite")
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [codexState.path, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, model TEXT, reasoning_effort TEXT,
            source TEXT, thread_source TEXT, archived INTEGER, preview TEXT
        );
        INSERT INTO threads VALUES (
            'fresh-user', 'gpt-5.6-sol', 'medium', 'vscode', 'user', 0, ''
        );
        INSERT INTO threads VALUES (
            'child-agent', 'gpt-5.6-sol', 'medium',
            '{"subagent":{"other":"worker"}}', 'subagent', 0, 'child'
        );
        """]
    try sqlite.run()
    sqlite.waitUntilExit()
    try expect(sqlite.terminationStatus, 0, "routing state fixture")
    try expect(
        CodexThreadSelectionReader.isTopLevelUserTask(
            sessionID: "fresh-user", databasePath: codexState.path),
        true,
        "empty preview does not hide a fresh top-level user task")
    try expect(
        CodexThreadSelectionReader.isTopLevelUserTask(
            sessionID: "child-agent", databasePath: codexState.path),
        false,
        "subagent remains excluded from routing")
    let freshRollout = root.appendingPathComponent("fresh.jsonl")
    let sessionMeta = event(type: "session_meta", payload: [
        "id": "fresh-session",
        "session_id": "fresh-session",
        "source": "vscode",
        "thread_source": "user",
    ])
    let turnContext = event(type: "turn_context", payload: [
        "model": "gpt-5.6-sol",
        "effort": "medium",
    ])
    try Data(sessionMeta + [0x0A] + turnContext + [0x0A]).write(to: freshRollout)
    let freshFacts = CodexRolloutPreflightReader.read(
        sessionID: "fresh-session",
        transcriptPath: freshRollout.path)
    try expect(freshFacts?.isTopLevelUserTask, true, "rollout identifies a new top-level task")
    try expect(
        freshFacts?.selection,
        RoutingSelection(model: "gpt-5.6-sol", reasoningEffort: "medium"),
        "turn_context supplies new-task routing configuration")
    try expect(
        RoutingReplaySafety.lifecycleState(transcriptPath: freshRollout.path),
        .notStarted,
        "fresh rollout is eligible before its first provider call")
    try expect(
        RoutingReplaySafety.isTurnActive(transcriptPath: freshRollout.path),
        false,
        "fresh rollout is not mistaken for an active writer")
    let subagentRollout = root.appendingPathComponent("subagent.jsonl")
    let subagentMeta = event(type: "session_meta", payload: [
        "id": "child-session",
        "session_id": "child-session",
        "source": "vscode",
        "thread_source": "subagent",
    ])
    try Data(subagentMeta + [0x0A] + turnContext + [0x0A]).write(to: subagentRollout)
    try expect(
        CodexRolloutPreflightReader.read(
            sessionID: "child-session",
            transcriptPath: subagentRollout.path)?.isTopLevelUserTask,
        false,
        "rollout fallback still excludes subagents")
    let activeRollout = root.appendingPathComponent("active.jsonl")
    let startedLine = event(type: "event_msg", payload: ["type": "task_started"])
    try Data(startedLine + [0x0A]).write(to: activeRollout)
    try expect(
        RoutingReplaySafety.isTurnActive(transcriptPath: activeRollout.path),
        true,
        "active rollout blocks replay before owner IPC")
    let completedLine = event(type: "event_msg", payload: ["type": "task_complete"])
    let handle = try FileHandle(forWritingTo: activeRollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(completedLine + [0x0A]))
    try handle.close()
    try expect(
        RoutingReplaySafety.isTurnActive(transcriptPath: activeRollout.path),
        false,
        "terminal event re-enables idle replay")
    let longActiveRollout = root.appendingPathComponent("long-active.jsonl")
    try Data(startedLine + [0x0A]).write(to: longActiveRollout)
    let longActiveHandle = try FileHandle(forWritingTo: longActiveRollout)
    try longActiveHandle.seekToEnd()
    try longActiveHandle.write(contentsOf: Data(
        repeating: 0x20,
        count: Int(RoutingReplaySafety.maximumTailBytes) + 1))
    try longActiveHandle.close()
    try expect(
        RoutingReplaySafety.isTurnActive(transcriptPath: longActiveRollout.path),
        nil,
        "bounded tail without lifecycle fails closed for long active replay")
    try expect(
        RoutingReplaySafety.isTurnActive(transcriptPath: root.appendingPathComponent("missing.jsonl").path),
        nil,
        "unknown rollout state fails closed for replay")
    var classifierUsage = TokenUsage()
    classifierUsage.input = 120
    classifierUsage.output = 10
    classifierUsage.total = 130
    let observation = RoutingPreflightObservation(
        id: "preflight-1",
        sessionID: input.sessionID,
        observedAt: Date(timeIntervalSince1970: 100),
        current: expensive,
        decision: simple!,
        classifierUsage: classifierUsage)
    var blockedTurn = TurnRecord(
        sessionID: input.sessionID,
        turnID: "blocked-turn",
        ordinal: 1,
        cwd: input.cwd,
        startedAt: Date(timeIntervalSince1970: 99))
    blockedTurn.completedAt = Date(timeIntervalSince1970: 101)
    try expect(
        observation.isSuperseded(by: blockedTurn),
        false,
        "the blocked turn completing after the hook keeps the decision visible")
    var replayedTurn = TurnRecord(
        sessionID: input.sessionID,
        turnID: "replayed-turn",
        ordinal: 2,
        cwd: input.cwd,
        startedAt: Date(timeIntervalSince1970: 102))
    replayedTurn.status = .completed
    try expect(
        observation.isSuperseded(by: replayedTurn),
        true,
        "a later replay turn retires the stale preflight decision")
    try store.recordRoutingPreflight(observation)
    let loaded = try store.routingPreflights(limit: 1)
    try expect(loaded.first?.blocked, true, "preflight audit persists decision")
    try expect(loaded.first?.sessionHash == input.sessionID, false, "preflight audit hashes session id")
    try expect(loaded.first?.classifierUsage?.total, 130, "classifier token cost is persisted exactly")
    let persisted = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
    try expect(persisted.contains(input.prompt), false, "preflight audit never persists prompt")
    try expect(persisted.contains(input.transcriptPath!), false, "preflight audit never persists transcript path")

    let diagnostic = RoutingHookDiagnostic(
        id: "hook-diagnostic-1",
        sessionID: input.sessionID,
        outcome: .filtered,
        reasonCode: "lifecycle_unknown",
        inputKeys: ["prompt", "session_id", "transcript_path"])
    try store.recordRoutingHookDiagnostic(diagnostic)
    let loadedDiagnostics = try store.routingHookDiagnostics(limit: 1)
    try expect(loadedDiagnostics.first?.outcome, .filtered, "hook terminal outcome is persisted")
    try expect(loadedDiagnostics.first?.reasonCode, "lifecycle_unknown", "hook reason is inspectable")
    try expect(loadedDiagnostics.first?.sessionHash == input.sessionID, false, "hook diagnostic hashes session id")
    let persistedDiagnostics = String(decoding: try JSONEncoder().encode(loadedDiagnostics), as: UTF8.self)
    try expect(persistedDiagnostics.contains(input.prompt), false, "hook diagnostic never persists prompt")
    try expect(persistedDiagnostics.contains(input.transcriptPath!), false, "hook diagnostic never persists transcript path")

    let bypass = RoutingPreflightBypass(sessionID: input.sessionID, prompt: input.prompt)
    try store.saveRoutingPreflightBypass(bypass)
    try expect(
        try store.consumeRoutingPreflightBypass(sessionID: input.sessionID, prompt: input.prompt),
        true,
        "one-click replay bypass is consumed")
    try expect(
        try store.consumeRoutingPreflightBypass(sessionID: input.sessionID, prompt: input.prompt),
        false,
        "replay bypass is one-time")

    let replayParams = CodexDesktopTurnReplay.turnStartParams(
        prompt: input.prompt,
        model: "gpt-5.6-luna",
        reasoningEffort: "medium")
    try expect(replayParams["model"] as? String, "gpt-5.6-luna", "replay overrides model for this thread")
    try expect(replayParams["effort"] as? String, "medium", "replay overrides effort for this thread")
    let settingsParams = CodexDesktopTurnReplay.threadSettingsParams(
        model: "gpt-5.6-luna",
        reasoningEffort: "medium")
    try expect(settingsParams["model"] as? String, "gpt-5.6-luna", "thread setting selects replay model")
    try expect(settingsParams["effort"] as? String, "medium", "thread setting selects replay effort")
    try expect(
        CodexDesktopIPCProtocol.version(
            method: "thread-follower-update-thread-settings",
            params: [:]),
        1,
        "Desktop settings update uses its declared v1 protocol")
    let verifiedTurn = event(type: "turn_context", payload: [
        "turn_id": "replay-turn",
        "model": "gpt-5.6-luna",
        "effort": "medium",
    ])
    try expect(
        CodexDesktopTurnReplay.turnConfiguration(in: verifiedTurn, turnID: "replay-turn"),
        RoutingSelection(model: "gpt-5.6-luna", reasoningEffort: "medium"),
        "replay verification reads the actual turn configuration")
    try expect(
        CodexDesktopTurnReplay.turnConfiguration(in: verifiedTurn, turnID: "different-turn"),
        nil,
        "replay verification is scoped to the returned turn id")

    let capture = ReplayCapture()
    let semaphore = DispatchSemaphore(value: 0)
    let socketPath = root.appendingPathComponent("preflight.sock").path
    let bridge = RoutingPreflightBridgeServer(socketPath: socketPath) { replay in
        capture.set(replay)
        semaphore.signal()
    }
    try bridge.start()
    defer { bridge.stop() }
    let replay = PendingRoutingReplay(
        sessionID: input.sessionID,
        prompt: input.prompt,
        current: expensive,
        recommended: .init(model: "gpt-5.6-luna", reasoningEffort: "medium"),
        reasonCode: simple!.reasonCode,
        upgradeCondition: simple!.upgradeCondition)
    try expect(
        RoutingPreflightBridgeClient.send(replay, socketPath: socketPath),
        true,
        "blocked prompt reaches the in-memory app bridge")
    try expect(semaphore.wait(timeout: .now() + 2), .success, "bridge receives prompt promptly")
    try expect(capture.get(), replay, "bridge preserves the pending replay contract")

}

func testRoutingHookInstaller() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hooks = root.appendingPathComponent("hooks.json")
    let fluxCommand = "flux-hooks --source codex"
    let original: [String: Any] = [
        "hooks": [
            "SessionStart": [["hooks": [["command": "start-hook", "type": "command"]]]],
            "UserPromptSubmit": [[
                "hooks": [["command": fluxCommand, "type": "command", "timeout": 5]],
            ]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: hooks)
    let backup = try RoutingHookInstaller.install(
        command: "/Applications/Codex Session Guardian.app/Contents/Helpers/codex-session-guardian-cli",
        hooksFile: hooks,
        now: Date(timeIntervalSince1970: 1_700_000_000))
    try expect(backup != nil, true, "first install creates backup")
    let rootObject = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as! [String: Any]
    let events = rootObject["hooks"] as! [String: Any]
    let matchers = events["UserPromptSubmit"] as! [[String: Any]]
    try expect(matchers.count, 2, "Guardian adds a separate matcher")
    let firstHooks = matchers[0]["hooks"] as! [[String: Any]]
    try expect(firstHooks[0]["command"] as? String, fluxCommand, "existing Flux hook is preserved exactly")
    let secondHooks = matchers[1]["hooks"] as! [[String: Any]]
    try expect((secondHooks[0]["command"] as? String)?.contains("--user-prompt-submit-hook"), true, "Guardian hook marker")
    try expect(secondHooks[0]["timeout"] as? Int, 15, "hook timeout bounds classifier")
    try expect(events["SessionStart"] != nil, true, "other hook events are preserved")
    let secondBackup = try RoutingHookInstaller.install(
        command: "/ignored",
        hooksFile: hooks,
        now: Date(timeIntervalSince1970: 1_700_000_001))
    try expect(secondBackup == nil, true, "install is idempotent")
}

let tests: [(String, () throws -> Void)] = [
    ("aggregation and cache semantics", testAggregation),
    ("task configuration capture and economics audit", testTaskConfigurationCaptureAndEconomics),
    ("task shape and routing shadow", testTaskShapeAndRoutingShadow),
    ("execution waste shadow ledger", testExecutionWasteShadowLedger),
    ("routing preference persistence", testRoutingPreferencePersistence),
    ("routing outcome quality and privacy", testRoutingOutcomeObservation),
    ("evaluation task protocol", testEvaluationTaskProtocol),
    ("Codex quota router policy", testCodexQuotaRouterPolicy),
    ("routing preflight policy and privacy", testRoutingPreflightPolicy),
    ("routing hook installer preservation", testRoutingHookInstaller),
    ("duplicate and cumulative reset", testDuplicateAndReset),
    ("turn boundaries and risk", testRiskAndBoundaries),
    ("incremental tail and archive move", testIncrementalAndArchive),
    ("cross-project isolation", testProjectIsolation),
    ("subagent filtering and migration", testSubagentFilteringAndMigration),
    ("multi-agent execution audit", testMultiAgentExecutionAudit),
    ("subagent hook privacy ledger", testSubagentHookLedger),
    ("configuration hook health", testConfigurationHookHealth),
    ("subagent hook health and trust inspection", testSubagentHookHealthAndTrustInspection),
    ("subagent hook health with rollout activity", testSubagentHookHealthWithRolloutActivity),
    ("sidebar-indexed coverage", testSidebarIndexedCoverage),
    ("session health, grouping, and activity", testSessionHealthAndActivity),
    ("pet animation event mapping", testPetAnimationState),
    ("floating pet anchor stability", testFloatingPetAnchorStability),
    ("floating session snapshot stability", testFloatingSessionSnapshotStability),
    ("floating visibility frame restoration", testFloatingVisibilityPreservesFrameAfterRestore),
    ("session refresh cadence", testSessionRefreshCadence),
    ("Xiaoxin speech scheduling", testXiaoxinSpeechScheduling),
    ("live activity privacy and mapping", testLiveActivityPrivacyAndMapping),
    ("live activity fragmentation and isolation", testLiveActivityFragmentationAndIsolation),
    ("live activity truncation and partial file", testLiveActivityTruncationAndPartialFile),
    ("live activity monitor latency", testLiveActivityMonitorLatency),
    ("handoff shadow telemetry and privacy", testHandoffShadowTelemetry),
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
