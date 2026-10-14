import CoreGraphics

public enum PostReleaseRightSwipe {
    public static func isRecognized(
        axisPeak: CGPoint,
        moveCount: Int,
        ordinaryThreshold: CGFloat
    ) -> Bool {
        moveCount >= 2
            && GestureClassifier(threshold: ordinaryThreshold)
                .direction(from: .zero, to: axisPeak) == .right
    }
}

/// Uses the same sectors as held gestures; only copy/paste/window-switch
/// actions are eligible for recovery after release.
public enum PostReleaseGesture {
    public static func direction(stroke: GestureStroke, shortStroke: ShortVerticalStroke,
                                 moveCount: Int, threshold: CGFloat) -> GestureDirection? {
        guard moveCount >= 2 else { return nil }
        let direction = stroke.direction(threshold: threshold)
            ?? shortStroke.direction(threshold: threshold)
        return direction == .left ? nil : direction
    }
}
