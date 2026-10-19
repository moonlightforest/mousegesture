import CoreGraphics

/// One on-screen window, as listed front to back by the window server.
public struct ScreenWindow: Equatable, Sendable {
    public let id: UInt32
    public let ownerPID: Int32
    public let bounds: CGRect
    public let layer: Int
    public let alpha: Double

    public init(id: UInt32, ownerPID: Int32, bounds: CGRect, layer: Int, alpha: Double) {
        self.id = id
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
    }
}

public enum PinnedWindowState: Equatable, Sendable {
    /// Not on screen: minimized, hidden or on another Space.
    case hidden
    /// Nothing covers it; the real window is usable as it is.
    case exposed(CGRect)
    /// Another window covers part of it; show the mirror over this frame.
    case covered(CGRect)
}

/// macOS gives no public way to raise another application's window above
/// the rest, so a pinned window is mirrored only while something covers it.
public enum PinPresentation {
    public static func state(
        of windowID: UInt32, frontToBack windows: [ScreenWindow],
        ignoringOwners ignored: Set<Int32>, stageManagerOwners: Set<Int32>, lastFullFrame: CGRect?
    ) -> PinnedWindowState {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return .hidden }
        let pinned = windows[index]

        // In Stage Manager's strip the window becomes a thumbnail under a
        // WindowManager overlay of the same bounds; keep it at full size.
        if windows.contains(where: { stageManagerOwners.contains($0.ownerPID) && $0.bounds == pinned.bounds }) {
            return lastFullFrame.map(PinnedWindowState.covered) ?? .hidden
        }

        let covered = windows[..<index].contains { window in
            guard window.layer == 0, window.alpha > 0,
                  !ignored.contains(window.ownerPID), !stageManagerOwners.contains(window.ownerPID)
            else { return false }
            let overlap = window.bounds.intersection(pinned.bounds)
            return !overlap.isNull && overlap.width > 2 && overlap.height > 2
        }
        return covered ? .covered(pinned.bounds) : .exposed(pinned.bounds)
    }
}
