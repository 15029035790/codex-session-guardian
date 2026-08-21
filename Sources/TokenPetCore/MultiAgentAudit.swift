import Foundation

public struct AgentDispatchRecord: Codable, Equatable, Sendable {
    public var taskName: String
    public var agentType: String
    /// The requested inheritance mode. This is intentionally optional: the
    /// rollout does not always include it and a missing value must never be
    /// interpreted as `all`.
    public var forkTurns: String?
    public var model: String?
    public var reasoningEffort: String?
    public var occurredAt: Date
    /// The lifecycle event's call identifier, when the rollout exposed one.
    /// It is used only to join a pending spawn with `sub_agent_activity`.
    public var callID: String?
    /// The child identity/path reported by `sub_agent_activity` or a
    /// successful spawn output. These are optional for old persisted records.
    public var agentThreadID: String?
    public var agentPath: String?

    public init(
        taskName: String,
        agentType: String,
        forkTurns: String?,
        model: String?,
        reasoningEffort: String?,
        occurredAt: Date,
        callID: String? = nil,
        agentThreadID: String? = nil,
        agentPath: String? = nil
    ) {
        self.taskName = taskName
        self.agentType = agentType
        self.forkTurns = forkTurns
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.occurredAt = occurredAt
        self.callID = callID
        self.agentThreadID = agentThreadID
        self.agentPath = agentPath
    }
}

public enum MultiAgentAuditReason: String, Codable, Equatable, Sendable {
    case genericWorkerInheritedFullHistory = "generic_worker_inherited_full_history"
    case boundedWorkerInheritedFullHistory = "bounded_worker_inherited_full_history"
    case unknownAgentInheritedFullHistory = "unknown_agent_inherited_full_history"
    case largeTokenBurn = "large_token_burn"
    case broadParallelFanout = "broad_parallel_fanout"
}

public enum MultiAgentAuditSeverity: String, Codable, Comparable, Equatable, Sendable {
    case reviewAfterCompletion
    case observeDuringExecution

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.reviewAfterCompletion, .observeDuringExecution]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum MultiAgentCostAttribution: String, Codable, Equatable, Sendable {
    /// A single rollout proves the selected inheritance mode and observed
    /// usage, but not how much of that usage was caused by inherited context.
    case observedUsageOnly = "observed_usage_only"
}

public struct MultiAgentAuditFinding: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var parentSessionID: String
    public var parentTurnID: String?
    public var childSessionID: String?
    public var taskName: String
    public var agentType: String
    public var reason: MultiAgentAuditReason
    public var severity: MultiAgentAuditSeverity
    public var isActive: Bool
    public var observedAt: Date
    public var usage: TokenUsage
    public var costAttribution: MultiAgentCostAttribution

    /// A matched `fork_turns:none` baseline is required before this can be
    /// estimated without confusing task work with inheritance overhead.
    public var estimatedAvoidableProviderTokens: Int?

    public var weightedTokenBurn: Int {
        usage.freshInput + usage.output + usage.reasoningOutput + usage.cachedInput / 10
    }
}

public enum MultiAgentAuditPolicy {
    public static let largeProviderTokenThreshold = 10_000_000
    public static let largeWeightedTokenThreshold = 2_000_000
    public static let broadParallelAgentThreshold = 3

    public static func evaluate(turns: [TurnRecord]) -> [MultiAgentAuditFinding] {
        let children = turns.filter { $0.isSubagent == true }
        var findings: [MultiAgentAuditFinding] = []
        for parent in turns where parent.isSubagent != true {
            let dispatches = parent.agentDispatches ?? []
            for dispatch in dispatches {
                let matchingChildren = children.filter {
                    guard $0.parentThreadID == parent.sessionID,
                          ($0.startedAt ?? .distantPast) >= dispatch.occurredAt.addingTimeInterval(-5)
                    else { return false }
                    if let childThreadID = dispatch.agentThreadID {
                        return $0.sessionID == childThreadID
                    }
                    return Self.taskName(from: $0.agentPath) == dispatch.taskName
                }
                let usage = matchingChildren.reduce(into: TokenUsage()) { $0 = $0 + $1.usage }
                let active = matchingChildren.contains { $0.status == .running }
                let childID = matchingChildren.max(by: { $0.sortDate < $1.sortDate })?.sessionID
                // A missing fork scope is unknown, not `all`. Historical
                // records from before this field was optional are still safe:
                // only an explicit value can produce an inheritance finding.
                let inheritedFullHistory = dispatch.forkTurns == "all"
                if inheritedFullHistory {
                    let reason: MultiAgentAuditReason = switch dispatch.agentType {
                    case "worker", "default": .genericWorkerInheritedFullHistory
                    case "unknown": .unknownAgentInheritedFullHistory
                    default: .boundedWorkerInheritedFullHistory
                    }
                    findings.append(Self.finding(
                        parent: parent,
                        dispatch: dispatch,
                        childID: childID,
                        usage: usage,
                        active: active,
                        reason: reason,
                        severity: active ? .observeDuringExecution : .reviewAfterCompletion))
                }
                if usage.total >= largeProviderTokenThreshold,
                   weightedBurn(usage) >= largeWeightedTokenThreshold {
                    findings.append(Self.finding(
                        parent: parent,
                        dispatch: dispatch,
                        childID: childID,
                        usage: usage,
                        active: active,
                        reason: .largeTokenBurn,
                        severity: active ? .observeDuringExecution : .reviewAfterCompletion))
                }
            }
            let dispatchedTaskNames = Set(dispatches.map(\.taskName))
            let activeChildren = Set(children.filter {
                $0.parentThreadID == parent.sessionID &&
                    $0.status == .running &&
                    Self.taskName(from: $0.agentPath).map(dispatchedTaskNames.contains) == true
            }.map(\.sessionID))
            if activeChildren.count >= broadParallelAgentThreshold,
               let latest = dispatches.max(by: { $0.occurredAt < $1.occurredAt }) {
                findings.append(Self.finding(
                    parent: parent,
                    dispatch: latest,
                    childID: nil,
                    usage: TokenUsage(),
                    active: true,
                    reason: .broadParallelFanout,
                    severity: .observeDuringExecution))
            }
        }
        return findings
            .reduce(into: [String: MultiAgentAuditFinding]()) { result, finding in
                if let current = result[finding.id], current.severity >= finding.severity { return }
                result[finding.id] = finding
            }
            .values
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.observedAt > $1.observedAt
            }
    }

    private static func finding(
        parent: TurnRecord,
        dispatch: AgentDispatchRecord,
        childID: String?,
        usage: TokenUsage,
        active: Bool,
        reason: MultiAgentAuditReason,
        severity: MultiAgentAuditSeverity
    ) -> MultiAgentAuditFinding {
        MultiAgentAuditFinding(
            id: [parent.id, dispatch.callID ?? dispatch.taskName, reason.rawValue].joined(separator: ":"),
            parentSessionID: parent.sessionID,
            parentTurnID: parent.turnID,
            childSessionID: childID,
            taskName: dispatch.taskName,
            agentType: dispatch.agentType,
            reason: reason,
            severity: severity,
            isActive: active,
            observedAt: dispatch.occurredAt,
            usage: usage,
            costAttribution: .observedUsageOnly,
            estimatedAvoidableProviderTokens: nil)
    }

    private static func taskName(from path: String?) -> String? {
        path?.split(separator: "/").last.map(String.init)
    }

    private static func weightedBurn(_ usage: TokenUsage) -> Int {
        usage.freshInput + usage.output + usage.reasoningOutput + usage.cachedInput / 10
    }
}

public enum ConfigurationHookHealth: Equatable, Sendable {
    case notInstalled
    case awaitingFirstEvent
    case healthy
    case staleAfterInstallation

    public static func evaluate(
        installed: Bool,
        hookModifiedAt: Date?,
        latestPreflightAt: Date?,
        latestUserTurnAt: Date?,
        now: Date = Date()
    ) -> Self {
        guard installed else { return .notInstalled }
        guard let modified = hookModifiedAt else { return .awaitingFirstEvent }
        if let latestPreflightAt, latestPreflightAt >= modified { return .healthy }
        guard now.timeIntervalSince(modified) >= 60,
              let latestUserTurnAt,
              latestUserTurnAt >= modified.addingTimeInterval(5)
        else { return .awaitingFirstEvent }
        return .staleAfterInstallation
    }
}
