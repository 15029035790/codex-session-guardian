import Foundation

public enum GuardianInboxKind: String, Codable, Equatable, Sendable {
    case waitingForUser
    case failed
    case completed
    case healthWatch
    case healthCritical
    case calibrationReady
    case calibrationContinueShadow
}

public struct GuardianInboxItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var sessionTitle: String
    public var kind: GuardianInboxKind
    public var occurredAt: Date
    public var publicSummary: String?
    public var isRead: Bool
    public var opensSession: Bool

    public init(
        sessionID: String,
        sessionTitle: String,
        kind: GuardianInboxKind,
        occurredAt: Date,
        publicSummary: String? = nil,
        isRead: Bool = false,
        opensSession: Bool = true,
        id: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.kind = kind
        self.occurredAt = occurredAt
        self.publicSummary = publicSummary
        self.isRead = isRead
        self.opensSession = opensSession
        self.id = id ?? "\(sessionID):\(kind.rawValue):\(occurredAt.timeIntervalSince1970)"
    }
}

public struct GuardianInboxState: Equatable, Sendable {
    public static let maximumItems = 50
    public private(set) var items: [GuardianInboxItem] = []

    public init() {}

    public var unreadCount: Int { items.lazy.filter { !$0.isRead }.count }

    @discardableResult
    public mutating func record(_ item: GuardianInboxItem) -> Bool {
        guard !items.contains(where: { $0.id == item.id }) else { return false }
        items.append(item)
        items.sort { $0.occurredAt > $1.occurredAt }
        if items.count > Self.maximumItems {
            items.removeLast(items.count - Self.maximumItems)
        }
        return true
    }

    public mutating func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead = true
    }

    public mutating func markAllRead() {
        for index in items.indices { items[index].isRead = true }
    }

    public static func kind(for activity: LiveActivityKind) -> GuardianInboxKind? {
        switch activity {
        case .waitingForUser: .waitingForUser
        case .failed: .failed
        case .completed: .completed
        default: nil
        }
    }

    public static func healthKind(from previous: TurnRisk, to next: TurnRisk) -> GuardianInboxKind? {
        guard next > previous else { return nil }
        return next == .red ? .healthCritical : .healthWatch
    }
}
