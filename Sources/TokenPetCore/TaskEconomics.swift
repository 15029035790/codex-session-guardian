import Foundation

public struct TaskConfigurationAggregate: Codable, Equatable, Sendable {
    public var model: String
    public var reasoningEffort: String
    public var completedTurns: Int
    public var sessions: Int
    public var usage: TokenUsage
    public var medianTokensPerTurn: Int
    public var upperQuartileTokensPerTurn: Int

    public init(
        model: String,
        reasoningEffort: String,
        completedTurns: Int,
        sessions: Int,
        usage: TokenUsage,
        medianTokensPerTurn: Int,
        upperQuartileTokensPerTurn: Int
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.completedTurns = completedTurns
        self.sessions = sessions
        self.usage = usage
        self.medianTokensPerTurn = medianTokensPerTurn
        self.upperQuartileTokensPerTurn = upperQuartileTokensPerTurn
    }
}

public enum TaskShape: String, Codable, CaseIterable, Equatable, Sendable {
    case implementation
    case orchestration
    case investigation
    case commandOperation
    case toolAssisted
    case responseOnly
    case unknown

    public static func classify(_ profile: TurnExecutionProfile?) -> Self {
        guard let profile, profile.observedActions > 0 else { return .unknown }
        if profile.agentActions > 0 { return .orchestration }
        if profile.editActions > 0 { return .implementation }
        if profile.readActions >= 2 { return .investigation }
        if profile.commandActions > 0 { return .commandOperation }
        if profile.readActions + profile.toolActions > 0 { return .toolAssisted }
        if profile.responseEvents > 0 { return .responseOnly }
        return .unknown
    }
}

public struct TaskShapeAggregate: Codable, Equatable, Sendable {
    public var shape: TaskShape
    public var completedTurns: Int
    public var tokenObservedTurns: Int
    public var explicitlyVerifiedTurns: Int
    public var usage: TokenUsage
    public var medianTokensPerTurn: Int
}

public struct TaskShapeCount: Codable, Equatable, Sendable {
    public var shape: TaskShape
    public var turns: Int
}

public struct RoutingRouteAggregate: Codable, Equatable, Sendable {
    public var lane: RoutingHabitLane
    public var model: String
    public var reasoningEffort: String
    public var baselineStatus: RoutingBaselineStatus
    public var officialModelRole: OfficialModelRole
    public var observedTurns: Int
    public var explicitlyVerifiedTurns: Int
    public var usage: TokenUsage
    public var taskShapes: [TaskShapeCount]
}

public enum RoutingShadowState: String, Codable, Equatable, Sendable {
    case insufficientEvidence
    case habitBaselineNeedsEvaluation
    case outsideHabitBaseline
}

public struct RoutingShadowDecision: Codable, Equatable, Sendable {
    public var shape: TaskShape
    public var observedModel: String
    public var observedReasoningEffort: String
    public var state: RoutingShadowState
    public var proposedModel: String?
    public var proposedReasoningEffort: String?
    public var matchedHabitLanes: [RoutingHabitLane]
    public var completedTurns: Int
    public var explicitlyVerifiedTurns: Int
    public var confidence: String
    public var reasonCode: String
    public var upgradeCondition: String
}

public struct TaskEconomicsAudit: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var completedTurns: Int
    public var tokenObservedTurns: Int
    public var configuredTurns: Int
    public var unknownConfigurationTurns: Int
    public var configurationCoverage: Double
    public var configurationSwitches: Int
    public var totalUsage: TokenUsage
    public var configurations: [TaskConfigurationAggregate]
    public var profiledTurns: Int
    public var profileCoverage: Double
    public var taskShapes: [TaskShapeAggregate]
    public var routingPreferenceProfile: RoutingPreferenceProfile?
    public var routingRouteMap: [RoutingRouteAggregate]
    public var outsideHabitBaselineTurns: Int
    public var officialRoutingPolicyVersion: String
    public var officialModelGuidance: [OfficialModelGuidance]
    public var effortEvaluationCandidates: [EffortEvaluationCandidate]
    public var shadowDecisions: [RoutingShadowDecision]
    public var routingRecommendationsReady: Bool
    public var evidenceBoundary: String

    public static func build(
        from turns: [TurnRecord],
        routingPreferenceProfile: RoutingPreferenceProfile? = nil
    ) -> Self {
        let completed = turns.filter { $0.status == .completed }
        let tokenObserved = completed.filter { $0.usage.total > 0 }
        let configured = tokenObserved.filter {
            Self.nonEmpty($0.model) != nil && Self.nonEmpty($0.reasoningEffort) != nil
        }
        let grouped = Dictionary(grouping: configured) {
            ConfigurationKey(
                model: Self.nonEmpty($0.model)!,
                reasoningEffort: Self.nonEmpty($0.reasoningEffort)!)
        }
        let configurations = grouped.map { key, values in
            let totals = values.map(\.usage.total).sorted()
            return TaskConfigurationAggregate(
                model: key.model,
                reasoningEffort: key.reasoningEffort,
                completedTurns: values.count,
                sessions: Set(values.map(\.sessionID)).count,
                usage: values.reduce(into: TokenUsage()) { $0 = $0 + $1.usage },
                medianTokensPerTurn: quantile(totals, 0.50),
                upperQuartileTokensPerTurn: quantile(totals, 0.75))
        }.sorted {
            if $0.completedTurns != $1.completedTurns { return $0.completedTurns > $1.completedTurns }
            if $0.model != $1.model { return $0.model < $1.model }
            return $0.reasoningEffort < $1.reasoningEffort
        }
        let profiled = tokenObserved.filter { ($0.executionProfile?.observedActions ?? 0) > 0 }
        let taskShapes = Dictionary(grouping: profiled) { TaskShape.classify($0.executionProfile) }
            .map { shape, values in
                let totals = values.map(\.usage.total).sorted()
                return TaskShapeAggregate(
                    shape: shape,
                    completedTurns: values.count,
                    tokenObservedTurns: values.filter { $0.usage.total > 0 }.count,
                    explicitlyVerifiedTurns: values.filter(Self.hasExplicitQualityEvidence).count,
                    usage: values.reduce(into: TokenUsage()) { $0 = $0 + $1.usage },
                    medianTokensPerTurn: quantile(totals, 0.50))
            }
            .sorted {
                if $0.completedTurns != $1.completedTurns { return $0.completedTurns > $1.completedTurns }
                return $0.shape.rawValue < $1.shape.rawValue
            }
        let routeMap = buildRouteMap(from: configured, profile: routingPreferenceProfile)
        let outsideHabitBaselineTurns: Int
        if let routingPreferenceProfile {
            outsideHabitBaselineTurns = configured.filter { turn in
                guard let model = nonEmpty(turn.model), let effort = nonEmpty(turn.reasoningEffort) else {
                    return true
                }
                return routingPreferenceProfile.lanes(model: model, reasoningEffort: effort).isEmpty
            }.count
        } else {
            outsideHabitBaselineTurns = 0
        }
        let shadowDecisions = buildShadowDecisions(
            from: configured,
            preferenceProfile: routingPreferenceProfile)
        return Self(
            schemaVersion: currentSchemaVersion,
            completedTurns: completed.count,
            tokenObservedTurns: tokenObserved.count,
            configuredTurns: configured.count,
            unknownConfigurationTurns: tokenObserved.count - configured.count,
            configurationCoverage: tokenObserved.isEmpty
                ? 0
                : Double(configured.count) / Double(tokenObserved.count),
            configurationSwitches: countConfigurationSwitches(in: configured),
            totalUsage: tokenObserved.reduce(into: TokenUsage()) { $0 = $0 + $1.usage },
            configurations: configurations,
            profiledTurns: profiled.count,
            profileCoverage: tokenObserved.isEmpty ? 0 : Double(profiled.count) / Double(tokenObserved.count),
            taskShapes: taskShapes,
            routingPreferenceProfile: routingPreferenceProfile,
            routingRouteMap: routeMap,
            outsideHabitBaselineTurns: outsideHabitBaselineTurns,
            officialRoutingPolicyVersion: OfficialRoutingPolicy.policyVersion,
            officialModelGuidance: OfficialRoutingPolicy.models,
            effortEvaluationCandidates: buildEffortEvaluationCandidates(routeMap),
            shadowDecisions: shadowDecisions,
            routingRecommendationsReady: false,
            evidenceBoundary: "Local aggregate of provider Token, recorded model/effort, normalized action counts, and current user habits. Habits are not recommendations. Official model roles define evaluation strata; representative tasks must establish quality before a lower-cost configuration is promoted.")
    }

    private struct ConfigurationKey: Hashable {
        var model: String
        var reasoningEffort: String
    }

    private struct ShadowKey: Hashable {
        var shape: TaskShape
        var model: String
        var reasoningEffort: String
    }

    private static func buildShadowDecisions(
        from turns: [TurnRecord],
        preferenceProfile: RoutingPreferenceProfile?
    ) -> [RoutingShadowDecision] {
        let profiled = turns.filter { ($0.executionProfile?.observedActions ?? 0) > 0 }
        return Dictionary(grouping: profiled) { turn in
            ShadowKey(
                shape: TaskShape.classify(turn.executionProfile),
                model: nonEmpty(turn.model)!,
                reasoningEffort: nonEmpty(turn.reasoningEffort)!)
        }.map { key, values in
            let verified = values.filter(hasExplicitQualityEvidence).count
            let lanes = preferenceProfile?.lanes(
                model: key.model,
                reasoningEffort: key.reasoningEffort) ?? []
            let state: RoutingShadowState
            let reasonCode: String
            let confidence: String
            if preferenceProfile == nil {
                state = .insufficientEvidence
                reasonCode = "habit_baseline_not_recorded"
                confidence = "insufficient"
            } else if lanes.isEmpty {
                state = .outsideHabitBaseline
                reasonCode = "configuration_outside_habit_baseline"
                confidence = "observed-only"
            } else {
                state = .habitBaselineNeedsEvaluation
                reasonCode = "habit_observed_not_validated"
                confidence = "habit-only"
            }
            return RoutingShadowDecision(
                shape: key.shape,
                observedModel: key.model,
                observedReasoningEffort: key.reasoningEffort,
                state: state,
                proposedModel: nil,
                proposedReasoningEffort: nil,
                matchedHabitLanes: lanes,
                completedTurns: values.count,
                explicitlyVerifiedTurns: verified,
                confidence: confidence,
                reasonCode: reasonCode,
                upgradeCondition: "Promote a route only after representative tasks preserve success, completeness, required evidence, and acceptable latency while improving Token or cost.")
        }.sorted {
            if $0.state != $1.state { return $0.state.rawValue > $1.state.rawValue }
            if $0.completedTurns != $1.completedTurns { return $0.completedTurns > $1.completedTurns }
            if $0.shape != $1.shape { return $0.shape.rawValue < $1.shape.rawValue }
            if $0.observedModel != $1.observedModel { return $0.observedModel < $1.observedModel }
            return $0.observedReasoningEffort < $1.observedReasoningEffort
        }
    }

    private static func buildRouteMap(
        from turns: [TurnRecord],
        profile: RoutingPreferenceProfile?
    ) -> [RoutingRouteAggregate] {
        guard let profile else { return [] }
        return profile.routes.map { route in
            let matches = turns.filter {
                nonEmpty($0.model)?.caseInsensitiveCompare(route.model) == .orderedSame &&
                    nonEmpty($0.reasoningEffort)?.caseInsensitiveCompare(route.reasoningEffort) == .orderedSame
            }
            let shapes = Dictionary(grouping: matches) { TaskShape.classify($0.executionProfile) }
                .map { TaskShapeCount(shape: $0.key, turns: $0.value.count) }
                .sorted {
                    if $0.turns != $1.turns { return $0.turns > $1.turns }
                    return $0.shape.rawValue < $1.shape.rawValue
                }
            return RoutingRouteAggregate(
                lane: route.lane,
                model: route.model,
                reasoningEffort: route.reasoningEffort,
                baselineStatus: route.effectiveStatus,
                officialModelRole: OfficialRoutingPolicy.role(for: route.model),
                observedTurns: matches.count,
                explicitlyVerifiedTurns: matches.filter(hasExplicitQualityEvidence).count,
                usage: matches.reduce(into: TokenUsage()) { $0 = $0 + $1.usage },
                taskShapes: shapes)
        }
    }

    private static func buildEffortEvaluationCandidates(
        _ routeMap: [RoutingRouteAggregate]
    ) -> [EffortEvaluationCandidate] {
        routeMap.map { route in
            let comparison = OfficialRoutingPolicy.comparisonEffort(for: route.reasoningEffort)
            let state: EffortEvaluationState
            let reasonCode: String
            if route.observedTurns == 0 {
                state = .noHistoricalSamples
                reasonCode = "no_historical_samples"
            } else if comparison == nil {
                state = .baselineAccepted
                reasonCode = "balanced_effort_baseline"
            } else {
                state = .needsRepresentativeComparison
                reasonCode = route.reasoningEffort.lowercased() == "max"
                    ? "compare_max_with_xhigh"
                    : "higher_effort_requires_measured_gain"
            }
            return EffortEvaluationCandidate(
                habitLane: route.lane,
                model: route.model,
                baselineEffort: route.reasoningEffort,
                comparisonEffort: comparison,
                state: state,
                observedTurns: route.observedTurns,
                explicitlyVerifiedTurns: route.explicitlyVerifiedTurns,
                reasonCode: reasonCode)
        }
    }

    private static func hasExplicitQualityEvidence(_ turn: TurnRecord) -> Bool {
        turn.status == .completed &&
            (turn.executionProfile?.verificationActions ?? 0) > 0 &&
            (turn.executionProfile?.failureSignals ?? 0) == 0
    }

    private static func countConfigurationSwitches(in turns: [TurnRecord]) -> Int {
        Dictionary(grouping: turns, by: \.sessionID).values.reduce(0) { total, sessionTurns in
            let ordered = sessionTurns.sorted { $0.ordinal < $1.ordinal }
            let keys = ordered.compactMap { turn -> ConfigurationKey? in
                guard let model = nonEmpty(turn.model),
                      let effort = nonEmpty(turn.reasoningEffort)
                else { return nil }
                return ConfigurationKey(model: model, reasoningEffort: effort)
            }
            return total + zip(keys, keys.dropFirst()).filter { $0.0 != $0.1 }.count
        }
    }

    private static func quantile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let index = Int((Double(values.count - 1) * fraction).rounded())
        return values[min(values.count - 1, max(0, index))]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
