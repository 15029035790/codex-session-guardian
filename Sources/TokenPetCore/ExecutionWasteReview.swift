import Foundation

public enum ExecutionWasteReviewVerdict: String, Codable, CaseIterable, Equatable, Sendable {
    case confirmedWaste = "confirmed_waste"
    case justified
    case unclear
}

public enum ExecutionWasteReviewRationale: String, Codable, CaseIterable, Equatable, Sendable {
    case confirmedRedundant = "confirmed_redundant"
    case intentionalRecheck = "intentional_recheck"
    case necessaryRecovery = "necessary_recovery"
    case necessaryEvidence = "necessary_evidence"
    case detectorMismatch = "detector_mismatch"
    case insufficientContext = "insufficient_context"
}

public enum ExecutionWasteReviewValidationError: LocalizedError, Equatable {
    case invalidObservationID
    case incompatibleRationale
    case observationNotFound
    case reasonNotObserved

    public var errorDescription: String? {
        switch self {
        case .invalidObservationID:
            return "execution-waste observation ID must be a 64-character lowercase SHA-256 hash"
        case .incompatibleRationale:
            return "review rationale is incompatible with the selected verdict"
        case .observationNotFound:
            return "execution-waste observation was not found"
        case .reasonNotObserved:
            return "the selected waste reason was not observed in this sample"
        }
    }
}

public struct ExecutionWasteReviewLabel: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var observationID: String
    public var reason: ExecutionWasteReason
    public var verdict: ExecutionWasteReviewVerdict
    public var rationale: ExecutionWasteReviewRationale
    public var recordedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        observationID: String,
        reason: ExecutionWasteReason,
        verdict: ExecutionWasteReviewVerdict,
        rationale: ExecutionWasteReviewRationale,
        recordedAt: Date
    ) throws {
        guard observationID.count == 64,
              observationID.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw ExecutionWasteReviewValidationError.invalidObservationID }
        guard Self.allowedRationales(for: verdict).contains(rationale)
        else { throw ExecutionWasteReviewValidationError.incompatibleRationale }
        self.schemaVersion = schemaVersion
        self.observationID = observationID
        self.reason = reason
        self.verdict = verdict
        self.rationale = rationale
        self.recordedAt = recordedAt
    }

    public static func allowedRationales(
        for verdict: ExecutionWasteReviewVerdict
    ) -> [ExecutionWasteReviewRationale] {
        switch verdict {
        case .confirmedWaste:
            return [.confirmedRedundant]
        case .justified:
            return [
                .intentionalRecheck,
                .necessaryRecovery,
                .necessaryEvidence,
                .detectorMismatch,
            ]
        case .unclear:
            return [.insufficientContext]
        }
    }
}

public struct ExecutionWasteReviewItem: Codable, Equatable, Sendable {
    public var observation: ExecutionWasteObservation
    public var labels: [ExecutionWasteReviewLabel]

    public var isFullyLabeled: Bool {
        let observed = Set(observation.evidence.map(\.reason))
        let labeled = Set(labels.map(\.reason))
        return !observed.isEmpty && observed.isSubset(of: labeled)
    }
}

public struct ExecutionWasteAccuracyMetrics: Codable, Equatable, Sendable {
    public var reason: ExecutionWasteReason?
    public var detectedSamples: Int
    public var detectedOccurrences: Int
    public var labeledSamples: Int
    public var confirmedWaste: Int
    public var justified: Int
    public var unclear: Int
    public var conclusiveSamples: Int
    public var labelCoverage: Double
    public var precision: Double?

    public init(
        reason: ExecutionWasteReason?,
        detectedSamples: Int,
        detectedOccurrences: Int,
        labeledSamples: Int,
        confirmedWaste: Int,
        justified: Int,
        unclear: Int,
        conclusiveSamples: Int,
        labelCoverage: Double,
        precision: Double?
    ) {
        self.reason = reason
        self.detectedSamples = detectedSamples
        self.detectedOccurrences = detectedOccurrences
        self.labeledSamples = labeledSamples
        self.confirmedWaste = confirmedWaste
        self.justified = justified
        self.unclear = unclear
        self.conclusiveSamples = conclusiveSamples
        self.labelCoverage = labelCoverage
        self.precision = precision
    }
}

public enum ExecutionWasteCalibrationState: String, Codable, Equatable, Sendable {
    case collectingLabels = "collecting_labels"
    case precisionBelowTarget = "precision_below_target"
    case precisionTargetMet = "precision_target_met"
}

public struct ExecutionWasteAccuracySummary: Codable, Equatable, Sendable {
    public var policyVersion: String
    public var generatedAt: Date
    public var minimumConclusiveSamples: Int
    public var precisionTarget: Double
    public var state: ExecutionWasteCalibrationState
    public var overall: ExecutionWasteAccuracyMetrics
    public var categories: [ExecutionWasteAccuracyMetrics]

    public static func build(
        observations: [ExecutionWasteObservation],
        labels: [ExecutionWasteReviewLabel],
        generatedAt: Date = Date(),
        minimumConclusiveSamples: Int = 30,
        precisionTarget: Double = 0.8
    ) -> Self {
        let observations = observations.filter {
            $0.policyVersion == ExecutionWasteObservation.currentPolicyVersion
        }
        let labelsByKey = Dictionary(
            labels.map { (key($0.observationID, $0.reason), $0) },
            uniquingKeysWith: { current, candidate in
                candidate.recordedAt >= current.recordedAt ? candidate : current
            })
        let categories = ExecutionWasteReason.allCases.map { reason in
            metrics(reason: reason, observations: observations, labelsByKey: labelsByKey)
        }
        let overall = metrics(reason: nil, observations: observations, labelsByKey: labelsByKey)
        let minimum = max(1, minimumConclusiveSamples)
        let target = min(1, max(0, precisionTarget))
        let state: ExecutionWasteCalibrationState
        if overall.conclusiveSamples < minimum {
            state = .collectingLabels
        } else if (overall.precision ?? 0) < target {
            state = .precisionBelowTarget
        } else {
            state = .precisionTargetMet
        }
        return Self(
            policyVersion: ExecutionWasteObservation.currentPolicyVersion,
            generatedAt: generatedAt,
            minimumConclusiveSamples: minimum,
            precisionTarget: target,
            state: state,
            overall: overall,
            categories: categories)
    }

    private static func metrics(
        reason selectedReason: ExecutionWasteReason?,
        observations: [ExecutionWasteObservation],
        labelsByKey: [String: ExecutionWasteReviewLabel]
    ) -> ExecutionWasteAccuracyMetrics {
        var detectedSamples = 0
        var detectedOccurrences = 0
        var selectedLabels: [ExecutionWasteReviewLabel] = []
        for observation in observations {
            for evidence in observation.evidence where selectedReason == nil || evidence.reason == selectedReason {
                detectedSamples += 1
                detectedOccurrences += max(0, evidence.occurrences)
                if let label = labelsByKey[key(observation.id, evidence.reason)] {
                    selectedLabels.append(label)
                }
            }
        }
        let confirmed = selectedLabels.filter { $0.verdict == .confirmedWaste }.count
        let justified = selectedLabels.filter { $0.verdict == .justified }.count
        let unclear = selectedLabels.filter { $0.verdict == .unclear }.count
        let conclusive = confirmed + justified
        return ExecutionWasteAccuracyMetrics(
            reason: selectedReason,
            detectedSamples: detectedSamples,
            detectedOccurrences: detectedOccurrences,
            labeledSamples: selectedLabels.count,
            confirmedWaste: confirmed,
            justified: justified,
            unclear: unclear,
            conclusiveSamples: conclusive,
            labelCoverage: detectedSamples > 0 ? Double(selectedLabels.count) / Double(detectedSamples) : 0,
            precision: conclusive > 0 ? Double(confirmed) / Double(conclusive) : nil)
    }

    private static func key(_ observationID: String, _ reason: ExecutionWasteReason) -> String {
        "\(observationID)|\(reason.rawValue)"
    }
}
