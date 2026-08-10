import Foundation

public struct RolloutState: Codable, Equatable, Sendable {
    public var sessionID: String?
    public var cwd = ""
    public var classificationVersion: Int?
    public var isSubagent: Bool?
    public var parentThreadID: String?
    public var ordinal = 0
    public var active: TurnRecord?
    public var cumulative: TokenUsage?
    public var recentFingerprints: [String] = []
    public var latestQuota: QuotaSnapshot?

    public init() {}

    public mutating func process(line: Data) -> TurnRecord? {
        let relevant = line.range(of: Self.sessionMetaNeedle) != nil ||
            line.range(of: Self.eventMessageNeedle) != nil ||
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
            classificationVersion = 1
            if active?.cwd.isEmpty == true { active?.cwd = cwd }
            return nil
        }

        guard type == "event_msg" || type == "response_item" else { return nil }
        let eventType = payload["type"] as? String ?? ""
        if type == "event_msg", eventType == "task_started" || eventType == "user_message" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String ?? payload["id"] as? String)
            if let timestamp { active?.lastActivityAt = timestamp }
            return active
        }
        if type == "event_msg", eventType == "task_complete" {
            ensureTurn(timestamp: timestamp, turnID: payload["turn_id"] as? String)
            active?.completedAt = timestamp
            if let timestamp { active?.lastActivityAt = timestamp }
            active?.status = .completed
            let completed = active
            active = nil
            return completed
        }
        if (type == "response_item" && eventType == "context_compaction") ||
            (type == "event_msg" && ["context_compacted", "thread_compacted"].contains(eventType))
        {
            active?.compactions += 1
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
        active?.quota = latestQuota
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter.tokenPet.date(from: value)
    }

    private static let sessionMetaNeedle = Data(#""type":"session_meta""#.utf8)
    private static let eventMessageNeedle = Data(#""type":"event_msg""#.utf8)
    private static let compactionNeedle = Data(#""context_compaction""#.utf8)
}

private extension ISO8601DateFormatter {
    static let tokenPet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
