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

    /// Selects the display from the mascot footprint, never from an expanded
    /// card whose leading edge may cross onto another display.
    public static func visibleFrame(
        forPetAnchor anchor: CGPoint,
        petSize: CGSize,
        screenVisibleFrames: [CGRect]
    ) -> CGRect? {
        let petFrame = CGRect(
            x: anchor.x - petSize.width,
            y: anchor.y,
            width: petSize.width,
            height: petSize.height)
        let petCenter = CGPoint(x: petFrame.midX, y: petFrame.midY)
        if let containingFrame = screenVisibleFrames.first(where: { $0.contains(petCenter) }) {
            return containingFrame
        }
        return screenVisibleFrames.max { first, second in
            intersectionArea(first, petFrame) < intersectionArea(second, petFrame)
        }
    }

    public static func panelOrigin(forPetAnchor anchor: CGPoint, panelSize: CGSize) -> CGPoint {
        CGPoint(x: anchor.x - panelSize.width, y: anchor.y)
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
