import Foundation

public struct RolloutState: Codable, Equatable, Sendable {
    public static let currentClassificationVersion = 6

    public var sessionID: String?
    public var cwd = ""
    public var classificationVersion: Int?
    public var isSubagent: Bool?
    public var parentThreadID: String?
    public var currentModel: String?
    public var currentReasoningEffort: String?
    public var ordinal = 0
    public var active: TurnRecord?
    public var cumulative: TokenUsage?
    public var recentFingerprints: [String] = []
    public var latestQuota: QuotaSnapshot?
    public var pendingVerificationCalls: [String: Bool]?
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
            sessionID = payload["id"] as? String ?? sessionID
            cwd = payload["cwd"] as? String ?? cwd
            parentThreadID = payload["parent_thread_id"] as? String
            let source = payload["source"] as? [String: Any]
            isSubagent = source?["subagent"] != nil
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
            recordTool(named: payload["name"] as? String ?? "", payload: payload)
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "response_item", eventType == "function_call_output" || eventType == "custom_tool_call_output" {
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
            mutateProfile { $0.agentActions += 1 }
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
        if let rawQuota = payload["rate_limits"] as? [String: Any] {
            latestQuota = QuotaSnapshot(raw: rawQuota)
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
