import CoreGraphics
import Testing
@testable import MouseGestureCore

struct PinPresentationTests {
    private let pinnedFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
    private func window(_ id: UInt32, pid: Int32, _ frame: CGRect, layer: Int = 0) -> ScreenWindow {
        ScreenWindow(id: id, ownerPID: pid, bounds: frame, layer: layer, alpha: 1)
    }
    private func state(_ windows: [ScreenWindow], last: CGRect? = nil) -> PinnedWindowState {
        PinPresentation.state(of: 1, frontToBack: windows, ignoringOwners: [99],
                              stageManagerOwners: [50], lastFullFrame: last)
    }

    @Test func frontmostWindowNeedsNoMirror() {
        #expect(state([window(1, pid: 10, pinnedFrame), window(2, pid: 20, pinnedFrame)]) == .exposed(pinnedFrame))
    }

    @Test func overlappingWindowInFrontShowsMirror() {
        let other = window(2, pid: 20, CGRect(x: 300, y: 200, width: 400, height: 300))
        #expect(state([other, window(1, pid: 10, pinnedFrame)]) == .covered(pinnedFrame))
    }

    @Test func distantWindowsMenusOwnMirrorAndTouchingEdgesDoNotCount() {
        #expect(state([
            window(2, pid: 20, CGRect(x: 800, y: 100, width: 300, height: 300)),
            window(3, pid: 20, CGRect(x: 120, y: 120, width: 200, height: 200), layer: 101),
            window(4, pid: 99, pinnedFrame),
            window(5, pid: 20, CGRect(x: 500, y: 100, width: 200, height: 300)),
            window(1, pid: 10, pinnedFrame)
        ]) == .exposed(pinnedFrame))
    }

    @Test func missingWindowIsHidden() {
        #expect(state([window(2, pid: 20, pinnedFrame)]) == .hidden)
    }

    @Test func stageManagerThumbnailKeepsTheLastFullFrame() {
        let thumbnail = CGRect(x: 16, y: 352, width: 155, height: 151)
        let windows = [window(9, pid: 50, thumbnail), window(1, pid: 10, thumbnail)]
        #expect(state(windows, last: pinnedFrame) == .covered(pinnedFrame))
        #expect(state(windows) == .hidden)
    }
}
