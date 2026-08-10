import Foundation
import CSQLite3

enum CodexDesktopIPCError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)
    case requestFailed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(details): return "Could not connect to Codex Desktop: \(details)"
        case let .invalidResponse(details): return "Codex Desktop returned an invalid response: \(details)"
        case let .requestFailed(details): return "Codex Desktop request failed: \(details)"
        case let .timeout(step): return "Timed out while waiting for Codex Desktop to \(step)"
        }
    }
}

private final class CodexIPCInbox: @unchecked Sendable {
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

final class CodexDesktopIPCClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let inbox = CodexIPCInbox()
    private let timeout: TimeInterval
    private let writeLock = NSLock()
    private let bufferLock = NSLock()
    private var buffer = Data()
    private var clientID = "initializing-client"

    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock").path
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: defaultSocketPath)
    }

    init(socketPath: String = CodexDesktopIPCClient.defaultSocketPath, timeout: TimeInterval = 30) throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw CodexDesktopIPCError.unavailable("Local IPC is unavailable")
        }
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", socketPath]
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
        try process.run()
        let initialized = try request("initialize", params: ["clientType": "token-pet"])
        guard let result = initialized as? [String: Any], let id = result["clientId"] as? String else {
            throw CodexDesktopIPCError.invalidResponse("initialize is missing clientId")
        }
        clientID = id
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func findThreadOwner(_ threadID: String) throws -> String {
        let response = try requestEnvelope("thread-owner-discovery", params: [
            "hostId": "local",
            "conversationId": threadID,
        ])
        guard let ownerID = response["handledByClientId"] as? String else {
            throw CodexDesktopIPCError.invalidResponse("Could not find the task owner")
        }
        return ownerID
    }

    func interruptConversation(_ threadID: String, turnID: String, ownerID: String) throws {
        _ = try request("thread-follower-interrupt-turn", params: [
            "conversationId": threadID,
            "mode": "user-stop",
            "expectedTurnId": turnID,
        ], targetClientID: ownerID)
    }

    func startFollowUp(threadID: String, prompt: String, ownerID: String) throws -> String {
        let result = try request("thread-follower-start-turn", params: [
            "conversationId": threadID,
            "turnStartParams": [
                "input": [["type": "text", "text": prompt, "text_elements": []]],
            ],
            "mcpAppModelContextAttachments": [],
        ], timeout: 120, targetClientID: ownerID)
        guard let object = result as? [String: Any],
              let nested = object["result"] as? [String: Any],
              let turn = nested["turn"] as? [String: Any],
              let turnID = turn["id"] as? String
        else { throw CodexDesktopIPCError.invalidResponse("start turn is missing turn.id") }
        return turnID
    }

    func broadcastThreadArchived(_ threadID: String) throws {
        try send([
            "type": "broadcast",
            "method": "thread-archived",
            "sourceClientId": clientID,
            "version": 2,
            "params": [
                "hostId": "local",
                "conversationId": threadID,
            ],
        ])
        // Allow nc to flush the framed broadcast before stop() closes the pipe.
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func request(
        _ method: String,
        params: [String: Any],
        timeout requestTimeout: TimeInterval? = nil,
        targetClientID: String? = nil
    ) throws -> Any {
        let response = try requestEnvelope(
            method,
            params: params,
            timeout: requestTimeout,
            targetClientID: targetClientID)
        return response["result"] ?? NSNull()
    }

    private func requestEnvelope(
        _ method: String,
        params: [String: Any],
        timeout requestTimeout: TimeInterval? = nil,
        targetClientID: String? = nil
    ) throws -> [String: Any] {
        let requestID = UUID().uuidString.lowercased()
        var request: [String: Any] = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": Self.protocolVersion(for: method, params: params),
            "method": method,
            "params": params,
            "timeoutMs": Int((requestTimeout ?? timeout) * 1_000),
        ]
        if let targetClientID { request["targetClientId"] = targetClientID }
        try send(request)
        let deadline = Date().addingTimeInterval(requestTimeout ?? timeout)
        while let message = inbox.pop(until: deadline) {
            if message["__eof"] as? Bool == true {
                throw CodexDesktopIPCError.unavailable("IPC connection closed")
            }
            guard message["requestId"] as? String == requestID else { continue }
            if message["resultType"] as? String == "error" {
                throw CodexDesktopIPCError.requestFailed(message["error"] as? String ?? "Unknown error")
            }
            return message
        }
        throw CodexDesktopIPCError.timeout(method)
    }

    private static func protocolVersion(for method: String, params: [String: Any]) -> Int {
        switch method {
        case "thread-owner-discovery", "thread-follower-start-turn":
            return 1
        case "thread-follower-interrupt-turn":
            return params["expectedTurnId"] == nil ? 3 : 4
        default:
            return 0
        }
    }

    private func send(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    private func consume(_ data: Data) {
        bufferLock.lock()
        buffer.append(data)
        while buffer.count >= 4 {
            let length = Int(buffer[0])
                | (Int(buffer[1]) << 8)
                | (Int(buffer[2]) << 16)
                | (Int(buffer[3]) << 24)
            guard length > 0, length <= 256 * 1024 * 1024 else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer[4..<(4 + length)])
            buffer.removeSubrange(0..<(4 + length))
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
            if object["type"] as? String == "client-discovery-request",
               let requestID = object["requestId"] as? String {
                try? send([
                    "type": "client-discovery-response",
                    "requestId": requestID,
                    "response": ["canHandle": false],
                ])
            } else {
                inbox.push(object)
            }
        }
        bufferLock.unlock()
    }
}

final class CodexRolloutTailer: @unchecked Sendable {
    private let path: String
    private var offset: UInt64
    private var remainder = Data()

    init(threadID: String) throws {
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let databasePath = codexHome.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            throw CodexDesktopIPCError.unavailable("Could not read the Codex task index")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw CodexDesktopIPCError.unavailable("Could not query task logs") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pathPointer = sqlite3_column_text(statement, 0)
        else { throw CodexDesktopIPCError.unavailable("Could not find the task log") }
        path = String(cString: pathPointer)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        offset = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func waitForTurn(_ turnID: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var started = false
        var messages: [String] = []
        while Date() < deadline {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            try? handle.close()
            if !data.isEmpty {
                offset += UInt64(data.count)
                var buffer = remainder
                buffer.append(data)
                if let newline = buffer.lastIndex(of: 0x0A) {
                    let complete = Data(buffer.prefix(through: newline))
                    remainder = Data(buffer.suffix(from: buffer.index(after: newline)))
                    for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let type = object["type"] as? String,
                              let payload = object["payload"] as? [String: Any]
                        else { continue }
                        if type == "event_msg", payload["type"] as? String == "task_started",
                           payload["turn_id"] as? String == turnID {
                            started = true
                        } else if started, type == "response_item",
                                  payload["type"] as? String == "message",
                                  payload["role"] as? String == "assistant",
                                  let content = payload["content"] as? [[String: Any]] {
                            messages.append(contentsOf: content.compactMap { item in
                                guard item["type"] as? String == "output_text" else { return nil }
                                return item["text"] as? String
                            })
                        } else if started, type == "event_msg",
                                  payload["type"] as? String == "task_complete" {
                            return messages.joined(separator: "\n\n")
                        }
                    }
                } else {
                    remainder = buffer
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CodexDesktopIPCError.timeout("finish the handoff")
    }
}
