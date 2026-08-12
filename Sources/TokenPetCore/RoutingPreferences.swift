import Foundation

public enum RoutingHabitLane: String, Codable, CaseIterable, Equatable, Sendable {
    case controllerArchitecture
    case frozenExecution
    case judgmentDenseExecution
}

public enum RoutingBaselineStatus: String, Codable, Equatable, Sendable {
    case observedHabit
    case validatedRecommendation
    case rejected
}

public struct RoutingBaselineRoute: Codable, Equatable, Sendable {
    public var lane: RoutingHabitLane
    public var model: String
    public var reasoningEffort: String
    public var status: RoutingBaselineStatus?

    public init(
        lane: RoutingHabitLane,
        model: String,
        reasoningEffort: String,
        status: RoutingBaselineStatus = .observedHabit
    ) {
        self.lane = lane
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.status = status
    }

    public var effectiveStatus: RoutingBaselineStatus { status ?? .observedHabit }
}

public struct RoutingPreferenceProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let currentHabitsPresetID = "current-habits-v2"
    public static let controllerWorkerPresetID = "controller-worker-v1"

    public var schemaVersion: Int
    public var presetID: String
    public var source: String
    public var updatedAt: Date
    public var routes: [RoutingBaselineRoute]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        presetID: String,
        source: String,
        updatedAt: Date,
        routes: [RoutingBaselineRoute]
    ) {
        self.schemaVersion = schemaVersion
        self.presetID = presetID
        self.source = source
        self.updatedAt = updatedAt
        self.routes = routes
    }

    public static func currentHabits(updatedAt: Date = Date()) -> Self {
        Self(
            presetID: currentHabitsPresetID,
            source: "observedHabit",
            updatedAt: updatedAt,
            routes: [
                RoutingBaselineRoute(
                    lane: .controllerArchitecture,
                    model: "gpt-5.6-sol",
                    reasoningEffort: "medium"),
                RoutingBaselineRoute(
                    lane: .frozenExecution,
                    model: "gpt-5.6-luna",
                    reasoningEffort: "max"),
                RoutingBaselineRoute(
                    lane: .judgmentDenseExecution,
                    model: "gpt-5.6-terra",
                    reasoningEffort: "high"),
            ])
    }

    public static func controllerWorker(updatedAt: Date = Date()) -> Self {
        currentHabits(updatedAt: updatedAt)
    }

    public func lanes(model: String, reasoningEffort: String) -> [RoutingHabitLane] {
        routes.filter {
            $0.model.caseInsensitiveCompare(model) == .orderedSame &&
                $0.reasoningEffort.caseInsensitiveCompare(reasoningEffort) == .orderedSame
        }.map(\.lane)
    }
}

public enum OfficialModelRole: String, Codable, CaseIterable, Equatable, Sendable {
    case frontierCapability
    case balancedIntelligenceCost
    case efficientHighVolume
    case unknown
}

public struct OfficialModelGuidance: Codable, Equatable, Sendable {
    public var model: String
    public var role: OfficialModelRole
    public var balancedStartingEffort: String
}

public enum EffortEvaluationState: String, Codable, Equatable, Sendable {
    case baselineAccepted
    case needsRepresentativeComparison
    case noHistoricalSamples
}

public struct EffortEvaluationCandidate: Codable, Equatable, Sendable {
    public var habitLane: RoutingHabitLane
    public var model: String
    public var baselineEffort: String
    public var comparisonEffort: String?
    public var state: EffortEvaluationState
    public var observedTurns: Int
    public var explicitlyVerifiedTurns: Int
    public var reasonCode: String
}

public enum OfficialRoutingPolicy {
    public static let policyVersion = "openai-model-guidance-2026-08-12"

    public static let models: [OfficialModelGuidance] = [
        OfficialModelGuidance(
            model: "gpt-5.6-sol",
            role: .frontierCapability,
            balancedStartingEffort: "medium"),
        OfficialModelGuidance(
            model: "gpt-5.6-terra",
            role: .balancedIntelligenceCost,
            balancedStartingEffort: "medium"),
        OfficialModelGuidance(
            model: "gpt-5.6-luna",
            role: .efficientHighVolume,
            balancedStartingEffort: "medium"),
    ]

    public static func role(for model: String) -> OfficialModelRole {
        models.first { $0.model.caseInsensitiveCompare(model) == .orderedSame }?.role ?? .unknown
    }

    public static func comparisonEffort(for baselineEffort: String) -> String? {
        switch baselineEffort.lowercased() {
        case "max": return "xhigh"
        case "xhigh": return "high"
        case "high": return "medium"
        default: return nil
        }
    }
}

public struct RoutingTaskContract: Codable, Equatable, Sendable {
    public var decisionChangingAmbiguity: Bool
    public var contractFrozen: Bool
    public var tinyOrTightlyCoupled: Bool
    public var architectureOrStrategyWork: Bool
    public var mechanicallyVerifiable: Bool
    public var judgmentDense: Bool
    public var crossModule: Bool
    public var lunaRepairRiskMateriallyHigher: Bool
    public var delegationHasClearValue: Bool
    public var credentialsOrPermissionDecision: Bool
    public var externalMutation: Bool
    public var guiOrDeviceAuthority: Bool

    public init(
        decisionChangingAmbiguity: Bool = false,
        contractFrozen: Bool = false,
        tinyOrTightlyCoupled: Bool = false,
        architectureOrStrategyWork: Bool = false,
        mechanicallyVerifiable: Bool = false,
        judgmentDense: Bool = false,
        crossModule: Bool = false,
        lunaRepairRiskMateriallyHigher: Bool = false,
        delegationHasClearValue: Bool = false,
        credentialsOrPermissionDecision: Bool = false,
        externalMutation: Bool = false,
        guiOrDeviceAuthority: Bool = false
    ) {
        self.decisionChangingAmbiguity = decisionChangingAmbiguity
        self.contractFrozen = contractFrozen
        self.tinyOrTightlyCoupled = tinyOrTightlyCoupled
        self.architectureOrStrategyWork = architectureOrStrategyWork
        self.mechanicallyVerifiable = mechanicallyVerifiable
        self.judgmentDense = judgmentDense
        self.crossModule = crossModule
        self.lunaRepairRiskMateriallyHigher = lunaRepairRiskMateriallyHigher
        self.delegationHasClearValue = delegationHasClearValue
        self.credentialsOrPermissionDecision = credentialsOrPermissionDecision
        self.externalMutation = externalMutation
        self.guiOrDeviceAuthority = guiOrDeviceAuthority
    }
}

public enum RoutingPolicyAction: String, Codable, Equatable, Sendable {
    case clarifyBeforeExecution
    case keepInController
    case delegateToLuna
    case delegateToTerra
}

public struct RoutingPolicyDecision: Codable, Equatable, Sendable {
    public var policyVersion: String
    public var action: RoutingPolicyAction
    public var model: String
    public var reasoningEffort: String
    public var reasonCodes: [String]
    public var evidenceStatus: String
}

/// Deterministic transcription of the locally installed codex-quota-router contract.
/// It describes declared routing behavior; it does not prove that a route is Token-optimal.
public enum CodexQuotaRouterPolicy {
    public static let policyVersion = "codex-quota-router-2026-08-12"

    public static func decide(_ contract: RoutingTaskContract) -> RoutingPolicyDecision {
        if contract.decisionChangingAmbiguity {
            return controllerDecision(
                action: .clarifyBeforeExecution,
                reasons: ["decision_changing_ambiguity"])
        }

        var retainedAuthority: [String] = []
        if contract.credentialsOrPermissionDecision { retainedAuthority.append("credentials_or_permission") }
        if contract.externalMutation { retainedAuthority.append("external_mutation") }
        if contract.guiOrDeviceAuthority { retainedAuthority.append("gui_or_device_authority") }
        if !retainedAuthority.isEmpty {
            return controllerDecision(
                action: .keepInController,
                reasons: retainedAuthority + ["authority_not_delegated"])
        }

        guard contract.contractFrozen else {
            return controllerDecision(action: .keepInController, reasons: ["contract_not_frozen"])
        }
        guard contract.delegationHasClearValue else {
            return controllerDecision(action: .keepInController, reasons: ["delegation_value_not_clear"])
        }
        if contract.tinyOrTightlyCoupled {
            return controllerDecision(action: .keepInController, reasons: ["tiny_or_tightly_coupled"])
        }
        if contract.architectureOrStrategyWork {
            return controllerDecision(action: .keepInController, reasons: ["architecture_or_strategy_owned_by_controller"])
        }

        if contract.judgmentDense,
           contract.crossModule,
           contract.lunaRepairRiskMateriallyHigher {
            return RoutingPolicyDecision(
                policyVersion: policyVersion,
                action: .delegateToTerra,
                model: "gpt-5.6-terra",
                reasoningEffort: "high",
                reasonCodes: [
                    "frozen_judgment_dense_cross_module",
                    "luna_repair_risk_materially_higher",
                ],
                evidenceStatus: "declared-policy-not-token-validated")
        }

        if contract.mechanicallyVerifiable {
            return RoutingPolicyDecision(
                policyVersion: policyVersion,
                action: .delegateToLuna,
                model: "gpt-5.6-luna",
                reasoningEffort: "max",
                reasonCodes: ["frozen_rule_clear_mechanically_verifiable"],
                evidenceStatus: "declared-policy-not-token-validated")
        }

        return controllerDecision(
            action: .keepInController,
            reasons: ["no_safe_execution_lane_proven"])
    }

    private static func controllerDecision(
        action: RoutingPolicyAction,
        reasons: [String]
    ) -> RoutingPolicyDecision {
        RoutingPolicyDecision(
            policyVersion: policyVersion,
            action: action,
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            reasonCodes: reasons,
            evidenceStatus: "declared-policy-not-token-validated")
    }
}

public struct RoutingEvaluationSample: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var comparisonID: String
    public var recordedAt: Date
    public var taskContractFingerprint: String
    public var environmentFingerprint: String?
    public var implementationFingerprint: String
    public var policyVersion: String
    public var habitLane: RoutingHabitLane
    public var model: String
    public var reasoningEffort: String
    public var qualityPassed: Bool
    public var passedChecks: Int
    public var totalChecks: Int
    public var durationSeconds: Double
    public var toolCalls: Int
    public var usage: TokenUsage
    public var evidenceBoundary: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        comparisonID: String,
        recordedAt: Date,
        taskContractFingerprint: String,
        environmentFingerprint: String? = nil,
        implementationFingerprint: String,
        policyVersion: String,
        habitLane: RoutingHabitLane,
        model: String,
        reasoningEffort: String,
        qualityPassed: Bool,
        passedChecks: Int,
        totalChecks: Int,
        durationSeconds: Double,
        toolCalls: Int,
        usage: TokenUsage,
        evidenceBoundary: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.comparisonID = comparisonID
        self.recordedAt = recordedAt
        self.taskContractFingerprint = taskContractFingerprint
        self.environmentFingerprint = environmentFingerprint
        self.implementationFingerprint = implementationFingerprint
        self.policyVersion = policyVersion
        self.habitLane = habitLane
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.qualityPassed = qualityPassed
        self.passedChecks = passedChecks
        self.totalChecks = totalChecks
        self.durationSeconds = durationSeconds
        self.toolCalls = toolCalls
        self.usage = usage
        self.evidenceBoundary = evidenceBoundary
    }
}

public enum RoutingEvaluationGateState: String, Codable, Equatable, Sendable {
    case insufficientComparableSamples
    case candidateFailedQuality
    case candidateTrialReady
    case candidateReadyForPersonalization
    case noMeasuredEfficiencyGain
}

public struct RoutingEvaluationGateResult: Codable, Equatable, Sendable {
    public var state: RoutingEvaluationGateState
    public var baselineEffort: String
    public var candidateEffort: String
    public var comparablePairs: Int
    public var distinctTaskContracts: Int
    public var minimumComparablePairs: Int
    public var minimumDistinctTaskContracts: Int
    public var baselineTotalTokens: Int
    public var candidateTotalTokens: Int
    public var tokenSavingsRatio: Double
    public var baselineDurationSeconds: Double
    public var candidateDurationSeconds: Double
    public var latencySavingsRatio: Double

    public init(
        state: RoutingEvaluationGateState,
        baselineEffort: String,
        candidateEffort: String,
        comparablePairs: Int,
        distinctTaskContracts: Int,
        minimumComparablePairs: Int,
        minimumDistinctTaskContracts: Int,
        baselineTotalTokens: Int,
        candidateTotalTokens: Int,
        tokenSavingsRatio: Double,
        baselineDurationSeconds: Double,
        candidateDurationSeconds: Double,
        latencySavingsRatio: Double
    ) {
        self.state = state
        self.baselineEffort = baselineEffort
        self.candidateEffort = candidateEffort
        self.comparablePairs = comparablePairs
        self.distinctTaskContracts = distinctTaskContracts
        self.minimumComparablePairs = minimumComparablePairs
        self.minimumDistinctTaskContracts = minimumDistinctTaskContracts
        self.baselineTotalTokens = baselineTotalTokens
        self.candidateTotalTokens = candidateTotalTokens
        self.tokenSavingsRatio = tokenSavingsRatio
        self.baselineDurationSeconds = baselineDurationSeconds
        self.candidateDurationSeconds = candidateDurationSeconds
        self.latencySavingsRatio = latencySavingsRatio
    }
}

public enum RoutingEvaluationGate {
    public static func evaluate(
        _ samples: [RoutingEvaluationSample],
        baselineEffort: String,
        candidateEffort: String,
        minimumComparablePairs: Int = 3,
        minimumDistinctTaskContracts: Int = 2
    ) -> RoutingEvaluationGateResult {
        let grouped = Dictionary(grouping: samples, by: \.comparisonID)
        let pairs = grouped.values.compactMap { values -> (RoutingEvaluationSample, RoutingEvaluationSample)? in
            guard let baseline = values.first(where: {
                $0.reasoningEffort.caseInsensitiveCompare(baselineEffort) == .orderedSame
            }), let candidate = values.first(where: {
                $0.reasoningEffort.caseInsensitiveCompare(candidateEffort) == .orderedSame
            }), let baselineEnvironment = baseline.environmentFingerprint,
                  !baselineEnvironment.isEmpty,
                  baselineEnvironment == candidate.environmentFingerprint,
                  baseline.model.caseInsensitiveCompare(candidate.model) == .orderedSame,
                  baseline.habitLane == candidate.habitLane,
                  baseline.taskContractFingerprint == candidate.taskContractFingerprint
            else { return nil }
            return (baseline, candidate)
        }
        let baselineTokens = pairs.reduce(0) { $0 + $1.0.usage.total }
        let candidateTokens = pairs.reduce(0) { $0 + $1.1.usage.total }
        let baselineDuration = pairs.reduce(0) { $0 + $1.0.durationSeconds }
        let candidateDuration = pairs.reduce(0) { $0 + $1.1.durationSeconds }
        let distinctContracts = Set(pairs.map { $0.0.taskContractFingerprint }).count
        let candidateFailedQuality = pairs.contains { !$0.1.qualityPassed }
        let hasEfficiencyGain = candidateTokens < baselineTokens && candidateDuration <= baselineDuration
        let state: RoutingEvaluationGateState
        if pairs.isEmpty {
            state = .insufficientComparableSamples
        } else if candidateFailedQuality {
            state = .candidateFailedQuality
        } else if !hasEfficiencyGain {
            state = .noMeasuredEfficiencyGain
        } else if pairs.count < max(1, minimumComparablePairs) ||
                    distinctContracts < max(1, minimumDistinctTaskContracts) {
            state = .candidateTrialReady
        } else {
            state = .candidateReadyForPersonalization
        }
        return RoutingEvaluationGateResult(
            state: state,
            baselineEffort: baselineEffort,
            candidateEffort: candidateEffort,
            comparablePairs: pairs.count,
            distinctTaskContracts: distinctContracts,
            minimumComparablePairs: max(1, minimumComparablePairs),
            minimumDistinctTaskContracts: max(1, minimumDistinctTaskContracts),
            baselineTotalTokens: baselineTokens,
            candidateTotalTokens: candidateTokens,
            tokenSavingsRatio: savings(baseline: Double(baselineTokens), candidate: Double(candidateTokens)),
            baselineDurationSeconds: baselineDuration,
            candidateDurationSeconds: candidateDuration,
            latencySavingsRatio: savings(baseline: baselineDuration, candidate: candidateDuration))
    }

    private static func savings(baseline: Double, candidate: Double) -> Double {
        guard baseline > 0 else { return 0 }
        return (baseline - candidate) / baseline
    }
}

public typealias RoutingWorkloadLane = RoutingHabitLane
public typealias ConfirmedRoutingRoute = RoutingBaselineRoute
