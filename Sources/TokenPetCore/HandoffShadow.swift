import Foundation

public enum HandoffShadowRecommendation: String, Codable, Sendable {
    case continueCurrent
    case observe
    case prepareHandoff
}

public enum HandoffShadowReason: String, Codable, Sendable {
    case healthy
    case highPressureOnly
    case recentCompaction
    case postCompactionRebound
    case freshInputAnomaly
    case multipleSignals
}

public struct HandoffShadowOutcome: Codable, Equatable, Sendable {
    public var horizon: Int
    public var observedAt: Date
    public var usage: TokenUsage
    public var compactions: Int
    public var highestContextPressure: Double?
    public var finalRisk: TurnRisk
}

public struct HandoffShadowDecision: Codable, Equatable, Identifiable, Sendable {
    public static let currentPolicyVersion = 1

    public var id: String
    public var sessionID: String
    public var turnID: String
    public var turnOrdinal: Int
    public var observedAt: Date
    public var policyVersion: Int
    public var recommendation: HandoffShadowRecommendation
    public var confidence: Double
    public var reasons: [HandoffShadowReason]
    public var risk: TurnRisk
    public var contextPressure: Double?
    public var contextWindow: Int
    public var recentCompactions: Int
    public var lifetimeCompactions: Int
    public var freshInputAnomaly: Bool
    public var postCompactionRebound: Bool
    public var turnUsage: TokenUsage
    public var completedTurnsObserved: Int
    public var followUpUsage: TokenUsage
    public var followUpCompactions: Int
    public var highestFollowUpContextPressure: Double?
    public var outcomes: [Int: HandoffShadowOutcome]

    public init(
        id: String,
        sessionID: String,
        turnID: String,
        turnOrdinal: Int,
        observedAt: Date,
        recommendation: HandoffShadowRecommendation,
        confidence: Double,
        reasons: [HandoffShadowReason],
        risk: TurnRisk,
        contextPressure: Double?,
        contextWindow: Int,
        recentCompactions: Int,
        lifetimeCompactions: Int,
        freshInputAnomaly: Bool,
        postCompactionRebound: Bool,
        turnUsage: TokenUsage
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.turnOrdinal = turnOrdinal
        self.observedAt = observedAt
        self.policyVersion = Self.currentPolicyVersion
        self.recommendation = recommendation
        self.confidence = confidence
        self.reasons = reasons
        self.risk = risk
        self.contextPressure = contextPressure
        self.contextWindow = contextWindow
        self.recentCompactions = recentCompactions
        self.lifetimeCompactions = lifetimeCompactions
        self.freshInputAnomaly = freshInputAnomaly
        self.postCompactionRebound = postCompactionRebound
        self.turnUsage = turnUsage
        self.completedTurnsObserved = 0
        self.followUpUsage = TokenUsage()
        self.followUpCompactions = 0
        self.highestFollowUpContextPressure = nil
        self.outcomes = [:]
    }

    mutating func observeFollowUp(_ turn: TurnRecord, sessionRisk: TurnRisk, at observedAt: Date) {
        completedTurnsObserved += 1
        followUpUsage = followUpUsage + turn.usage
        followUpCompactions += turn.compactions
        if let pressure = turn.contextPressure {
            highestFollowUpContextPressure = max(highestFollowUpContextPressure ?? pressure, pressure)
        }
        guard [1, 3, 5].contains(completedTurnsObserved) else { return }
        outcomes[completedTurnsObserved] = HandoffShadowOutcome(
            horizon: completedTurnsObserved,
            observedAt: observedAt,
            usage: followUpUsage,
            compactions: followUpCompactions,
            highestContextPressure: highestFollowUpContextPressure,
            finalRisk: sessionRisk)
    }
}

public enum HandoffShadowPolicy {
    public static func evaluate(session: SessionSummary, completedTurn: TurnRecord) -> HandoffShadowDecision? {
        guard completedTurn.status == .completed, let turnID = completedTurn.turnID else { return nil }
        let pressure = completedTurn.contextPressure
        let recommendation: HandoffShadowRecommendation
        let confidence: Double
        var reasons: [HandoffShadowReason] = []

        if session.postCompactionRebound {
            recommendation = .prepareHandoff
            confidence = 0.86
            reasons.append(.postCompactionRebound)
        } else if session.risk == .red && session.recentCompactions > 0 {
            recommendation = .prepareHandoff
            confidence = 0.78
            reasons.append(.multipleSignals)
        } else if session.risk == .red {
            recommendation = .observe
            confidence = 0.68
            reasons.append(.highPressureOnly)
        } else if session.risk == .amber {
            recommendation = .observe
            confidence = 0.72
            if session.recentCompactions > 0 { reasons.append(.recentCompaction) }
            if session.freshInputAnomaly { reasons.append(.freshInputAnomaly) }
            if reasons.isEmpty { reasons.append(.highPressureOnly) }
        } else {
            recommendation = .continueCurrent
            confidence = 0.82
            reasons.append(.healthy)
        }

        return HandoffShadowDecision(
            id: completedTurn.id,
            sessionID: session.sessionID,
            turnID: turnID,
            turnOrdinal: completedTurn.ordinal,
            observedAt: completedTurn.completedAt ?? session.updatedAt,
            recommendation: recommendation,
            confidence: confidence,
            reasons: reasons,
            risk: session.risk,
            contextPressure: pressure,
            contextWindow: completedTurn.contextWindow,
            recentCompactions: session.recentCompactions,
            lifetimeCompactions: session.compactions,
            freshInputAnomaly: session.freshInputAnomaly,
            postCompactionRebound: session.postCompactionRebound,
            turnUsage: completedTurn.usage)
    }
}

public enum HandoffCostStatus: String, Codable, Sendable {
    case pending
    /// The summary was accepted by `thread/inject_items`, but the destination
    /// task has not exposed it through `thread/read` and has no real turn yet.
    case seeded
    /// The destination exposed the marker through `thread/read`, or completed
    /// the compatibility acknowledgement turn.
    case acknowledged
    /// A later, real destination turn started. This is the first state that
    /// proves the new task was actually used for continuation.
    case continued
    /// Kept only so existing ledger rows remain decodable. New handoffs never
    /// write this state because delivery and continuation are distinct facts.
    case complete
}

public enum HandoffPreparationMethod: String, Codable, Sendable {
    case quickCapsule
    case fullSourceSummary
}

public enum HandoffDeliveryMethod: String, Codable, Sendable {
    case historyInjection
    case acknowledgementTurn
}

public struct HandoffCostRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sourceSessionID: String
    public var destinationSessionID: String
    public var sourceSummaryTurnID: String?
    public var destinationAcknowledgementTurnID: String?
    public var preparationMethod: HandoffPreparationMethod
    public var deliveryMethod: HandoffDeliveryMethod
    public var startedAt: Date
    public var completedAt: Date?
    public var payloadCharacters: Int
    public var payloadUTF8Bytes: Int
    public var sourceUsage: TokenUsage?
    public var destinationUsage: TokenUsage?
    public var status: HandoffCostStatus

    public init(
        sourceSessionID: String,
        destinationSessionID: String,
        sourceSummaryTurnID: String?,
        destinationAcknowledgementTurnID: String?,
        preparationMethod: HandoffPreparationMethod,
        deliveryMethod: HandoffDeliveryMethod = .acknowledgementTurn,
        status: HandoffCostStatus? = nil,
        startedAt: Date,
        payload: String
    ) {
        id = "\(sourceSessionID):\(destinationSessionID)"
        self.sourceSessionID = sourceSessionID
        self.destinationSessionID = destinationSessionID
        self.sourceSummaryTurnID = sourceSummaryTurnID
        self.destinationAcknowledgementTurnID = destinationAcknowledgementTurnID
        self.preparationMethod = preparationMethod
        self.deliveryMethod = deliveryMethod
        self.startedAt = startedAt
        self.completedAt = nil
        self.payloadCharacters = payload.count
        self.payloadUTF8Bytes = payload.utf8.count
        self.sourceUsage = sourceSummaryTurnID == nil ? TokenUsage() : nil
        self.destinationUsage = destinationAcknowledgementTurnID == nil ? TokenUsage() : nil
        self.status = status ?? (deliveryMethod == .historyInjection ? .seeded : .pending)
    }

    public var totalUsage: TokenUsage {
        (sourceUsage ?? TokenUsage()) + (destinationUsage ?? TokenUsage())
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceSessionID
        case destinationSessionID
        case sourceSummaryTurnID
        case destinationAcknowledgementTurnID
        case preparationMethod
        case deliveryMethod
        case startedAt
        case completedAt
        case payloadCharacters
        case payloadUTF8Bytes
        case sourceUsage
        case destinationUsage
        case status
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceSessionID = try values.decode(String.self, forKey: .sourceSessionID)
        destinationSessionID = try values.decode(String.self, forKey: .destinationSessionID)
        sourceSummaryTurnID = try values.decodeIfPresent(String.self, forKey: .sourceSummaryTurnID)
        destinationAcknowledgementTurnID = try values.decodeIfPresent(
            String.self,
            forKey: .destinationAcknowledgementTurnID)
        preparationMethod = try values.decode(HandoffPreparationMethod.self, forKey: .preparationMethod)
        deliveryMethod = try values.decodeIfPresent(HandoffDeliveryMethod.self, forKey: .deliveryMethod)
            ?? .acknowledgementTurn
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        payloadCharacters = try values.decode(Int.self, forKey: .payloadCharacters)
        payloadUTF8Bytes = try values.decode(Int.self, forKey: .payloadUTF8Bytes)
        sourceUsage = try values.decodeIfPresent(TokenUsage.self, forKey: .sourceUsage)
        destinationUsage = try values.decodeIfPresent(TokenUsage.self, forKey: .destinationUsage)
        status = try values.decode(HandoffCostStatus.self, forKey: .status)
    }
}

public struct HandoffShadowTelemetrySummary: Equatable, Sendable {
    public var decisionCount: Int
    public var continueCount: Int
    public var observeCount: Int
    public var prepareHandoffCount: Int
    public var pendingHandoffCosts: Int
    public var seededHandoffCosts: Int
    public var acknowledgedHandoffCosts: Int
    public var continuedHandoffCosts: Int
    public var completedHandoffCosts: Int
    public var quickCapsuleHandoffs: Int
    public var fullSummaryHandoffs: Int
    public var historyInjectionHandoffs: Int
    public var acknowledgementTurnHandoffs: Int
    public var handoffUsage: TokenUsage
}
