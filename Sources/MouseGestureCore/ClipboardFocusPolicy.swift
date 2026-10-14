public enum ClipboardFocusPolicy {
    public static func canSend(originalPID: Int32, currentPID: Int32?,
                               capturedWindowMatches: Bool?, recoveredWindowStable: Bool) -> Bool {
        guard originalPID > 0, currentPID == originalPID else { return false }
        return capturedWindowMatches ?? recoveredWindowStable
    }
}
