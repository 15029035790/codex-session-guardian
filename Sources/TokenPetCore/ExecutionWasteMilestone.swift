import Foundation

public enum ExecutionWasteCalibrationMilestoneOutcome: String, Codable, Equatable, Sendable {
    case semanticContinuityReady = "semantic_continuity_ready"
    case continueShadow = "continue_shadow"
}

public struct ExecutionWasteCalibrationMilestone: Codable, Equatable, Identifiable, Sendable {
    public var policyVersion: String
    public var outcome: ExecutionWasteCalibrationMilestoneOutcome
    public var occurredAt: Date
    public var conclusiveSamples: Int
    public var minimumConclusiveSamples: Int
    public var coveredReasonCount: Int
    public var totalReasonCount: Int
    public var precision: Double
    public var precisionTarget: Double

    public var id: String {
        "execution-waste-calibration:\(policyVersion)"
    }

    public static func derive(from summary: ExecutionWasteAccuracySummary) -> Self? {
        let coveredReasons = summary.categories.filter { $0.conclusiveSamples > 0 }.count
        guard summary.overall.conclusiveSamples >= summary.minimumConclusiveSamples,
              coveredReasons == ExecutionWasteReason.allCases.count
        else { return nil }
        let precision = summary.overall.precision ?? 0
        return Self(
            policyVersion: summary.policyVersion,
            outcome: precision >= summary.precisionTarget ? .semanticContinuityReady : .continueShadow,
            occurredAt: summary.generatedAt,
            conclusiveSamples: summary.overall.conclusiveSamples,
            minimumConclusiveSamples: summary.minimumConclusiveSamples,
            coveredReasonCount: coveredReasons,
            totalReasonCount: ExecutionWasteReason.allCases.count,
            precision: precision,
            precisionTarget: summary.precisionTarget)
    }
}

public extension ExecutionWasteAccuracySummary {
    var coveredReasonCount: Int {
        categories.filter { $0.conclusiveSamples > 0 }.count
    }

    var totalReasonCount: Int {
        ExecutionWasteReason.allCases.count
    }
}
