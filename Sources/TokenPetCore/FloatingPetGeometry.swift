import CoreGraphics
import Foundation

public enum FloatingPetGeometry {
    /// Keeps an expanded card set stable across partial scanner snapshots.
    /// Existing sessions refresh when present, while a temporarily missing
    /// session keeps its last rendered value until the panel is collapsed.
    public static func stabilizedSessions(
        frozen: [SessionSummary],
        current: [SessionSummary]
    ) -> [SessionSummary] {
        guard !frozen.isEmpty else { return current }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return frozen.map { currentByID[$0.id] ?? $0 }
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
