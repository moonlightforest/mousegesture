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
