import CoreGraphics
import Foundation

public enum FloatingPetShowPlacement: Equatable, Sendable {
    case initializeFromSavedAnchor
    case preserveCurrentFrame
}

public struct FloatingPetVisibilityLifecycle: Sendable {
    private var hasShown = false

    public init() {}

    public mutating func nextShowPlacement() -> FloatingPetShowPlacement {
        guard !hasShown else { return .preserveCurrentFrame }
        hasShown = true
        return .initializeFromSavedAnchor
    }
}

public enum SessionRefreshCadence {
    public static func interval(
        statusPanelVisible: Bool,
        floatingWorkspaceVisible: Bool
    ) -> TimeInterval {
        statusPanelVisible || floatingWorkspaceVisible ? 2 : 10
    }
}

public enum FloatingPetGeometry {
    /// Keeps an expanded card set stable across partial scanner snapshots.
    /// Current sessions keep the scanner's ordering, newly discovered sessions
    /// are appended immediately, and a temporarily missing frozen session keeps
    /// its last rendered value until the panel is collapsed.
    public static func stabilizedSessions(
        frozen: [SessionSummary],
        current: [SessionSummary]
    ) -> [SessionSummary] {
        guard !frozen.isEmpty else { return current }
        let currentIDs = Set(current.map(\.id))
        return current + frozen.filter { !currentIDs.contains($0.id) }
    }

    /// Keeps the pet itself visible without coupling its persistent anchor to
    /// the transient size of an expanded status panel.
    public static func constrainedPetAnchor(
        _ anchor: CGPoint,
        petSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(anchor.x, visibleFrame.minX + petSize.width), visibleFrame.maxX),
            y: min(
                max(anchor.y, visibleFrame.minY),
                max(visibleFrame.minY, visibleFrame.maxY - petSize.height)))
    }

    public static func panelOrigin(forPetAnchor anchor: CGPoint, panelSize: CGSize) -> CGPoint {
        CGPoint(x: anchor.x - panelSize.width, y: anchor.y)
    }
}
