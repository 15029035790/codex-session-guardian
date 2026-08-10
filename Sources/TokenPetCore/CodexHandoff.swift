import Foundation

public struct CodexHandoffResult: Sendable {
    public let sourceThreadID: String
    public let newThreadID: String
    public let handoff: String
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
            return try migrateViaDesktop(
                sourceThreadID: sourceThreadID,
                sourceTitle: sourceTitle,
                cwd: cwd,
                interruptActiveTurn: interruptActiveTurn,
                currentTurnID: currentTurnID,
                progress: progress)
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
        progress("Asking the source task for a handoff")
        let summaryTurnID = try desktop.startFollowUp(
            threadID: sourceThreadID,
            prompt: Self.summaryPrompt,
            ownerID: ownerID)
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
        let started = try client.request("thread/start", params: ["cwd": cwd, "ephemeral": false])
        guard let thread = started["thread"] as? [String: Any],
              let newThreadID = thread["id"] as? String
        else { throw CodexHandoffError.invalidResponse("thread/start is missing thread.id") }
        let cleanTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = String((cleanTitle.isEmpty ? "Continued task" : "\(cleanTitle) · continued").prefix(80))
        _ = try? client.request("thread/setName", params: ["threadId": newThreadID, "name": newTitle])

        progress("Delivering the handoff to the fresh task")
        let destinationTurnID = try client.startTurn(
            threadID: newThreadID,
            text: Self.destinationPrompt(sourceThreadID: sourceThreadID, handoff: handoff))
        let acknowledgement = try client.waitForTurn(destinationTurnID)
        guard !acknowledgement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexHandoffError.invalidResponse("The fresh task did not acknowledge the handoff")
        }

        progress("Handoff complete; opening the fresh task")
        return CodexHandoffResult(
            sourceThreadID: sourceThreadID,
            newThreadID: newThreadID,
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

        progress("Asking the source task for a handoff")
        let summaryTurn = try client.startTurn(threadID: sourceThreadID, text: Self.summaryPrompt)
        let handoff = try client.waitForTurn(summaryTurn)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateHandoff(handoff) else { throw CodexHandoffError.invalidHandoff }

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
        let newTitle = String((cleanTitle.isEmpty ? "Continued task" : "\(cleanTitle) · continued").prefix(80))
        _ = try? client.request("thread/setName", params: ["threadId": newThreadID, "name": newTitle])

        progress("Delivering the handoff to the fresh task")
        var newTurnParams: [String: Any] = [
            "threadId": newThreadID,
            "input": [["type": "text", "text": Self.destinationPrompt(
                sourceThreadID: sourceThreadID,
                handoff: handoff)]],
        ]
        if let effort = resumed["reasoningEffort"] { newTurnParams["effort"] = effort }
        let newTurn = try client.startTurn(params: newTurnParams)
        let acknowledgement = try client.waitForTurn(newTurn)
        guard !acknowledgement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexHandoffError.invalidResponse("The fresh task did not acknowledge the handoff")
        }

        progress("Handoff complete; opening the fresh task")
        return CodexHandoffResult(
            sourceThreadID: sourceThreadID,
            newThreadID: newThreadID,
            handoff: handoff)
    }

    public static func validateHandoff(_ text: String) -> Bool {
        let headingSets = [
            ["Goal", "Current state", "Verified", "Key decisions", "Constraints", "Workspace", "Next step"],
            ["目标", "当前状态", "已验证完成", "关键决策", "约束", "工作区", "下一步"],
        ]
        return text.count >= 120 && headingSets.contains { headings in
            headings.filter { text.localizedCaseInsensitiveContains($0) }.count >= 6
        }
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
    Create a structured handoff using only context already present in this task so the work can continue in a fresh session.
    Do not call tools, modify files, do new work, or claim that a fresh task has already been created.
    Output Markdown only, with all seven top-level headings below:
    # Goal
    # Current state
    # Verified work and evidence
    # Key decisions and rationale
    # Immutable constraints and risks
    # Workspace, branch, and changed files
    # Next step
    Make the handoff sufficient for a task with no access to prior chat history. Separate verified facts, inferences, and pending validation. Never include passwords, tokens, or other credentials.
    Deduplicate aggressively while keeping every fact that changes future execution, acceptance, or risk decisions.
    """

    private static func destinationPrompt(sourceThreadID: String, handoff: String) -> String {
        """
        Codex Session Guardian generated and validated this handoff from source task \(sourceThreadID). Treat it as the starting context for this task. Do not assume access to prior chat history and do not expand its scope or permissions.

        <tokenpet_handoff>
        \(handoff)
        </tokenpet_handoff>

        Do not call tools or modify files in this turn. Confirm receipt and restate the “Next step” in one sentence, then wait for the user to continue.
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
    private let writeLock = NSLock()
    private let errorLock = NSLock()
    private var nextID = 1
    private var buffer = Data()
    private var errorText = ""
    private var completedTurns: [String: CompletedTurn] = [:]
    private var turnMessages: [String: [String]] = [:]

    init(executableURL: URL, timeout: TimeInterval) throws {
        self.timeout = timeout
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
        return completed.messages.joined(separator: "\n\n")
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
        if method == "item/completed",
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
