import Foundation
import CoreGraphics

public struct InputToken: Equatable, Sendable {
    public let generation: UInt64
    public let applicationPID: Int32
}

/// Shared by the listener and action queues. No system APIs run under this lock.
public final class InputLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pid: Int32 = -1
    private var enabled = false
    private var faulted = false
    private var claimed = false

    public init() {}
    public func configure(enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if self.enabled != enabled { advance() }
        self.enabled = enabled
    }
    @discardableResult
    public func foregroundChanged(to pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.pid != pid else { return false }
        advance(); self.pid = pid
        return true
    }
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }; advance()
    }
    public func begin() -> InputToken {
        lock.lock(); defer { lock.unlock() }; advance()
        return InputToken(generation: generation, applicationPID: pid)
    }
    public func isCurrent(_ token: InputToken) -> Bool {
        lock.lock(); defer { lock.unlock() }; return matches(token)
    }
    public func claim(_ token: InputToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard matches(token), !claimed else { return false }
        claimed = true
        return true
    }
    public func fault() {
        lock.lock(); defer { lock.unlock() }; advance(); faulted = true
    }
    public func recover() {
        lock.lock(); defer { lock.unlock() }; advance(); faulted = false
    }
    private func advance() { generation &+= 1; claimed = false }
    private func matches(_ token: InputToken) -> Bool {
        enabled && !faulted && token.generation == generation && token.applicationPID == pid && pid > 0
    }
}
