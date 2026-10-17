import Foundation
import CoreGraphics
import Testing
@testable import MouseGestureCore

struct InputLifetimeTests {
    private func ready() -> InputLifetime {
        let lifetime = InputLifetime()
        lifetime.foregroundChanged(to: 10)
        lifetime.configure(enabled: true)
        return lifetime
    }
    @Test func cancellationInvalidatesQueuedClickAXAndAction() {
        let lifetime = ready()
        let first = lifetime.begin()
        #expect(lifetime.isCurrent(first))
        lifetime.invalidate() // Every observed new-input kind uses this operation.
        #expect(!lifetime.isCurrent(first))
        #expect(!lifetime.claim(first))
        let second = lifetime.begin()
        #expect(lifetime.claim(second))
        #expect(!lifetime.claim(second)) // click replay and action are mutually exclusive.
        #expect(!lifetime.claim(first))
    }
    @Test func appChangeAndPauseInvalidateAndSameAppDoesNot() {
        let lifetime = ready()
        let token = lifetime.begin()
        #expect(!lifetime.foregroundChanged(to: 10))
        #expect(lifetime.isCurrent(token))
        lifetime.foregroundChanged(to: 11)
        #expect(!lifetime.claim(token))
        let next = lifetime.begin()
        lifetime.configure(enabled: false)
        #expect(!lifetime.claim(next))
        lifetime.configure(enabled: true)
        #expect(!lifetime.claim(next))
    }
    @Test func faultsCannotBeRecoveredByConfigurationOrActivation() {
        let lifetime = ready()
        let token = lifetime.begin()
        lifetime.fault()
        lifetime.configure(enabled: true)
        lifetime.foregroundChanged(to: 11)
        #expect(!lifetime.claim(token))
        #expect(!lifetime.claim(lifetime.begin()))
        lifetime.recover()
        #expect(lifetime.claim(lifetime.begin()))
    }
    @Test func invalidPIDNeverReceivesAction() {
        let lifetime = ready()
        lifetime.foregroundChanged(to: -1)
        #expect(!lifetime.claim(lifetime.begin()))
    }
    @Test func onlyOneConcurrentActionCanClaim() {
        let lifetime = ready()
        let token = lifetime.begin()
        let lock = NSLock()
        var count = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if lifetime.claim(token) { lock.lock(); count += 1; lock.unlock() }
        }
        #expect(count == 1)
    }
}
