import CryptoKit
import Foundation

public enum RoutingQualityEvidence: String, Codable, CaseIterable, Equatable, Sendable {
    case verifiedSuccess
    case verifiedFailure
    case completedUnverified
    case interrupted

    public var isDecisive: Bool {
        self == .verifiedSuccess || self == .verifiedFailure
    }
}

public enum RoutingPostflightQuality: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case insufficientEvidence
}

public enum RoutingPostflightAction: String, Codable, Equatable, Sendable {
    case keepRoute
    case reviewTaskContract
    case requireVerification
}

/// A quality-first interpretation of a completed routed turn. Token and latency
/// are retained for comparison, but they never promote a route without decisive
/// quality evidence.
public struct RoutingPostflightAssessment: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var executed: RoutingSelection
    public var quality: RoutingPostflightQuality
    public var action: RoutingPostflightAction
    public var reasonCode: String
    public var usage: TokenUsage
    public var durationSeconds: Double

    public static func evaluate(_ outcome: RoutingOutcomeObservation) -> Self {
        let executed = RoutingSelection(
            model: outcome.model,
            reasoningEffort: outcome.reasoningEffort)
        switch outcome.qualityEvidence {
        case .verifiedSuccess:
            return Self(
                observedAt: outcome.observedAt,
                executed: executed,
                quality: .passed,
                action: .keepRoute,
                reasonCode: "quality_verified_before_efficiency",
                usage: outcome.usage,
                durationSeconds: outcome.durationSeconds)
        case .verifiedFailure, .interrupted:
            return Self(
                observedAt: outcome.observedAt,
                executed: executed,
                quality: .failed,
                action: .reviewTaskContract,
                reasonCode: outcome.qualityEvidence == .interrupted
                    ? "task_interrupted_quality_not_met"
                    : "verification_failed_quality_not_met",
                usage: outcome.usage,
                durationSeconds: outcome.durationSeconds)
        case .completedUnverified:
            return Self(
                observedAt: outcome.observedAt,
                executed: executed,
                quality: .insufficientEvidence,
                action: .requireVerification,
                reasonCode: "completed_without_quality_evidence",
                usage: outcome.usage,
                durationSeconds: outcome.durationSeconds)
        }
    }

}

public enum RoutingComplexityBucket: String, Codable, Equatable, Sendable {
    case minimal
    case small
    case medium
    case large

    static func classify(_ profile: TurnExecutionProfile?) -> Self {
        let actions = profile?.observedActions ?? 0
        switch actions {
        case ...1: return .minimal
        case 2...4: return .small
        case 5...12: return .medium
        default: return .large
        }
    }
}

/// A privacy-safe observation derived from one local task turn. It deliberately
/// excludes the session ID, title, cwd, prompt, tool arguments, commands, and output.
public struct RoutingOutcomeObservation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let evidencePolicyVersion = "routing-quality-evidence-v1"

    public var schemaVersion: Int
    public var id: String
    public var observedAt: Date
    public var model: String
    public var reasoningEffort: String
    public var matchedHabitLanes: [RoutingHabitLane]
    public var taskShape: TaskShape
    public var complexity: RoutingComplexityBucket
    public var taskClassFingerprint: String
    public var qualityEvidence: RoutingQualityEvidence
    public var durationSeconds: Double
    public var calls: Int
    public var observedActions: Int
    public var usage: TokenUsage
    public var evidencePolicyVersion: String

    public static func derive(
        from turn: TurnRecord,
        routingPreferenceProfile: RoutingPreferenceProfile?
    ) -> Self? {
        guard turn.status != .running,
              let model = nonEmpty(turn.model),
              let effort = nonEmpty(turn.reasoningEffort)
        else { return nil }

        let profile = turn.executionProfile
        let shape = TaskShape.classify(profile)
        let complexity = RoutingComplexityBucket.classify(profile)
        let evidence: RoutingQualityEvidence
        if turn.status == .interrupted {
            evidence = .interrupted
        } else if (profile?.failureSignals ?? 0) > 0 {
            evidence = .verifiedFailure
        } else if (profile?.verificationActions ?? 0) > 0 {
            evidence = .verifiedSuccess
        } else {
            evidence = .completedUnverified
        }

        let actions = profile?.observedActions ?? 0
        let taskClass = [
            shape.rawValue,
            complexity.rawValue,
            profile?.editActions ?? 0 > 0 ? "edits" : "no-edits",
            profile?.agentActions ?? 0 > 0 ? "agents" : "no-agents",
            profile?.verificationActions ?? 0 > 0 || profile?.failureSignals ?? 0 > 0
                ? "verification-observed" : "verification-unobserved",
        ].joined(separator: "|")
        let rawIdentity = "\(turn.id)|\(Self.evidencePolicyVersion)"
        return Self(
            schemaVersion: currentSchemaVersion,
            id: digest(rawIdentity),
            observedAt: turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt ?? .distantPast,
            model: model,
            reasoningEffort: effort,
            matchedHabitLanes: routingPreferenceProfile?.lanes(
                model: model,
                reasoningEffort: effort) ?? [],
            taskShape: shape,
            complexity: complexity,
            taskClassFingerprint: digest(taskClass),
            qualityEvidence: evidence,
            durationSeconds: max(0, (turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt ?? .distantPast)
                .timeIntervalSince(turn.startedAt ?? turn.completedAt ?? .distantPast)),
            calls: max(0, turn.calls),
            observedActions: max(0, actions),
            usage: turn.usage,
            evidencePolicyVersion: evidencePolicyVersion)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct RoutingOutcomeSummary: Codable, Equatable, Sendable {
    public var verifiedSuccesses: Int
    public var verifiedFailures: Int
    public var completedUnverified: Int
    public var interrupted: Int

    public init(
        verifiedSuccesses: Int = 0,
        verifiedFailures: Int = 0,
        completedUnverified: Int = 0,
        interrupted: Int = 0
    ) {
        self.verifiedSuccesses = verifiedSuccesses
        self.verifiedFailures = verifiedFailures
        self.completedUnverified = completedUnverified
        self.interrupted = interrupted
    }

    public var decisiveSamples: Int { verifiedSuccesses + verifiedFailures }

    public static func build(from observations: [RoutingOutcomeObservation]) -> Self {
        observations.reduce(into: Self()) { result, observation in
            switch observation.qualityEvidence {
            case .verifiedSuccess: result.verifiedSuccesses += 1
            case .verifiedFailure: result.verifiedFailures += 1
            case .completedUnverified: result.completedUnverified += 1
            case .interrupted: result.interrupted += 1
            }
        }
    }
}

public enum RoutingCandidateConfidenceState: String, Codable, Equatable, Sendable {
    case notEligible
    case trialReady
    case qualityObserving
    case personalizationReady
    case withdrawn
}

public struct RoutingCandidateConfidence: Codable, Equatable, Sendable {
    public var state: RoutingCandidateConfidenceState
    public var verifiedSuccesses: Int
    public var verifiedFailures: Int
    public var distinctTaskClasses: Int
    public var requiredSuccesses: Int
    public var requiredTaskClasses: Int
}

public enum RoutingOnlineLearningGate {
    public static func evaluate(
        controlledGate: RoutingEvaluationGateResult,
        candidateOutcomes: [RoutingOutcomeObservation],
        requiredSuccesses: Int = 3,
        requiredTaskClasses: Int = 2
    ) -> RoutingCandidateConfidence {
        let successes = candidateOutcomes.filter { $0.qualityEvidence == .verifiedSuccess }
        let failures = candidateOutcomes.filter { $0.qualityEvidence == .verifiedFailure }
        let distinctClasses = Set(successes.map(\.taskClassFingerprint)).count
        let state: RoutingCandidateConfidenceState
        if !failures.isEmpty || controlledGate.state == .candidateFailedQuality {
            state = .withdrawn
        } else if controlledGate.state == .candidateReadyForPersonalization ||
                    (controlledGate.state == .candidateTrialReady &&
                     successes.count >= max(1, requiredSuccesses) &&
                     distinctClasses >= max(1, requiredTaskClasses)) {
            state = .personalizationReady
        } else if controlledGate.state == .candidateTrialReady, !successes.isEmpty {
            state = .qualityObserving
        } else if controlledGate.state == .candidateTrialReady {
            state = .trialReady
        } else {
            state = .notEligible
        }
        return RoutingCandidateConfidence(
            state: state,
            verifiedSuccesses: successes.count,
            verifiedFailures: failures.count,
            distinctTaskClasses: distinctClasses,
            requiredSuccesses: max(1, requiredSuccesses),
            requiredTaskClasses: max(1, requiredTaskClasses))
    }
}
