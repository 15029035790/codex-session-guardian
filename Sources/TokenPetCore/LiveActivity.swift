import Foundation

public enum LiveActivityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case thinking
    case readingFile
    case runningCommand
    case callingTool
    case editingFiles
    case waitingForUser
    case responding
    case completed
    case failed
}

public extension LiveActivityKind {
    var petAnimationState: PetAnimationState {
        switch self {
        case .thinking, .readingFile, .callingTool, .failed: .thinking
        case .runningCommand, .editingFiles, .responding: .idle
        case .waitingForUser: .working
        case .completed: .success
        }
    }

    var speechContext: XiaoxinSpeechContext {
        switch self {
        case .thinking: .thinking
        case .readingFile: .reading
        case .runningCommand: .runningCommand
        case .callingTool: .callingTool
        case .editingFiles: .editing
        case .waitingForUser: .waitingForUser
        case .responding: .responding
        case .completed: .success
        case .failed: .failed
        }
    }

    var needsUserAttention: Bool {
        self == .waitingForUser || self == .failed
    }
}

public struct LiveActivityEvent: Equatable, Sendable {
    public var kind: LiveActivityKind
    public var occurredAt: Date
    public var publicSummary: String?
    public var detailCount: Int?

    public init(
        kind: LiveActivityKind,
        occurredAt: Date,
        publicSummary: String? = nil,
        detailCount: Int? = nil
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.publicSummary = publicSummary
        self.detailCount = detailCount
    }
}

public struct SessionLiveActivity: Equatable, Sendable {
    public var kind: LiveActivityKind
    public var updatedAt: Date
    public var publicSummary: String?
    public var detailCount: Int?

    public init(event: LiveActivityEvent, previousSummary: String? = nil) {
        kind = event.kind
        updatedAt = event.occurredAt
        publicSummary = event.publicSummary ?? previousSummary
        detailCount = event.detailCount
    }
}

public struct LiveActivityParser: Sendable {
    public static let maximumSummaryCharacters = 180

    public init() {}

    public func parse(line: Data) -> LiveActivityEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let outerType = object["type"] as? String,
            let payload = object["payload"] as? [String: Any],
            let eventType = payload["type"] as? String
        else { return nil }

        let timestamp = Self.date(object["timestamp"] as? String) ?? Date()
        if outerType == "event_msg" {
            switch eventType {
            case "task_started", "user_message":
                return LiveActivityEvent(kind: .thinking, occurredAt: timestamp)
            case "agent_message":
                return LiveActivityEvent(
                    kind: .responding,
                    occurredAt: timestamp,
                    publicSummary: Self.publicSummary(payload["message"] as? String))
            case "patch_apply_begin", "patch_apply_end":
                return LiveActivityEvent(
                    kind: .editingFiles,
                    occurredAt: timestamp,
                    detailCount: Self.changeCount(payload["changes"]))
            case "waiting_request", "request_user_input", "approval_request":
                return LiveActivityEvent(kind: .waitingForUser, occurredAt: timestamp)
            case "task_complete":
                return LiveActivityEvent(
                    kind: .completed,
                    occurredAt: timestamp,
                    publicSummary: Self.publicSummary(payload["last_agent_message"] as? String))
            case "task_failed", "turn_failed", "turn_aborted":
                return LiveActivityEvent(kind: .failed, occurredAt: timestamp)
            default:
                return nil
            }
        }

        guard outerType == "response_item" else { return nil }
        switch eventType {
        case "custom_tool_call", "function_call":
            let name = payload["name"] as? String ?? ""
            return LiveActivityEvent(kind: Self.kind(forToolNamed: name), occurredAt: timestamp)
        case "message":
            guard payload["role"] as? String == "assistant",
                  let content = payload["content"] as? [[String: Any]]
            else { return nil }
            let text = content.compactMap { item -> String? in
                guard item["type"] as? String == "output_text" else { return nil }
                return item["text"] as? String
            }.joined(separator: "\n")
            return LiveActivityEvent(
                kind: .responding,
                occurredAt: timestamp,
                publicSummary: Self.publicSummary(text))
        case "patch_apply_begin", "patch_apply_end":
            return LiveActivityEvent(
                kind: .editingFiles,
                occurredAt: timestamp,
                detailCount: Self.changeCount(payload["changes"]))
        default:
            // Tool outputs and all reasoning variants are intentionally ignored.
            return nil
        }
    }

    public static func kind(forToolNamed rawName: String) -> LiveActivityKind {
        let name = rawName.lowercased()
        if name.contains("request_user_input") || name.contains("approval") { return .waitingForUser }
        if name.contains("apply_patch") || name.contains("edit") || name.contains("write") { return .editingFiles }
        if name.contains("exec") || name.contains("command") || name.contains("shell") || name.contains("terminal") {
            return .runningCommand
        }
        if name.contains("read") || name.contains("open") || name.contains("view") || name.contains("find") ||
            name.contains("search") || name.contains("list") || name.contains("glob")
        {
            return .readingFile
        }
        return .callingTool
    }

    public static func publicSummary(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let citation = text.range(of: "<oai-mem-citation>", options: .caseInsensitive) {
            text = String(text[..<citation.lowerBound])
        }
        text = text
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maximumSummaryCharacters {
            let end = text.index(text.startIndex, offsetBy: maximumSummaryCharacters)
            text = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }

    private static func changeCount(_ raw: Any?) -> Int? {
        if let array = raw as? [Any] { return array.count }
        if let dictionary = raw as? [String: Any] { return dictionary.count }
        return nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter.liveActivity.date(from: value)
    }
}

public struct LiveActivityStreamCursor: Sendable {
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var fileIdentity: String?
    private var shouldDiscardLeadingFragment = false
    private let replayBytes: UInt64
    private let parser = LiveActivityParser()

    public init(replayBytes: UInt64 = 128 * 1024) {
        self.replayBytes = replayBytes
    }

    public mutating func readAvailable(at url: URL, fileManager: FileManager = .default) throws -> [LiveActivityEvent] {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let identity = "\(device):\(inode)"
        if fileIdentity != identity || size < offset {
            fileIdentity = identity
            offset = size > replayBytes ? size - replayBytes : 0
            remainder.removeAll(keepingCapacity: true)
            shouldDiscardLeadingFragment = offset > 0
        }
        guard size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        offset += UInt64(data.count)
        return consume(data)
    }

    public mutating func consume(_ data: Data) -> [LiveActivityEvent] {
        remainder.append(data)
        guard let lastNewline = remainder.lastIndex(of: 0x0A) else { return [] }
        let complete = Data(remainder.prefix(through: lastNewline))
        remainder = Data(remainder.suffix(from: remainder.index(after: lastNewline)))
        var lines = complete.split(separator: 0x0A, omittingEmptySubsequences: true)
        if shouldDiscardLeadingFragment {
            if !lines.isEmpty { lines.removeFirst() }
            shouldDiscardLeadingFragment = false
        }
        return lines.compactMap { parser.parse(line: Data($0)) }
    }

    public mutating func resetForTests() {
        offset = 0
        remainder.removeAll()
        fileIdentity = nil
        shouldDiscardLeadingFragment = false
    }
}

public final class SessionLiveActivityMonitor: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ sessionID: String, _ event: LiveActivityEvent) -> Void

    private struct Watch {
        var url: URL
        var cursor = LiveActivityStreamCursor()
    }

    private let queue = DispatchQueue(label: "CodexSessionGuardian.LiveActivity", qos: .utility)
    private let handler: EventHandler
    private var watches: [String: Watch] = [:]
    private var timer: DispatchSourceTimer?

    public init(handler: @escaping EventHandler) {
        self.handler = handler
    }

    deinit { timer?.cancel() }

    public func synchronize(pathsBySessionID: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let desired = pathsBySessionID.mapValues { URL(fileURLWithPath: $0) }
            self.watches = desired.reduce(into: [:]) { result, pair in
                if var existing = self.watches[pair.key], existing.url == pair.value {
                    existing.url = pair.value
                    result[pair.key] = existing
                } else {
                    result[pair.key] = Watch(url: pair.value)
                }
            }
            self.updateTimer()
            self.poll()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.watches.removeAll()
            self?.updateTimer()
        }
    }

    private func updateTimer() {
        if watches.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200), leeway: .milliseconds(40))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    private func poll() {
        for sessionID in Array(watches.keys) {
            guard var watch = watches[sessionID] else { continue }
            do {
                let events = try watch.cursor.readAvailable(at: watch.url)
                watches[sessionID] = watch
                for event in events { handler(sessionID, event) }
            } catch {
                // Rollouts may be moved, rotated, or briefly unavailable. Keep the
                // last UI state and retry; scanner synchronization supplies new paths.
                watches[sessionID] = watch
            }
        }
    }
}

private extension ISO8601DateFormatter {
    static let liveActivity: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
