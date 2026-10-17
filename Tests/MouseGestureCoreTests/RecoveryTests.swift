import CoreGraphics
import Testing
@testable import MouseGestureCore

struct RecoveryTests {
    @Test func missingWindowRequiresStableOriginalApplication() {
        #expect(!ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 11,
            capturedWindowMatches: nil, recoveredWindowStable: true))
        #expect(!ClipboardFocusPolicy.canSend(originalPID: -1, currentPID: -1,
            capturedWindowMatches: true, recoveredWindowStable: true))
        #expect(!ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: nil, recoveredWindowStable: false))
        #expect(ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: nil, recoveredWindowStable: true))
        #expect(!ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: false, recoveredWindowStable: true))
        #expect(ClipboardFocusPolicy.canSend(originalPID: 10, currentPID: 10,
            capturedWindowMatches: true, recoveredWindowStable: false))
    }
}
