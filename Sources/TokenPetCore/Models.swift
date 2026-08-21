import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input = 0
    public var cachedInput = 0
    public var cacheWriteInput = 0
    public var uncachedInput = 0
    public var output = 0
    public var reasoningOutput = 0
    public var total = 0

    public init() {}

    public init(raw: [String: Any]) {
        input = Self.number(raw["input_tokens"])
        cachedInput = min(input, Self.number(raw["cached_input_tokens"]))
        cacheWriteInput = min(
            max(0, input - cachedInput),
            Self.number(raw["cache_write_input_tokens"]))
        uncachedInput = max(0, input - cachedInput - cacheWriteInput)
        output = Self.number(raw["output_tokens"])
        reasoningOutput = Self.number(raw["reasoning_output_tokens"])
        total = Self.number(raw["total_tokens"])
        if total == 0 { total = input + output }
    }

    private static func number(_ value: Any?) -> Int {
        max(0, (value as? NSNumber)?.intValue ?? 0)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        var result = Self()
        result.input = lhs.input + rhs.input
        result.cachedInput = lhs.cachedInput + rhs.cachedInput
        result.cacheWriteInput = lhs.cacheWriteInput + rhs.cacheWriteInput
        result.uncachedInput = lhs.uncachedInput + rhs.uncachedInput
        result.output = lhs.output + rhs.output
        result.reasoningOutput = lhs.reasoningOutput + rhs.reasoningOutput
        result.total = lhs.total + rhs.total
        return result
    }

    public func subtracting(_ previous: Self) -> Self {
        var result = Self()
        result.input = max(0, input - previous.input)
        result.cachedInput = max(0, cachedInput - previous.cachedInput)
        result.cacheWriteInput = max(0, cacheWriteInput - previous.cacheWriteInput)
        result.uncachedInput = max(0, uncachedInput - previous.uncachedInput)
        result.output = max(0, output - previous.output)
        result.reasoningOutput = max(0, reasoningOutput - previous.reasoningOutput)
        result.total = max(0, total - previous.total)
        return result
    }

    public var fingerprint: String {
        [input, cachedInput, cacheWriteInput, uncachedInput, output, reasoningOutput, total]
            .map(String.init).joined(separator: ":")
    }

    public var freshInput: Int { uncachedInput + cacheWriteInput }
    public var cacheHitRate: Double { input > 0 ? Double(cachedInput) / Double(input) : 0 }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?
    public var creditBalance: String?
    public var limitName: String?
    public var limitID: String?
    public var observedAt: Date?

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    public var level: QuotaLevel {
        if remainingPercent <= 20 { return .critical }
        if remainingPercent <= 40 { return .caution }
        return .healthy
    }

    public init(raw: [String: Any], observedAt: Date? = nil) {
        let primary = raw["primary"] as? [String: Any] ?? [:]
        usedPercent = max(0, min(100, (primary["used_percent"] as? NSNumber)?.doubleValue ?? 0))
        windowMinutes = max(0, (primary["window_minutes"] as? NSNumber)?.intValue ?? 0)
        if let timestamp = (primary["resets_at"] as? NSNumber)?.doubleValue, timestamp > 0 {
            resetsAt = Date(timeIntervalSince1970: timestamp)
        } else {
            resetsAt = nil
        }
        let credits = raw["credits"] as? [String: Any]
        creditBalance = credits?["balance"] as? String
        limitName = raw["limit_name"] as? String
        limitID = raw["limit_id"] as? String
        self.observedAt = observedAt
    }

    public static func isValid(raw: [String: Any]) -> Bool {
        guard let primary = raw["primary"] as? [String: Any],
              primary["used_percent"] is NSNumber
        else { return false }
        return true
    }
}

public enum QuotaLevel: String, Codable, Equatable, Sendable {
    case healthy
    case caution
    case critical
}

public enum TurnStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
}

public struct TurnExecutionProfile: Codable, Equatable, Sendable {
    public var readActions = 0
    public var commandActions = 0
    public var toolActions = 0
    public var editActions = 0
    public var agentActions = 0
    public var responseEvents = 0
    public var verificationActions = 0
    public var failureSignals = 0

    public init() {}

    public var observedActions: Int {
        readActions + commandActions + toolActions + editActions + agentActions + responseEvents
    }
}

public enum TurnRisk: String, Codable, CaseIterable, Comparable, Sendable {
    case green
    case amber
    case red

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.green, .amber, .red]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum SessionActivity: String, Sendable {
    case executing
    case waiting
    case interrupted
    case stopped
}

public enum SessionAdvice: String, Sendable {
    case continueCurrent
    case watch
    case startFresh
}

public enum PetAnimationState: String, CaseIterable, Hashable, Sendable {
    case idle
    case working
    case multitask
    case thinking
    case success
    case guardian
}

public struct HealthPolicy: Equatable, Sendable {
    public var amberContext = 0.60
    public var redContext = 0.80
    public var contextSampleCount = 0
    public var freshInputSampleCount = 0
    public var freshInputMedian = 0.0
    public var freshInputMAD = 0.0
    public var compactionSampleCount = 0
    public var compactionPressureMedian = 0.0
    public var compactionPressureMAD = 0.0

    public var isCalibrated: Bool { contextSampleCount >= 20 || freshInputSampleCount >= 20 }
    public var effectiveSampleCount: Int { max(contextSampleCount, freshInputSampleCount) }
    public var freshInputReferenceThreshold: Int? {
        guard freshInputSampleCount >= 20 else { return nil }
        return Int(max(
            20_000,
            freshInputMedian * 2.5,
            freshInputMedian + max(6 * freshInputMAD, 5_000)
        ).rounded(.up))
    }
    public var calibrationLabel: String {
        isCalibrated ? "Personal baseline · \(effectiveSampleCount) samples" : "Cold-start rules · \(effectiveSampleCount)/20"
    }

    static func learned(from turns: [TurnRecord]) -> Self {
        var policy = Self()
        let completedPressure = turns
            .filter { $0.status == .completed && $0.compactions == 0 }
            .compactMap(\.contextPressure)
            .filter { $0 > 0 && $0 < 1 }
            .prefix(200)
            .sorted()
        policy.contextSampleCount = completedPressure.count
        if completedPressure.count >= 20 {
            let upperQuartile = Self.quantile(completedPressure, 0.75)
            let normalized = min(1, max(0, (upperQuartile - 0.35) / 0.35))
            policy.amberContext = ((0.55 + normalized * 0.10) * 100).rounded() / 100
            policy.redContext = ((0.78 + normalized * 0.04) * 100).rounded() / 100
        }

        let fresh = turns.map(\.usage.freshInput).filter { $0 > 0 }.prefix(300).map(Double.init).sorted()
        policy.freshInputSampleCount = fresh.count
        if fresh.count >= 20 {
            policy.freshInputMedian = Self.quantile(fresh, 0.50)
            let deviations = fresh.map { abs($0 - policy.freshInputMedian) }.sorted()
            policy.freshInputMAD = Self.quantile(deviations, 0.50)
        }

        let compacted = turns.filter { $0.compactions > 0 }.compactMap(\.contextPressure).prefix(100).sorted()
        policy.compactionSampleCount = compacted.count
        if compacted.count >= 3 {
            policy.compactionPressureMedian = Self.quantile(compacted, 0.50)
            let deviations = compacted.map { abs($0 - policy.compactionPressureMedian) }.sorted()
            policy.compactionPressureMAD = Self.quantile(deviations, 0.50)
        }
        return policy
    }

    private static func quantile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = Int((Double(values.count - 1) * fraction).rounded())
        return values[min(values.count - 1, max(0, index))]
    }
}

public struct TurnRecord: Codable, Equatable, Identifiable, Sendable {
    public var sessionID: String
    public var turnID: String?
    public var ordinal: Int
    public var cwd: String
    public var model: String?
    public var reasoningEffort: String?
    public var executionProfile: TurnExecutionProfile?
    public var executionWasteProfile: ExecutionWasteProfile?
    public var agentDispatches: [AgentDispatchRecord]?
    public var isSubagent: Bool?
    public var parentThreadID: String?
    public var agentPath: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var status: TurnStatus
    public var calls: Int
    public var usage: TokenUsage
    public var contextWindow: Int
    public var latestPromptInput: Int
    public var compactions: Int
    public var confidence: String
    public var quota: QuotaSnapshot?
    public var lastActivityAt: Date?
    /// Latest rollout `sub_agent_activity` evidence for this turn. It is
    /// retained for Hook health diagnostics while the turn remains hidden from
    /// the user-facing sidebar.
    public var lastSubagentActivityAt: Date?

    public var id: String { "\(sessionID):\(turnID ?? String(ordinal))" }
    public var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }
    public var contextPressure: Double? {
        contextWindow > 0 ? Double(latestPromptInput) / Double(contextWindow) : nil
    }
    public var risk: TurnRisk {
        if (contextPressure ?? 0) >= 0.80 { return .red }
        if (contextPressure ?? 0) >= 0.60 || compactions >= 1 { return .amber }
        return .green
    }
    public var sortDate: Date { completedAt ?? startedAt ?? .distantPast }

    public init(
        sessionID: String,
        turnID: String?,
        ordinal: Int,
        cwd: String,
        startedAt: Date?,
        status: TurnStatus = .running
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.ordinal = ordinal
        self.cwd = cwd
        self.model = nil
        self.reasoningEffort = nil
        self.executionProfile = nil
        self.executionWasteProfile = nil
        self.agentDispatches = nil
        self.isSubagent = nil
        self.parentThreadID = nil
        self.agentPath = nil
        self.startedAt = startedAt
        self.completedAt = nil
        self.status = status
        self.calls = 0
        self.usage = TokenUsage()
        self.contextWindow = 0
        self.latestPromptInput = 0
        self.compactions = 0
        self.confidence = "exact"
        self.quota = nil
        self.lastActivityAt = startedAt
        self.lastSubagentActivityAt = nil
    }
}

public struct SessionSummary: Identifiable, Sendable {
    public var id: String { sessionID }
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var turns: [TurnRecord]
    public var updatedAt: Date
    public var activity: SessionActivity
    public var risk: TurnRisk
    public var usage: TokenUsage
    public var compactions: Int
    public var recentCompactions: Int
    public var advice: SessionAdvice
    public var reason: String
    public var freshInputAnomaly: Bool
    public var postCompactionRebound: Bool

    public var latestTurn: TurnRecord? { turns.first }
    public var isActive: Bool { activity == .executing || activity == .waiting }
    public var canShowResumeWarning: Bool {
        guard activity == .waiting, risk == .red else { return false }
        return postCompactionRebound || recentCompactions > 0
    }
    public var renderIdentity: String {
        let latest = latestTurn
        return [sessionID, activity.rawValue, latest?.status.rawValue ?? "none", latest?.id ?? "none"]
            .joined(separator: ":")
    }
}

public struct DashboardSnapshot: Sendable {
    public var active: [TurnRecord]
    public var recent: [TurnRecord]
    public var sessionTitles: [String: String]
    public var indexedFiles: Int
    public var updatedAt: Date

    public init(
        active: [TurnRecord],
        recent: [TurnRecord],
        sessionTitles: [String: String] = [:],
        indexedFiles: Int,
        updatedAt: Date
    ) {
        self.active = active
        self.recent = recent
        self.sessionTitles = sessionTitles
        self.indexedFiles = indexedFiles
        self.updatedAt = updatedAt
    }

    public var highestRisk: TurnRisk {
        activeSessions.map(\.risk).max() ?? .green
    }

    public var healthPolicy: HealthPolicy {
        var unique: [String: TurnRecord] = [:]
        for turn in active + recent { unique[turn.id] = turn }
        return HealthPolicy.learned(from: unique.values.sorted { $0.sortDate > $1.sortDate })
    }

    public var latestQuota: QuotaSnapshot? {
        let candidates = (active + recent).compactMap { turn -> (QuotaSnapshot, Date)? in
            guard let quota = turn.quota else { return nil }
            return (quota, quota.observedAt ?? turn.sortDate)
        }
        let canonical = candidates.filter { $0.0.limitID == "codex" }
        return (canonical.isEmpty ? candidates : canonical)
            .max { $0.1 < $1.1 }?.0
    }

    public var sessions: [SessionSummary] {
        var unique: [String: TurnRecord] = [:]
        for turn in active + recent { unique[turn.id] = turn }
        let grouped = Dictionary(grouping: unique.values, by: \.sessionID)
        let policy = HealthPolicy.learned(from: unique.values.sorted { $0.sortDate > $1.sortDate })
        return grouped.map { sessionID, values in
            let turns = values.sorted { $0.sortDate > $1.sortDate }
            let usage = turns.reduce(into: TokenUsage()) { $0 = $0 + $1.usage }
            let latest = turns[0]
            let compactions = turns.reduce(0) { $0 + $1.compactions }
            let recentCompactions = turns.prefix(3).reduce(0) { $0 + $1.compactions }
            let activity = Self.activity(for: latest, now: updatedAt)
            let freshInputAnomaly = Self.isFreshInputAnomaly(turns: turns, policy: policy)
            let postCompactionRebound = Self.isPostCompactionRebound(turns: turns, policy: policy)
            let risk = Self.risk(
                    latest: latest,
                    recentCompactions: recentCompactions,
                    freshInputAnomaly: freshInputAnomaly,
                    postCompactionRebound: postCompactionRebound,
                    policy: policy)
            // Context pressure describes resource state; it is not evidence that
            // the current coherent task should be migrated. A fresh-task offer
            // requires the separate task-boundary policy.
            let advice: SessionAdvice = risk == .green ? .continueCurrent : .watch
            return SessionSummary(
                sessionID: sessionID,
                title: title(for: latest),
                cwd: latest.cwd,
                turns: turns,
                updatedAt: latest.lastActivityAt ?? latest.sortDate,
                activity: activity,
                risk: risk,
                usage: usage,
                compactions: compactions,
                recentCompactions: recentCompactions,
                advice: advice,
                reason: Self.reason(
                        latest: latest,
                        risk: risk,
                        recentCompactions: recentCompactions,
                        freshInputAnomaly: freshInputAnomaly,
                        postCompactionRebound: postCompactionRebound,
                        policy: policy),
                freshInputAnomaly: freshInputAnomaly,
                postCompactionRebound: postCompactionRebound)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public var activeSessions: [SessionSummary] {
        sessions.filter(\.isActive)
    }

    public var startFreshSessions: [SessionSummary] {
        sessions.filter { !$0.isActive && $0.risk != .green }
    }

    public var recentHealthySessions: [SessionSummary] {
        sessions.filter { !$0.isActive && $0.risk == .green }
    }

    public func petAnimationState(
        liveActivities: [String: SessionLiveActivity] = [:],
        isHovered: Bool = false,
        hasResumeWarning: Bool = false,
        isCelebrating: Bool = false
    ) -> PetAnimationState {
        let active = activeSessions
        if isHovered { return .guardian }
        if hasResumeWarning { return .thinking }
        let activeIDs = Set(active.map(\.sessionID))
        let live = liveActivities
            .filter { activeIDs.contains($0.key) }
            .map(\.value)
            .sorted { $0.updatedAt > $1.updatedAt }
        if let attention = live.first(where: { $0.kind.needsUserAttention }) {
            return attention.kind.petAnimationState
        }
        if isCelebrating { return .success }
        if let latest = live.first { return latest.kind.petAnimationState }
        if active.contains(where: { $0.activity == .executing }) { return .idle }
        if active.contains(where: { $0.activity == .waiting }) { return .working }
        return .multitask
    }

    public func completedSessionIDs(previouslyActive: Set<String>) -> Set<String> {
        let completed = Set(sessions.filter {
            $0.activity == .stopped && $0.latestTurn?.status == .completed
        }.map(\.sessionID))
        return previouslyActive.intersection(completed)
    }

    public func resumedGuardedSession(
        from previous: DashboardSnapshot,
        excluding excludedSessionIDs: Set<String> = [],
        requiringUserAttention userAttentionSessionIDs: Set<String>
    ) -> SessionSummary? {
        let guarded = Dictionary(
            uniqueKeysWithValues: previous.startFreshSessions
                .filter { $0.risk == .red && $0.advice == .startFresh }
                .map { ($0.sessionID, $0) })
        guard let resumed = activeSessions.first(where: {
            guarded[$0.sessionID] != nil &&
                !excludedSessionIDs.contains($0.sessionID) &&
                userAttentionSessionIDs.contains($0.sessionID) &&
                $0.canShowResumeWarning
        }) else { return nil }
        return resumed
    }

    public func title(for turn: TurnRecord) -> String {
        if let title = sessionTitles[turn.sessionID], !title.isEmpty { return title }
        let project = turn.projectName.isEmpty ? "External project" : turn.projectName
        return "\(project) · \(Self.fallbackDate.string(from: turn.sortDate))"
    }

    private static let fallbackDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private static func activity(for turn: TurnRecord, now: Date) -> SessionActivity {
        guard turn.status == .running else { return .stopped }
        let age = now.timeIntervalSince(turn.lastActivityAt ?? turn.startedAt ?? .distantPast)
        if age <= 45 { return .executing }
        if age <= 5 * 60 { return .waiting }
        return .interrupted
    }

    private static func isFreshInputAnomaly(turns: [TurnRecord], policy: HealthPolicy) -> Bool {
        guard let latest = turns.first else { return false }
        let history = turns.dropFirst().prefix(20).map(\.usage.freshInput).filter { $0 > 0 }.sorted()
        let baseline: Double
        let deviation: Double
        if history.count >= 4 {
            baseline = Double(history[history.count / 2])
            let deviations = history.map { abs(Double($0) - baseline) }.sorted()
            deviation = deviations[deviations.count / 2]
        } else if policy.freshInputSampleCount >= 20 {
            baseline = policy.freshInputMedian
            deviation = policy.freshInputMAD
        } else {
            return false
        }
        let threshold = max(20_000, baseline * 2.5, baseline + max(6 * deviation, 5_000))
        return Double(latest.usage.freshInput) >= threshold
    }

    private static func isPostCompactionRebound(turns: [TurnRecord], policy: HealthPolicy) -> Bool {
        guard let latest = turns.first, let pressure = latest.contextPressure else { return false }
        let learnedRebound = policy.compactionSampleCount >= 3
            ? policy.compactionPressureMedian + max(0.10, 3 * policy.compactionPressureMAD)
            : 0.75
        if latest.compactions > 0 && pressure >= min(policy.redContext, learnedRebound) { return true }
        guard let compacted = turns.dropFirst().prefix(3).first(where: { $0.compactions > 0 }),
              let compactedPressure = compacted.contextPressure
        else { return false }
        let reboundDelta = policy.compactionSampleCount >= 3
            ? min(0.18, max(0.10, 3 * policy.compactionPressureMAD))
            : 0.15
        return pressure >= max(policy.amberContext, 0.70) && pressure - compactedPressure >= reboundDelta
    }

    private static func risk(
        latest: TurnRecord,
        recentCompactions: Int,
        freshInputAnomaly: Bool,
        postCompactionRebound: Bool,
        policy: HealthPolicy
    ) -> TurnRisk {
        if (latest.contextPressure ?? 0) >= policy.redContext || postCompactionRebound { return .red }
        if (latest.contextPressure ?? 0) >= policy.amberContext || recentCompactions > 0 || freshInputAnomaly { return .amber }
        return .green
    }

    private static func reason(
        latest: TurnRecord,
        risk: TurnRisk,
        recentCompactions: Int,
        freshInputAnomaly: Bool,
        postCompactionRebound: Bool,
        policy: HealthPolicy
    ) -> String {
        let pressure = latest.contextPressure.map { "Context \(Int($0 * 100))%" }
        if postCompactionRebound { return "Context rose quickly after a recent compaction. Keep observing task continuity." }
        if (latest.contextPressure ?? 0) >= policy.redContext { return "\(pressure ?? "Context") reached your personalized high-pressure threshold of \(Int(policy.redContext * 100))%." }
        if recentCompactions > 0 { return "This session compacted recently. Watch whether context rebounds quickly." }
        if (latest.contextPressure ?? 0) >= policy.amberContext { return "\(pressure ?? "Context") reached your personalized watch threshold of \(Int(policy.amberContext * 100))%." }
        if freshInputAnomaly { return "Fresh input for this turn is well above this session's personal baseline." }
        if risk == .green { return "Context is below \(Int(policy.amberContext * 100))%, with no compaction or recent input anomaly." }
        return "Watch this session for health changes."
    }
}

public struct ResumeWarningSuppressions: Sendable {
    private var sessionIDs: Set<String> = []

    public init() {}

    public mutating func suppress(_ sessionID: String) {
        sessionIDs.insert(sessionID)
    }

    public mutating func reconcile(with sessions: [SessionSummary]) {
        for session in sessions where session.risk == .green {
            sessionIDs.remove(session.sessionID)
        }
    }

    public func isSuppressed(_ sessionID: String) -> Bool {
        sessionIDs.contains(sessionID)
    }

    public var allSessionIDs: Set<String> { sessionIDs }
}

public struct ResumeWarningBudget: Sendable {
    public var maximumWarningsPerHour: Int
    public var perSessionCooldown: TimeInterval
    private var emittedAt: [Date] = []
    private var latestBySessionID: [String: Date] = [:]

    public init(maximumWarningsPerHour: Int = 2, perSessionCooldown: TimeInterval = 60 * 60) {
        self.maximumWarningsPerHour = max(1, maximumWarningsPerHour)
        self.perSessionCooldown = max(60, perSessionCooldown)
    }

    public mutating func consumeIfAllowed(sessionID: String, at now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-60 * 60)
        emittedAt.removeAll { $0 < cutoff }
        latestBySessionID = latestBySessionID.filter { $0.value >= cutoff }
        guard emittedAt.count < maximumWarningsPerHour else { return false }
        if let latest = latestBySessionID[sessionID], now.timeIntervalSince(latest) < perSessionCooldown {
            return false
        }
        emittedAt.append(now)
        latestBySessionID[sessionID] = now
        return true
    }
}
