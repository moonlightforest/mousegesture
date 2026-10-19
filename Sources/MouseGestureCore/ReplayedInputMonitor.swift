import Foundation

/// Notices when right presses from a remote-input source (Deskflow) keep
/// arriving as replays, which means the other computer's gesture tool is
/// holding the button again. Native mouse input is never counted.
public struct ReplayedInputMonitor: Sendable {
    public enum Change: Equatable, Sendable {
        case warn(notify: Bool)
        case clear
    }

    /// Replays measured 0–25 ms from press to release; real presses 83 ms or more.
    public static let maximumReplayedHold: TimeInterval = 0.025
    static let window: TimeInterval = 120
    static let requiredReplays = 3
    static let notificationInterval: TimeInterval = 1_800

    private var replayTimes: [TimeInterval] = []
    private var notifiedAt: TimeInterval?
    public private(set) var isWarning = false

    public init() {}

    public mutating func record(hold: TimeInterval, remoteSource: Bool, at time: TimeInterval) -> Change? {
        guard remoteSource else { return nil }
        guard hold <= Self.maximumReplayedHold else {
            replayTimes.removeAll()
            guard isWarning else { return nil }
            isWarning = false
            return .clear
        }
        replayTimes.append(time)
        replayTimes.removeAll { time - $0 > Self.window }
        guard !isWarning, replayTimes.count >= Self.requiredReplays else { return nil }
        isWarning = true
        let notify = notifiedAt.map { time - $0 >= Self.notificationInterval } ?? true
        if notify { notifiedAt = time }
        return .warn(notify: notify)
    }
}
