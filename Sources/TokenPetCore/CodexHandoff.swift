import Foundation

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

public enum CodexHandoffError: LocalizedError {
    case executableNotFound
    case appServerExited(String)
    case invalidResponse(String)
    case rpc(String)
    case timeout(String)
    case turnFailed(String)

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
        case let .turnFailed(details):
            return "Codex task failed: \(details)"
        }
    }
}

public struct CodexEvaluationTaskRunner: Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval

    public init(executableURL: URL? = nil, timeout: TimeInterval = 900) throws {
        guard let resolved = executableURL ?? Self.resolveExecutable() else {
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
            return ["id": requestID, "result": ["scope": "turn", "permissions": [String: Any]()]]
        }
        return ["id": requestID, "result": ["decision": decision]]
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
        let started = try client.request("thread/start", params: Self.threadStartParams(cwd: cwd, model: model))
        guard let thread = started["thread"] as? [String: Any],
              let threadID = thread["id"] as? String
        else { throw CodexHandoffError.invalidResponse("thread/start is missing thread.id") }
        _ = try? client.request("thread/name/set", params: ["threadId": threadID, "name": String(title.prefix(80))])
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
        let started = try client.request("thread/start", params: Self.preflightThreadStartParams(cwd: cwd))
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

    private static func resolveExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

/// Reads Codex's authoritative Hook enablement and trust state. The caller is
/// responsible for caching because starting app-server is intentionally not a
/// per-refresh operation.
public enum CodexHooksListReader {
    public static func read(
        cwds: [String],
        executableURL: URL? = nil,
        timeout: TimeInterval = 5
    ) throws -> [CodexHookMetadata] {
        guard let executableURL = executableURL ?? resolveExecutable() else {
            throw CodexHandoffError.executableNotFound
        }
        let client = try CodexAppServerClient(
            executableURL: executableURL,
            timeout: timeout)
        defer { client.stop() }
        _ = try client.request("initialize", params: [
            "clientInfo": [
                "name": "codex-session-guardian-hooks",
                "title": "Codex Session Guardian Hook Health",
                "version": "0.1.0",
            ],
        ])
        try client.notify("initialized", params: nil)
        let response = try client.request("hooks/list", params: ["cwds": cwds])
        let entries = response["data"] as? [[String: Any]] ?? []
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).map { hook in
                CodexHookMetadata(
                    key: hook["key"] as? String,
                    eventName: hook["eventName"] as? String,
                    command: hook["command"] as? String,
                    sourcePath: hook["sourcePath"] as? String,
                    enabled: hook["enabled"] as? Bool,
                    currentHash: hook["currentHash"] as? String,
                    trustStatus: hook["trustStatus"] as? String)
            }
        }
    }

    private static func resolveExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
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
        return CompletedTurnDetails(text: completed.messages.joined(separator: "\n\n"), usage: latestUsage)
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
           let requestID = message["id"],
           let response = CodexEvaluationTaskRunner.approvalResponse(
                requestID: requestID,
                method: method,
                decision: automaticApprovalDecision) {
            try? send(response)
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
