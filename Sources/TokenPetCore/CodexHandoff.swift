import Foundation

public struct CodexHandoffResult: Sendable {
    public let sourceThreadID: String
    public let newThreadID: String
    public let sourceSummaryTurnID: String?
    public let destinationAcknowledgementTurnID: String?
    public let preparationMethod: HandoffPreparationMethod
    public let deliveryMethod: HandoffDeliveryMethod
    public let handoff: String
}

public struct CodexEvaluationTaskResult: Codable, Equatable, Sendable {
    public var threadID: String
    public var turnID: String
    public var model: String
    public var reasoningEffort: String
    public var outputCharacters: Int
    public var durationSeconds: Double
}

public struct CodexPreflightClassificationResult: Codable, Equatable, Sendable {
    public var output: String
    public var durationSeconds: Double
    public var usage: TokenUsage?

    public init(output: String, durationSeconds: Double, usage: TokenUsage? = nil) {
        self.output = output
        self.durationSeconds = durationSeconds
        self.usage = usage
    }
}

public struct CodexEvaluationTaskRunner: Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 900) throws {
        guard let resolved = executableURL ?? CodexHandoffMigrator.resolveExecutable() else {
            throw CodexHandoffError.executableNotFound
        }
        self.executableURL = resolved
        self.timeout = timeout
    }

    public static func threadStartParams(cwd: String, model: String) -> [String: Any] {
        [
            "cwd": cwd,
            "ephemeral": false,
            "model": model,
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
        ]
    }

    public static func preflightThreadStartParams(cwd: String) -> [String: Any] {
        [
            "cwd": cwd,
            "ephemeral": true,
            "model": "gpt-5.6-sol",
            "approvalPolicy": "never",
            "sandbox": "read-only",
        ]
    }

    public static func turnStartParams(
        threadID: String,
        prompt: String,
        reasoningEffort: String
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]],
            "effort": reasoningEffort,
        ]
    }

    public static func approvalResponse(
        requestID: Any,
        method: String,
        decision: String = "decline"
    ) -> [String: Any]? {
        guard method.hasSuffix("/requestApproval") else { return nil }
        if method == "item/permissions/requestApproval" {
            return [
                "id": requestID,
                "result": ["scope": "turn", "permissions": [String: Any]()],
            ]
        }
        return [
            "id": requestID,
            "result": ["decision": decision],
        ]
    }

    public func run(
        cwd: String,
        title: String,
        prompt: String,
        model: String,
        reasoningEffort: String
    ) throws -> CodexEvaluationTaskResult {
        let startedAt = Date()
        let client = try CodexAppServerClient(
            executableURL: executableURL,
            timeout: timeout,
            automaticApprovalDecision: "decline")
        defer { client.stop() }
        _ = try client.request("initialize", params: [
            "clientInfo": [
                "name": "codex-session-guardian-eval",
                "title": "Codex Session Guardian Evaluation",
                "version": "0.1.0",
            ],
        ])
        try client.notify("initialized", params: nil)
        let started = try client.request(
            "thread/start",
            params: Self.threadStartParams(cwd: cwd, model: model))
        guard let thread = started["thread"] as? [String: Any],
              let threadID = thread["id"] as? String
        else { throw CodexHandoffError.invalidResponse("thread/start is missing thread.id") }
        _ = try? client.request(
            HandoffHistoryInjection.setThreadNameMethod,
            params: ["threadId": threadID, "name": String(title.prefix(80))])
        let turnID = try client.startTurn(params: Self.turnStartParams(
            threadID: threadID,
            prompt: prompt,
            reasoningEffort: reasoningEffort))
        let output = try client.waitForTurn(turnID)
        return CodexEvaluationTaskResult(
            threadID: threadID,
            turnID: turnID,
            model: model,
            reasoningEffort: reasoningEffort,
            outputCharacters: output.count,
            durationSeconds: Date().timeIntervalSince(startedAt))
    }

    public func classifyPreflight(cwd: String, prompt: String) throws -> CodexPreflightClassificationResult {
        let startedAt = Date()
        let client = try CodexAppServerClient(
            executableURL: executableURL,
            timeout: timeout,
            automaticApprovalDecision: "decline")
        defer { client.stop() }
        _ = try client.request("initialize", params: [
            "clientInfo": [
                "name": "codex-session-guardian-preflight",
                "title": "Codex Session Guardian Preflight",
                "version": "0.1.0",
            ],
        ])
        try client.notify("initialized", params: nil)
        let started = try client.request(
            "thread/start",
            params: Self.preflightThreadStartParams(cwd: cwd))
        guard let thread = started["thread"] as? [String: Any],
              let threadID = thread["id"] as? String
        else { throw CodexHandoffError.invalidResponse("thread/start is missing thread.id") }
        let turnID = try client.startTurn(params: Self.turnStartParams(
            threadID: threadID,
            prompt: prompt,
            reasoningEffort: "medium"))
        let completed = try client.waitForTurnDetails(turnID)
        return CodexPreflightClassificationResult(
            output: completed.text,
            durationSeconds: Date().timeIntervalSince(startedAt),
            usage: completed.usage)
    }
}

public enum HandoffHistoryInjection {
    public static let setThreadNameMethod = "thread/name/set"

    public static func text(sourceThreadID: String, handoff: String) -> String {
        """
        Codex Session Guardian 已从源任务 \(sourceThreadID) 生成并校验以下交接摘要。请将它作为本任务的起始上下文；不要假设能够访问此前聊天记录，也不要扩大其范围或权限。

        <tokenpet_handoff>
        \(handoff)
        </tokenpet_handoff>

        这是一次性历史上下文，不是当前待执行请求。收到下一条真实用户消息后直接处理，不要先输出接力确认。
        """
    }

    public static func requestParams(
        threadID: String,
        sourceThreadID: String,
        handoff: String
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "items": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": text(sourceThreadID: sourceThreadID, handoff: handoff),
                ]],
            ]],
        ]
    }
}

public enum CodexHandoffError: LocalizedError {
    case executableNotFound
    case appServerExited(String)
    case invalidResponse(String)
    case rpc(String)
    case timeout(String)
    case invalidHandoff
    case turnFailed(String)
    case activeTurnRequiresInterruption
    case activeTurnIdentifierMissing

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Could not find a local Codex app-server executable"
        case let .appServerExited(details):
            return "Codex app-server exited\(details.isEmpty ? "" : ": \(details)")"
        case let .invalidResponse(details):
            return "Codex app-server returned an invalid response: \(details)"
        case let .rpc(details):
            return "Codex app-server request failed: \(details)"
        case let .timeout(step):
            return "Timed out while waiting for Codex to \(step)"
        case .invalidHandoff:
            return "The source task returned an incomplete handoff; no fresh task was created"
        case let .turnFailed(details):
            return "Codex task failed: \(details)"
        case .activeTurnRequiresInterruption:
            return "The source task is still producing output. Confirm interruption or wait for the current turn to finish."
        case .activeTurnIdentifierMissing:
            return "The source task is active, but its log has no usable turn ID yet. Retry shortly or stop the turn in Codex first."
        }
    }
}

public struct CodexHandoffMigrator: Sendable {
    public typealias Progress = @Sendable (String) -> Void
    public static let defaultPreparationMethod: HandoffPreparationMethod = .fullSourceSummary

    private let executableURL: URL
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 180) throws {
        guard let resolved = executableURL ?? Self.resolveExecutable() else {
            throw CodexHandoffError.executableNotFound
        }
        self.executableURL = resolved
        self.timeout = timeout
    }

    public func migrate(
        sourceThreadID: String,
        sourceTitle: String,
        cwd: String,
        interruptActiveTurn: Bool = false,
        currentTurnID: String? = nil,
        progress: @escaping Progress = { _ in }
    ) throws -> CodexHandoffResult {
        if CodexDesktopIPCClient.isAvailable {
            do {
                return try migrateViaDesktop(
                    sourceThreadID: sourceThreadID,
                    sourceTitle: sourceTitle,
                    cwd: cwd,
                    interruptActiveTurn: interruptActiveTurn,
                    currentTurnID: currentTurnID,
                    progress: progress)
            } catch let error as CodexDesktopIPCError where error.isNoClientFound {
                progress("The source task has no Desktop owner; resuming it through app-server")
            }
        }

        let client = try CodexAppServerClient(executableURL: executableURL, timeout: timeout)
        defer { client.stop() }

        progress("Connecting to the source task")
        _ = try client.request("initialize", params: [
            "clientInfo": [
                "name": "codex-session-guardian",
                "title": "Codex Session Guardian",
                "version": "0.1.0",
            ],
        ])
        try client.notify("initialized", params: nil)
        var resumed: [String: Any]
        if interruptActiveTurn {
            guard let activeTurnID = currentTurnID, !activeTurnID.isEmpty else {
                throw CodexHandoffError.activeTurnIdentifierMissing
            }
            progress("Stopping the source task's current turn")
            do {
                _ = try client.request("turn/interrupt", params: [
                    "threadId": sourceThreadID,
                    "turnId": activeTurnID,
                ])
            } catch {
                // The turn can finish between the local snapshot and interrupt.
                // If the writer has already released, resume is authoritative.
                resumed = try Self.waitUntilResumable(client: client, threadID: sourceThreadID)
                if Self.activeTurnID(in: resumed) != nil { throw error }
                return try Self.finishMigration(
                    client: client,
                    resumed: resumed,
                    sourceThreadID: sourceThreadID,
                    sourceTitle: sourceTitle,
                    cwd: cwd,
                    progress: progress)
            }
            resumed = try Self.waitUntilResumable(client: client, threadID: sourceThreadID)
            resumed = try Self.waitUntilIdle(
                client: client,
                threadID: sourceThreadID,
                initial: resumed)
        } else {
            do {
                resumed = try client.request("thread/resume", params: ["threadId": sourceThreadID])
            } catch where Self.isActiveWriterError(error) {
                throw CodexHandoffError.activeTurnRequiresInterruption
            }
            if Self.activeTurnID(in: resumed) != nil {
                throw CodexHandoffError.activeTurnRequiresInterruption
            }
        }

        return try Self.finishMigration(
            client: client,
            resumed: resumed,
            sourceThreadID: sourceThreadID,
            sourceTitle: sourceTitle,
            cwd: cwd,
            progress: progress)
    }

    private func migrateViaDesktop(
        sourceThreadID: String,
        sourceTitle: String,
        cwd: String,
        interruptActiveTurn: Bool,
        currentTurnID: String?,
        progress: @escaping Progress
    ) throws -> CodexHandoffResult {
        let desktop = try CodexDesktopIPCClient(timeout: timeout)
        defer { desktop.stop() }

        progress("Connecting to Codex Desktop")
        let ownerID = try desktop.findThreadOwner(sourceThreadID)
        if interruptActiveTurn {
            guard let currentTurnID, !currentTurnID.isEmpty else {
                throw CodexHandoffError.activeTurnIdentifierMissing
            }
            progress("Stopping the source task's current turn")
            try desktop.interruptConversation(sourceThreadID, turnID: currentTurnID, ownerID: ownerID)
        }

        let sourceTailer = try CodexRolloutTailer(threadID: sourceThreadID)
        progress("Asking the source task for a quality-first handoff summary")
        let summaryTurnID = try desktop.startFollowUp(
            threadID: sourceThreadID,
            prompt: Self.summaryPrompt,
            ownerID: ownerID)
        let preparationMethod = Self.defaultPreparationMethod
        let handoff = try sourceTailer.waitForTurn(summaryTurnID, timeout: timeout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateHandoff(handoff) else { throw CodexHandoffError.invalidHandoff }

        progress("Creating a fresh task")
        let client = try CodexAppServerClient(executableURL: executableURL, timeout: timeout)
        defer { client.stop() }
        _ = try client.request("initialize", params: [
            "clientInfo": [
                "name": "codex-session-guardian",
                "title": "Codex Session Guardian",
                "version": "0.1.0",
            ],
        ])
        try client.notify("initialized", params: nil)
        if preparationMethod == .fullSourceSummary {
            Self.restoreSourceName(client: client, threadID: sourceThreadID, title: sourceTitle)
        }
        let started = try client.request("thread/start", params: ["cwd": cwd, "ephemeral": false])
        guard let thread = started["thread"] as? [String: Any],
              let newThreadID = thread["id"] as? String
        else { throw CodexHandoffError.invalidResponse("thread/start is missing thread.id") }
        let cleanTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = String((cleanTitle.isEmpty ? "续接任务" : "\(cleanTitle) · 续接").prefix(80))
        _ = try? client.request(
            HandoffHistoryInjection.setThreadNameMethod,
            params: ["threadId": newThreadID, "name": newTitle])

        let delivery = try Self.deliverHandoff(
            client: client,
            newThreadID: newThreadID,
            sourceThreadID: sourceThreadID,
            handoff: handoff,
            progress: progress)

        progress("Handoff complete; opening the fresh task")
        return CodexHandoffResult(
            sourceThreadID: sourceThreadID,
            newThreadID: newThreadID,
            sourceSummaryTurnID: summaryTurnID,
            destinationAcknowledgementTurnID: delivery.turnID,
            preparationMethod: preparationMethod,
            deliveryMethod: delivery.method,
            handoff: handoff)
    }

    private static func finishMigration(
        client: CodexAppServerClient,
        resumed: [String: Any],
        sourceThreadID: String,
        sourceTitle: String,
        cwd: String,
        progress: @escaping Progress
    ) throws -> CodexHandoffResult {

        progress("Asking the source task for a quality-first handoff summary")
        let summaryTurn = try client.startTurn(threadID: sourceThreadID, text: Self.summaryPrompt)
        let preparationMethod = Self.defaultPreparationMethod
        let handoff = try client.waitForTurn(summaryTurn)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateHandoff(handoff) else { throw CodexHandoffError.invalidHandoff }

        if preparationMethod == .fullSourceSummary {
            Self.restoreSourceName(client: client, threadID: sourceThreadID, title: sourceTitle)
        }

        progress("Creating a fresh task")
        var startParams: [String: Any] = [
            "cwd": (resumed["cwd"] as? String) ?? cwd,
            "ephemeral": false,
        ]
        Self.copy("model", from: resumed, to: &startParams)
        Self.copy("modelProvider", from: resumed, to: &startParams)
        Self.copy("serviceTier", from: resumed, to: &startParams)
        Self.copy("approvalPolicy", from: resumed, to: &startParams)
        Self.copy("approvalsReviewer", from: resumed, to: &startParams)
        if let mode = Self.sandboxMode(from: resumed["sandbox"]) { startParams["sandbox"] = mode }

        let started = try client.request("thread/start", params: startParams)
        guard let thread = started["thread"] as? [String: Any],
              let newThreadID = thread["id"] as? String
        else { throw CodexHandoffError.invalidResponse("thread/start is missing thread.id") }

        let cleanTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = String((cleanTitle.isEmpty ? "续接任务" : "\(cleanTitle) · 续接").prefix(80))
        _ = try? client.request(
            HandoffHistoryInjection.setThreadNameMethod,
            params: ["threadId": newThreadID, "name": newTitle])

        var fallbackTurnParams: [String: Any] = ["threadId": newThreadID]
        if let effort = resumed["reasoningEffort"] { fallbackTurnParams["effort"] = effort }
        let delivery = try Self.deliverHandoff(
            client: client,
            newThreadID: newThreadID,
            sourceThreadID: sourceThreadID,
            handoff: handoff,
            fallbackTurnParams: fallbackTurnParams,
            progress: progress)

        progress("Handoff complete; opening the fresh task")
        return CodexHandoffResult(
            sourceThreadID: sourceThreadID,
            newThreadID: newThreadID,
            sourceSummaryTurnID: summaryTurn,
            destinationAcknowledgementTurnID: delivery.turnID,
            preparationMethod: preparationMethod,
            deliveryMethod: delivery.method,
            handoff: handoff)
    }

    public static func validateHandoff(_ text: String) -> Bool {
        let headingSets = [
            ["Goal", "Current state", "Verified work and evidence", "Key decisions and rationale",
             "Immutable constraints and risks", "Workspace, branch, and changed files", "Next step"],
            ["目标", "当前状态", "已验证完成与证据", "关键决策与理由",
             "不可变约束与风险", "工作区、分支与变更文件", "下一步"],
        ]
        guard text.count >= 120,
              !text.localizedCaseInsensitiveContains("<tokenpet_handoff>")
        else { return false }
        return headingSets.contains { headings in
            headings.allSatisfy { heading in
                guard let value = section(heading, in: text) else { return false }
                return value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            }
        }
    }

    private static func section(_ heading: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: heading)
        let pattern = "(?s)(?:^|\\n)#\\s*\(escaped)\\s*\\n(.*?)(?=\\n#\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    public static func probeDesktopThread(_ threadID: String) throws -> String {
        let desktop = try CodexDesktopIPCClient(timeout: 15)
        defer { desktop.stop() }
        return try desktop.findThreadOwner(threadID)
    }

    public static func activeTurnID(in resumeResponse: [String: Any]) -> String? {
        guard let thread = resumeResponse["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]]
        else { return nil }
        return turns.reversed().first(where: { ($0["status"] as? String) == "inProgress" })?["id"] as? String
    }

    private static func turns(in response: [String: Any]) -> [[String: Any]] {
        guard let thread = response["thread"] as? [String: Any] else { return [] }
        return thread["turns"] as? [[String: Any]] ?? []
    }

    private static func turnIDs(in response: [String: Any]) -> Set<String> {
        Set(turns(in: response).compactMap { $0["id"] as? String })
    }


    private static func waitUntilIdle(
        client: CodexAppServerClient,
        threadID: String,
        initial: [String: Any]
    ) throws -> [String: Any] {
        var response = initial
        let deadline = Date().addingTimeInterval(12)
        while activeTurnID(in: response) != nil {
            guard Date() < deadline else { throw CodexHandoffError.timeout("stop the source task's current turn") }
            Thread.sleep(forTimeInterval: 0.2)
            response = try client.request("thread/resume", params: ["threadId": threadID])
        }
        return response
    }

    private static func waitUntilResumable(
        client: CodexAppServerClient,
        threadID: String
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(12)
        while true {
            do {
                return try client.request("thread/resume", params: ["threadId": threadID])
            } catch {
                guard isActiveWriterError(error), Date() < deadline else { throw error }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private static func isActiveWriterError(_ error: Error) -> Bool {
        guard let handoffError = error as? CodexHandoffError else { return false }
        if case let .rpc(details) = handoffError {
            return details.localizedCaseInsensitiveContains("active writer")
        }
        return false
    }

    private static func copy(_ key: String, from source: [String: Any], to target: inout [String: Any]) {
        if let value = source[key], !(value is NSNull) { target[key] = value }
    }

    private static func sandboxMode(from value: Any?) -> String? {
        guard let policy = value as? [String: Any], let type = policy["type"] as? String else { return nil }
        switch type {
        case "readOnly": return "read-only"
        case "workspaceWrite": return "workspace-write"
        case "dangerFullAccess": return "danger-full-access"
        default:
            // Managed/external sandboxes cannot be faithfully represented by the legacy
            // mode field. Omitting it lets the Codex host reapply its current profile.
            return nil
        }
    }

    fileprivate static func resolveExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static let summaryPrompt = """
    仅使用此任务中已经存在的上下文，生成一份结构化交接摘要，以便在新会话中继续工作。
    不要调用工具、修改文件、开展新工作，也不要声称新任务已经创建。
    以最近一次仍然有效、且得到用户授权的目标为当前目标。旧的交接摘要、接力控制指令、模型路由授权、简短确认和已经被后续消息取代的要求只能作为历史证据，不能自动提升为当前目标或下一步。
    如果某项事实无法从当前任务确认，明确标记“未知/待验证”，不要猜测。保留所有会影响权限、范围、实现、验收和风险的用户约束，并明确区分已验证事实、合理推断和待验证事项。
    仅输出 Markdown，并完整包含以下七个一级标题：
    # 目标
    # 当前状态
    # 已验证完成与证据
    # 关键决策与理由
    # 不可变约束与风险
    # 工作区、分支与变更文件
    # 下一步
    摘要必须足以供无法访问此前聊天记录的新任务继续执行。绝不包含密码、Token、完整命令输出或其他凭据。
    质量和连续性优先于摘要长度；在完整保留会改变后续执行、验收或风险判断的事实后，再去重精简。
    """

    private static func deliverHandoff(
        client: CodexAppServerClient,
        newThreadID: String,
        sourceThreadID: String,
        handoff: String,
        fallbackTurnParams: [String: Any]? = nil,
        progress: Progress
    ) throws -> (turnID: String?, method: HandoffDeliveryMethod) {
        progress("Injecting handoff context into the fresh task")
        do {
            _ = try client.request(
                "thread/inject_items",
                params: HandoffHistoryInjection.requestParams(
                    threadID: newThreadID,
                    sourceThreadID: sourceThreadID,
                    handoff: handoff))
            return (nil, .historyInjection)
        } catch {
            // Older app-server builds may not expose thread/inject_items. Keep the
            // previous acknowledgement turn as a compatibility fallback.
            progress("Direct context injection is unavailable; using compatibility delivery")
            var params = fallbackTurnParams ?? ["threadId": newThreadID]
            params["input"] = [[
                "type": "text",
                "text": acknowledgementPrompt(sourceThreadID: sourceThreadID, handoff: handoff),
            ]]
            let turnID = try client.startTurn(params: params)
            let acknowledgement = try client.waitForTurn(turnID)
            guard !acknowledgement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexHandoffError.invalidResponse("The fresh task did not acknowledge the handoff")
            }
            return (turnID, .acknowledgementTurn)
        }
    }

    private static func restoreSourceName(
        client: CodexAppServerClient,
        threadID: String,
        title: String
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        _ = try? client.request(
            HandoffHistoryInjection.setThreadNameMethod,
            params: ["threadId": threadID, "name": String(cleanTitle.prefix(80))])
    }

    private static func acknowledgementPrompt(sourceThreadID: String, handoff: String) -> String {
        """
        Codex Session Guardian 已从源任务 \(sourceThreadID) 生成并校验以下交接摘要。请将它作为本任务的起始上下文；不要假设能够访问此前聊天记录，也不要扩大其范围或权限。

        <tokenpet_handoff>
        \(handoff)
        </tokenpet_handoff>

        本回合不要调用工具或修改文件。请确认收到，并用一句话复述“下一步”，然后等待用户继续。
        """
    }
}

public struct CodexThreadArchiver: Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 30) throws {
        guard let resolved = executableURL ?? CodexHandoffMigrator.resolveExecutable() else {
            throw CodexHandoffError.executableNotFound
        }
        self.executableURL = resolved
        self.timeout = timeout
    }

    @discardableResult
    public func archive(threadID: String) throws -> Bool {
        let client = try CodexAppServerClient(executableURL: executableURL, timeout: timeout)
        defer { client.stop() }
        _ = try client.request("initialize", params: [
            "clientInfo": [
                "name": "codex-session-guardian",
                "title": "Codex Session Guardian",
                "version": "0.1.0",
            ],
        ])
        try client.notify("initialized", params: nil)
        _ = try client.request("thread/archive", params: ["threadId": threadID])

        guard CodexDesktopIPCClient.isAvailable else { return false }
        do {
            let desktop = try CodexDesktopIPCClient(timeout: 5)
            defer { desktop.stop() }
            try desktop.broadcastThreadArchived(threadID)
            return true
        } catch {
            // The authoritative archive already succeeded. Let the UI explain
            // that Desktop's cached sidebar will catch up after reopening.
            return false
        }
    }
}

private struct CompletedTurn {
    let status: String
    let messages: [String]
    let error: String?
}

private struct CompletedTurnDetails {
    let text: String
    let usage: TokenUsage?
}

private final class JSONMessageInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var messages: [[String: Any]] = []

    func push(_ message: [String: Any]) {
        condition.lock()
        messages.append(message)
        condition.signal()
        condition.unlock()
    }

    func pop(until deadline: Date) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        while messages.isEmpty {
            guard condition.wait(until: deadline) else { return nil }
        }
        return messages.removeFirst()
    }
}

private final class CodexAppServerClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let inbox = JSONMessageInbox()
    private let timeout: TimeInterval
    private let automaticApprovalDecision: String?
    private let writeLock = NSLock()
    private let errorLock = NSLock()
    private var nextID = 1
    private var buffer = Data()
    private var errorText = ""
    private var completedTurns: [String: CompletedTurn] = [:]
    private var turnMessages: [String: [String]] = [:]
    private var latestUsage: TokenUsage?

    init(
        executableURL: URL,
        timeout: TimeInterval,
        automaticApprovalDecision: String? = nil
    ) throws {
        self.timeout = timeout
        self.automaticApprovalDecision = automaticApprovalDecision
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                self.inbox.push(["__eof": true])
                return
            }
            self.consume(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.errorLock.lock()
            self.errorText = String((self.errorText + text).suffix(4_000))
            self.errorLock.unlock()
        }
        try process.run()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func notify(_ method: String, params: [String: Any]?) throws {
        var message: [String: Any] = ["method": method]
        if let params { message["params"] = params }
        try send(message)
    }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while let message = inbox.pop(until: deadline) {
            if message["__eof"] as? Bool == true { throw exitedError() }
            if let responseID = (message["id"] as? NSNumber)?.intValue, responseID == id {
                if let error = message["error"] { throw CodexHandoffError.rpc(Self.describe(error)) }
                guard let result = message["result"] as? [String: Any] else {
                    throw CodexHandoffError.invalidResponse("\(method) is missing result")
                }
                return result
            }
            handleNotification(message)
        }
        throw CodexHandoffError.timeout(method)
    }

    func startTurn(threadID: String, text: String) throws -> String {
        try startTurn(params: [
            "threadId": threadID,
            "input": [["type": "text", "text": text]],
        ])
    }

    func startTurn(params: [String: Any]) throws -> String {
        let response = try request("turn/start", params: params)
        guard let turn = response["turn"] as? [String: Any], let id = turn["id"] as? String else {
            throw CodexHandoffError.invalidResponse("turn/start is missing turn.id")
        }
        return id
    }

    func waitForTurn(_ turnID: String) throws -> String {
        try waitForTurnDetails(turnID).text
    }

    func waitForTurnDetails(_ turnID: String) throws -> CompletedTurnDetails {
        let deadline = Date().addingTimeInterval(timeout)
        while completedTurns[turnID] == nil {
            guard let message = inbox.pop(until: deadline) else {
                throw CodexHandoffError.timeout("finish generation")
            }
            if message["__eof"] as? Bool == true { throw exitedError() }
            handleNotification(message)
        }
        guard let completed = completedTurns.removeValue(forKey: turnID) else {
            throw CodexHandoffError.invalidResponse("Could not find the completed turn")
        }
        guard completed.status == "completed" else {
            throw CodexHandoffError.turnFailed(completed.error ?? completed.status)
        }
        return CompletedTurnDetails(
            text: completed.messages.joined(separator: "\n\n"),
            usage: latestUsage)
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            inbox.push(object)
        }
    }

    private func handleNotification(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any]
        else { return }
        if let automaticApprovalDecision,
           method.hasSuffix("/requestApproval"),
           let requestID = message["id"] {
            if let response = CodexEvaluationTaskRunner.approvalResponse(
                requestID: requestID,
                method: method,
                decision: automaticApprovalDecision) {
                try? send(response)
            }
            return
        }
        if method == "thread/tokenUsage/updated",
           let usage = params["tokenUsage"] as? [String: Any] {
            let raw = (usage["last"] as? [String: Any]) ?? usage
            latestUsage = Self.tokenUsage(raw)
        } else if method == "item/completed",
           let turnID = params["turnId"] as? String,
           let item = params["item"] as? [String: Any],
           item["type"] as? String == "agentMessage",
           let text = item["text"] as? String {
            turnMessages[turnID, default: []].append(text)
        } else if method == "turn/completed",
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String {
            var messages = turnMessages.removeValue(forKey: turnID) ?? []
            if messages.isEmpty, let items = turn["items"] as? [[String: Any]] {
                messages = items.compactMap { item in
                    item["type"] as? String == "agentMessage" ? item["text"] as? String : nil
                }
            }
            completedTurns[turnID] = CompletedTurn(
                status: turn["status"] as? String ?? "completed",
                messages: messages,
                error: Self.describeOptional(turn["error"]))
        }
    }

    private static func tokenUsage(_ raw: [String: Any]) -> TokenUsage {
        TokenUsage(raw: [
            "input_tokens": raw["inputTokens"] ?? raw["input_tokens"] as Any,
            "cached_input_tokens": raw["cachedInputTokens"] ?? raw["cached_input_tokens"] as Any,
            "cache_write_input_tokens": raw["cacheWriteInputTokens"] ?? raw["cache_write_input_tokens"] as Any,
            "output_tokens": raw["outputTokens"] ?? raw["output_tokens"] as Any,
            "reasoning_output_tokens": raw["reasoningOutputTokens"] ?? raw["reasoning_output_tokens"] as Any,
            "total_tokens": raw["totalTokens"] ?? raw["total_tokens"] as Any,
        ])
    }

    private func exitedError() -> CodexHandoffError {
        errorLock.lock()
        let details = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        errorLock.unlock()
        return .appServerExited(details)
    }

    private static func describe(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }

    private static func describeOptional(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return describe(value)
    }
}
