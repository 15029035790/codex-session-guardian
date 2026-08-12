import Foundation

public struct AgentDispatchRecord: Codable, Equatable, Sendable {
    public var taskName: String
    public var agentType: String
    public var forkTurns: String
    public var model: String?
    public var reasoningEffort: String?
    public var occurredAt: Date

    public init(
        taskName: String,
        agentType: String,
        forkTurns: String,
        model: String?,
        reasoningEffort: String?,
        occurredAt: Date
    ) {
        self.taskName = taskName
        self.agentType = agentType
        self.forkTurns = forkTurns
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.occurredAt = occurredAt
    }
}

public enum MultiAgentAuditReason: String, Codable, Equatable, Sendable {
    case genericWorkerInheritedFullHistory = "generic_worker_inherited_full_history"
    case boundedWorkerInheritedFullHistory = "bounded_worker_inherited_full_history"
    case largeTokenBurn = "large_token_burn"
    case broadParallelFanout = "broad_parallel_fanout"
}

public enum MultiAgentAuditSeverity: String, Codable, Comparable, Equatable, Sendable {
    case reviewAfterCompletion
    case considerInterrupting

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.reviewAfterCompletion, .considerInterrupting]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
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
                    $0.parentThreadID == parent.sessionID &&
                        Self.taskName(from: $0.agentPath) == dispatch.taskName &&
                        ($0.startedAt ?? .distantPast) >= dispatch.occurredAt.addingTimeInterval(-5)
                }
                let usage = matchingChildren.reduce(into: TokenUsage()) { $0 = $0 + $1.usage }
                let active = matchingChildren.contains { $0.status == .running }
                let childID = matchingChildren.max(by: { $0.sortDate < $1.sortDate })?.sessionID
                let inheritedFullHistory = dispatch.forkTurns == "all"
                if inheritedFullHistory {
                    let generic = dispatch.agentType == "worker" || dispatch.agentType == "default"
                    let reason: MultiAgentAuditReason = generic
                        ? .genericWorkerInheritedFullHistory : .boundedWorkerInheritedFullHistory
                    findings.append(Self.finding(
                        parent: parent,
                        dispatch: dispatch,
                        childID: childID,
                        usage: usage,
                        active: active,
                        reason: reason,
                        severity: active && generic ? .considerInterrupting : .reviewAfterCompletion))
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
                        severity: active ? .considerInterrupting : .reviewAfterCompletion))
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
                    severity: .considerInterrupting))
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
            id: [parent.id, dispatch.taskName, reason.rawValue].joined(separator: ":"),
            parentSessionID: parent.sessionID,
            parentTurnID: parent.turnID,
            childSessionID: childID,
            taskName: dispatch.taskName,
            agentType: dispatch.agentType,
            reason: reason,
            severity: severity,
            isActive: active,
            observedAt: dispatch.occurredAt,
            usage: usage)
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
