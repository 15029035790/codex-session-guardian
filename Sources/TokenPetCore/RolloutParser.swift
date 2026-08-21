import Foundation

/// A spawn request is kept in memory/on the rollout cursor until Codex emits
/// positive lifecycle evidence. A `spawn_agent` function call alone is not a
/// dispatch: the tool can be rejected before a child task exists.
public struct PendingAgentDispatch: Codable, Equatable, Sendable {
    public var callID: String
    public var taskName: String
    public var agentType: String
    public var forkTurns: String?
    public var model: String?
    public var reasoningEffort: String?
    public var occurredAt: Date

    public init(
        callID: String,
        taskName: String,
        agentType: String,
        forkTurns: String?,
        model: String?,
        reasoningEffort: String?,
        occurredAt: Date
    ) {
        self.callID = callID
        self.taskName = taskName
        self.agentType = agentType
        self.forkTurns = forkTurns
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.occurredAt = occurredAt
    }
}

public struct RolloutState: Codable, Equatable, Sendable {
    // Bump when dispatch confirmation semantics change so existing cursors
    // are replayed and stale function-call-only records disappear.
    public static let currentClassificationVersion = 12

    public var sessionID: String?
    public var cwd = ""
    public var classificationVersion: Int?
    public var isSubagent: Bool?
    public var parentThreadID: String?
    public var agentPath: String?
    public var didReadPrimarySessionMeta: Bool?
    public var currentModel: String?
    public var currentReasoningEffort: String?
    public var ordinal = 0
    public var active: TurnRecord?
    public var cumulative: TokenUsage?
    public var recentFingerprints: [String] = []
    public var latestQuota: QuotaSnapshot?
    public var pendingVerificationCalls: [String: Bool]?
    public var pendingAgentDispatches: [String: PendingAgentDispatch]?
    var executionWasteTracker: ExecutionWasteTracker?

    public init() {}

    public mutating func process(line: Data) -> TurnRecord? {
        let relevant = line.range(of: Self.sessionMetaNeedle) != nil ||
            line.range(of: Self.turnContextNeedle) != nil ||
            line.range(of: Self.eventMessageNeedle) != nil ||
            line.range(of: Self.functionCallNeedle) != nil ||
            line.range(of: Self.customToolCallNeedle) != nil ||
            line.range(of: Self.functionCallOutputNeedle) != nil ||
            line.range(of: Self.customToolCallOutputNeedle) != nil ||
            line.range(of: Self.compactionNeedle) != nil
        guard relevant else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else { return nil }

        let timestamp = Self.date(object["timestamp"] as? String)
        if type == "session_meta" {
            guard didReadPrimarySessionMeta != true else { return nil }
            didReadPrimarySessionMeta = true
            sessionID = payload["id"] as? String ?? sessionID
            cwd = payload["cwd"] as? String ?? cwd
            parentThreadID = payload["parent_thread_id"] as? String
            let source = payload["source"] as? [String: Any]
            isSubagent = source?["subagent"] != nil
            if let subagent = source?["subagent"] as? [String: Any],
               let spawn = subagent["thread_spawn"] as? [String: Any] {
                agentPath = spawn["agent_path"] as? String
            }
            classificationVersion = Self.currentClassificationVersion
            if active?.cwd.isEmpty == true { active?.cwd = cwd }
            return nil
        }

        if type == "turn_context" {
            cwd = payload["cwd"] as? String ?? cwd
            currentModel = Self.nonEmpty(payload["model"] as? String) ?? currentModel
            currentReasoningEffort = Self.nonEmpty(payload["effort"] as? String) ?? currentReasoningEffort
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            active?.cwd = cwd
            active?.model = currentModel
            active?.reasoningEffort = currentReasoningEffort
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }

        guard type == "event_msg" || type == "response_item" else { return nil }
        let eventType = payload["type"] as? String ?? ""
        if type == "event_msg", eventType == "thread_settings_applied",
           let settings = payload["thread_settings"] as? [String: Any]
        {
            currentModel = Self.nonEmpty(settings["model"] as? String) ?? currentModel
            currentReasoningEffort = Self.nonEmpty(settings["reasoning_effort"] as? String)
                ?? currentReasoningEffort
            if active != nil {
                active?.model = currentModel
                active?.reasoningEffort = currentReasoningEffort
                if let timestamp { active?.lastActivityAt = timestamp }
            }
            return active
        }
        if type == "event_msg", eventType == "task_started" || eventType == "user_message" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String ?? payload["id"] as? String)
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "response_item", eventType == "function_call" || eventType == "custom_tool_call" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            recordPendingAgentDispatchIfNeeded(payload, timestamp: timestamp)
            recordTool(named: payload["name"] as? String ?? "", payload: payload)
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "response_item", eventType == "function_call_output" || eventType == "custom_tool_call_output" {
            recordAgentDispatchOutputIfNeeded(payload)
            _ = recordWasteOutput(
                callID: payload["call_id"] as? String,
                raw: payload["output"])
            if let callID = payload["call_id"] as? String,
               pendingVerificationCalls?[callID] == true
            {
                switch Self.toolOutputStatus(payload["output"]) {
                case .success:
                    mutateProfile {
                        $0.verificationActions += 1
                        // Failed checks are common during an implementation loop.
                        // A later explicit successful verification resolves the
                        // earlier signal; quality classification follows the last
                        // observed verification result, not transient failures.
                        $0.failureSignals = 0
                    }
                    executionWasteTracker?.markProgressBoundary()
                case .failure:
                    mutateProfile { $0.failureSignals += 1 }
                case .unknown:
                    break
                }
                pendingVerificationCalls?.removeValue(forKey: callID)
            }
            syncWasteProfile()
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "event_msg", eventType == "agent_message" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            mutateProfile { $0.responseEvents += 1 }
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "event_msg", eventType == "patch_apply_end" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            mutateProfile { $0.editActions += max(1, Self.changeCount(payload["changes"])) }
            executionWasteTracker?.markProgressBoundary()
            syncWasteProfile()
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "event_msg", eventType == "sub_agent_activity" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            recordStartedAgentActivityIfNeeded(payload, timestamp: timestamp)
            mutateProfile { $0.agentActions += 1 }
            if let timestamp { active?.lastSubagentActivityAt = timestamp }
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "event_msg", Self.verificationEventTypes.contains(eventType) {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            mutateProfile { $0.verificationActions += 1 }
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "event_msg", Self.terminalFailureEventTypes.contains(eventType) {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            if eventType != "turn_aborted" { mutateProfile { $0.failureSignals += 1 } }
            active?.completedAt = timestamp
            if let timestamp { active?.lastActivityAt = timestamp }
            active?.status = .interrupted
            syncWasteProfile()
            let interrupted = active
            active = nil
            executionWasteTracker = nil
            return interrupted
        }
        if type == "event_msg", eventType == "task_complete" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            active?.completedAt = timestamp
            if let timestamp { active?.lastActivityAt = timestamp }
            active?.status = .completed
            syncWasteProfile()
            let completed = active
            active = nil
            executionWasteTracker = nil
            return completed
        }
        if (type == "response_item" && eventType == "context_compaction") ||
            (type == "event_msg" && ["context_compacted", "thread_compacted"].contains(eventType))
        {
            active?.compactions += 1
            executionWasteTracker?.markProgressBoundary()
            syncWasteProfile()
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        guard type == "event_msg", eventType == "token_count" else { return nil }
        if let rawQuota = payload["rate_limits"] as? [String: Any],
           QuotaSnapshot.isValid(raw: rawQuota)
        {
            latestQuota = QuotaSnapshot(raw: rawQuota, observedAt: timestamp)
            active?.quota = latestQuota
        }
        guard
              let info = payload["info"] as? [String: Any],
              let totalRaw = info["total_token_usage"] as? [String: Any]
        else { return nil }

        let next = TokenUsage(raw: totalRaw)
        let reset = cumulative.map { next.total < $0.total } ?? false
        if reset { recentFingerprints.removeAll() }
        let duplicate = recentFingerprints.contains(next.fingerprint)

        defer {
            cumulative = next
            if !duplicate {
                recentFingerprints.append(next.fingerprint)
                if recentFingerprints.count > 64 { recentFingerprints.removeFirst() }
            }
        }

        guard var turn = active else { return nil }
        turn.lastActivityAt = timestamp ?? turn.lastActivityAt
        turn.contextWindow = max(0, (info["model_context_window"] as? NSNumber)?.intValue ?? 0)
        guard !duplicate else {
            active = turn
            return turn
        }

        let callUsage: TokenUsage
        if let cumulative, !reset {
            callUsage = next.subtracting(cumulative)
        } else if let lastRaw = info["last_token_usage"] as? [String: Any] {
            callUsage = TokenUsage(raw: lastRaw)
            if cumulative == nil { turn.confidence = "inferred-from-last-call" }
        } else {
            callUsage = next
            turn.confidence = "lower-bound"
        }
        if callUsage.total > 0 {
            turn.usage = turn.usage + callUsage
            turn.calls += 1
            turn.latestPromptInput = callUsage.input
        }
        active = turn
        return turn
    }

    private mutating func ensureTurn(timestamp: Date?, turnID: String?) {
        guard active == nil else {
            if active?.turnID == nil { active?.turnID = turnID }
            return
        }
        ordinal += 1
        active = TurnRecord(
            sessionID: sessionID ?? "pending-session",
            turnID: turnID,
            ordinal: ordinal,
            cwd: cwd,
            startedAt: timestamp)
        executionWasteTracker = ExecutionWasteTracker()
        active?.model = currentModel
        active?.reasoningEffort = currentReasoningEffort
        active?.quota = latestQuota
        active?.isSubagent = isSubagent
        active?.parentThreadID = parentThreadID
        active?.agentPath = agentPath
    }

    private mutating func recordPendingAgentDispatchIfNeeded(_ payload: [String: Any], timestamp: Date?) {
        guard (payload["name"] as? String) == "spawn_agent",
              let callID = Self.nonEmpty(payload["call_id"] as? String ?? payload["id"] as? String)
        else { return }
        let arguments: [String: Any]
        if let raw = payload["arguments"] as? String,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            arguments = object
        } else if let object = payload["arguments"] as? [String: Any] {
            arguments = object
        } else {
            return
        }
        guard
              let taskName = arguments["task_name"] as? String,
              let normalizedTaskName = Self.nonEmpty(taskName)
        else { return }

        var pending = pendingAgentDispatches ?? [:]
        pending[callID] = PendingAgentDispatch(
            callID: callID,
            taskName: normalizedTaskName,
            agentType: Self.nonEmpty(arguments["agent_type"] as? String) ?? "unknown",
            // A missing field remains unknown. In particular, do not turn an
            // omitted field into the historical default `all`.
            forkTurns: Self.nonEmpty(arguments["fork_turns"] as? String),
            model: arguments["model"] as? String,
            reasoningEffort: arguments["reasoning_effort"] as? String,
            occurredAt: timestamp ?? active?.lastActivityAt ?? Date())
        pendingAgentDispatches = pending
    }

    private mutating func recordAgentDispatchOutputIfNeeded(_ payload: [String: Any]) {
        guard let callID = Self.nonEmpty(payload["call_id"] as? String),
              let pending = pendingAgentDispatches?[callID]
        else { return }
        switch Self.spawnOutputStatus(payload["output"]) {
        case let .success(path):
            confirmAgentDispatch(
                pending,
                agentThreadID: nil,
                agentPath: path,
                taskName: Self.taskName(fromAgentPath: path) ?? pending.taskName)
        case .failure:
            // A rejected/failed spawn is deliberately forgotten. It must not
            // become an audit dispatch merely because the call was attempted.
            pendingAgentDispatches?.removeValue(forKey: callID)
        case .unknown:
            break
        }
    }

    private mutating func recordStartedAgentActivityIfNeeded(
        _ payload: [String: Any],
        timestamp: Date?
    ) {
        guard (payload["kind"] as? String)?.lowercased() == "started",
              let callID = Self.nonEmpty(payload["event_id"] as? String)
        else { return }

        let agentThreadID = Self.nonEmpty(payload["agent_thread_id"] as? String)
        let agentPath = Self.nonEmpty(payload["agent_path"] as? String)
        if let pending = pendingAgentDispatches?[callID] {
            confirmAgentDispatch(
                pending,
                agentThreadID: agentThreadID,
                agentPath: agentPath,
                taskName: Self.taskName(fromAgentPath: agentPath) ?? pending.taskName)
            return
        }

        // A cursor may begin after the original function call when an old
        // rollout is incrementally tailed. The started lifecycle event is
        // still positive evidence, so retain a conservative record with
        // unknown request metadata instead of inventing `fork_turns`.
        let fallbackTaskName = Self.taskName(fromAgentPath: agentPath)
        guard let fallbackTaskName else { return }
        let fallback = PendingAgentDispatch(
            callID: callID,
            taskName: fallbackTaskName,
            agentType: "unknown",
            forkTurns: nil,
            model: nil,
            reasoningEffort: nil,
            occurredAt: timestamp ?? active?.lastActivityAt ?? Date())
        confirmAgentDispatch(
            fallback,
            agentThreadID: agentThreadID,
            agentPath: agentPath,
            taskName: fallbackTaskName)
    }

    private mutating func confirmAgentDispatch(
        _ pending: PendingAgentDispatch,
        agentThreadID: String?,
        agentPath: String?,
        taskName: String
    ) {
        var records = active?.agentDispatches ?? []
        let record = AgentDispatchRecord(
            taskName: taskName,
            agentType: pending.agentType,
            forkTurns: pending.forkTurns,
            model: pending.model,
            reasoningEffort: pending.reasoningEffort,
            occurredAt: pending.occurredAt,
            callID: pending.callID,
            agentThreadID: agentThreadID,
            agentPath: agentPath)
        if !records.contains(where: { $0.callID == record.callID || $0 == record }) {
            records.append(record)
        }
        active?.agentDispatches = records
        pendingAgentDispatches?.removeValue(forKey: pending.callID)
    }

    private mutating func recordTool(named rawName: String, payload: [String: Any]) {
        let kind = LiveActivityParser.kind(forToolNamed: rawName)
        mutateProfile { profile in
            switch kind {
            case .readingFile:
                profile.readActions += 1
            case .runningCommand:
                profile.commandActions += 1
            case .editingFiles:
                profile.editActions += 1
            case .callingTool, .waitingForUser:
                profile.toolActions += 1
            case .thinking, .responding, .completed, .failed:
                break
            }
        }
        if executionWasteTracker == nil { executionWasteTracker = ExecutionWasteTracker() }
        executionWasteTracker?.recordToolCall(name: rawName, payload: payload)
        syncWasteProfile()
        guard let callID = payload["call_id"] as? String else { return }
        let rawInput = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
        if Self.isVerificationTool(rawName) || Self.isVerificationCommand(rawInput) {
            var pending = pendingVerificationCalls ?? [:]
            pending[callID] = true
            pendingVerificationCalls = pending
        }
    }

    private mutating func mutateProfile(_ mutation: (inout TurnExecutionProfile) -> Void) {
        guard active != nil else { return }
        var profile = active?.executionProfile ?? TurnExecutionProfile()
        mutation(&profile)
        active?.executionProfile = profile
    }

    private mutating func recordWasteOutput(callID: String?, raw: Any?) -> ToolOutputDisposition {
        guard active != nil else { return .unknown }
        if executionWasteTracker == nil { executionWasteTracker = ExecutionWasteTracker() }
        return executionWasteTracker?.recordToolOutput(callID: callID, raw: raw) ?? .unknown
    }

    private mutating func syncWasteProfile() {
        guard active != nil else { return }
        active?.executionWasteProfile = executionWasteTracker?.profile
    }

    private static func changeCount(_ raw: Any?) -> Int {
        if let array = raw as? [Any] { return array.count }
        if let dictionary = raw as? [String: Any] { return dictionary.count }
        return 0
    }

    private static func isVerificationTool(_ rawName: String) -> Bool {
        let name = rawName.lowercased()
        return ["test", "verify", "validation", "lint", "typecheck", "build", "check_ci"]
            .contains { name.contains($0) }
    }

    private static func isVerificationCommand(_ rawInput: String) -> Bool {
        guard !rawInput.isEmpty else { return false }
        let command: String
        if let data = rawInput.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["cmd"] as? String
        {
            command = value
        } else {
            command = rawInput
        }
        let normalized = command.lowercased()
        return [
            "swift test", "swift build", "xcodebuild", "cargo test", "go test", "pytest",
            "npm test", "npm run test", "npm run lint", "pnpm test", "pnpm run lint",
            "yarn test", "yarn lint", "gradlew test", "./gradlew test", "make test", "make check",
            "eslint", "tsc --noemit", "git diff --check", "codesign --verify", "plutil -lint",
            "codex-session-guardian-tests",
        ].contains { normalized.contains($0) }
    }

    private enum ToolOutputStatus {
        case success
        case failure
        case unknown
    }

    private static func toolOutputStatus(_ raw: Any?) -> ToolOutputStatus {
        let output: String
        if let text = raw as? String {
            output = text
        } else if let blocks = raw as? [[String: Any]] {
            output = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return .unknown
        }
        if output.contains("Process exited with code 0") ||
            output.range(of: #"\"exit_code\"\s*:\s*0"#, options: .regularExpression) != nil ||
            output.range(of: #"exit_code\s*[:=]\s*0"#, options: .regularExpression) != nil {
            return .success
        }
        if output.range(of: #"Process exited with code [1-9][0-9]*"#, options: .regularExpression) != nil ||
            output.range(of: #"\"exit_code\"\s*:\s*-[0-9]+"#, options: .regularExpression) != nil ||
            output.range(of: #"\"exit_code\"\s*:\s*[1-9][0-9]*"#, options: .regularExpression) != nil ||
            output.range(of: #"exit_code\s*[:=]\s*-?[1-9][0-9]*"#, options: .regularExpression) != nil {
            return .failure
        }
        return .unknown
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func taskName(fromAgentPath path: String?) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        return path.split(separator: "/").last.map(String.init)
    }

    private enum SpawnOutputStatus {
        case success(String?)
        case failure
        case unknown
    }

    private static func spawnOutputStatus(_ raw: Any?) -> SpawnOutputStatus {
        let output: String
        if let text = raw as? String {
            output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let blocks = raw as? [[String: Any]] {
            output = blocks.compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return .unknown
        }
        guard !output.isEmpty else { return .unknown }

        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if object["error"] != nil || object["failed"] as? Bool == true ||
                object["timed_out"] as? Bool == true || object["success"] as? Bool == false
            {
                return .failure
            }
            if let path = nonEmpty(object["task_name"] as? String)
                ?? nonEmpty(object["agent_path"] as? String)
            {
                return .success(path)
            }
        }

        if output.hasPrefix("/"), !output.contains(where: { $0.isWhitespace }) {
            return .success(output)
        }

        let normalized = output.lowercased()
        if ["unsupported", "rejected", "failed", "error", "timed out", "timeout", "cancelled", "canceled"]
            .contains(where: normalized.contains)
        {
            return .failure
        }
        return .unknown
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter.tokenPet.date(from: value)
    }

    private static let sessionMetaNeedle = Data(#""type":"session_meta""#.utf8)
    private static let turnContextNeedle = Data(#""type":"turn_context""#.utf8)
    private static let eventMessageNeedle = Data(#""type":"event_msg""#.utf8)
    private static let functionCallNeedle = Data(#""type":"function_call""#.utf8)
    private static let customToolCallNeedle = Data(#""type":"custom_tool_call""#.utf8)
    private static let functionCallOutputNeedle = Data(#""type":"function_call_output""#.utf8)
    private static let customToolCallOutputNeedle = Data(#""type":"custom_tool_call_output""#.utf8)
    private static let compactionNeedle = Data(#""context_compaction""#.utf8)
    private static let verificationEventTypes: Set<String> = [
        "validation_completed", "tests_completed", "test_completed", "build_completed", "lint_completed",
    ]
    private static let terminalFailureEventTypes: Set<String> = ["task_failed", "turn_failed", "turn_aborted"]
}

private extension ISO8601DateFormatter {
    static let tokenPet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
