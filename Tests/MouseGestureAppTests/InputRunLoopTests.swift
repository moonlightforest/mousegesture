import Foundation
import Testing
@testable import MouseGestureApp

struct InputRunLoopTests {
    @MainActor @Test func listenerRunsWhileMainActorIsBlocked() {
        // Only exercise the worker; never install a tap or inject user input.
        let worker = InputRunLoop()
        let completed = DispatchSemaphore(value: 0)
        worker.perform {
            #expect(!Thread.isMainThread)
            #expect(Thread.current.name == "MouseGesture.InputListener")
            completed.signal()
        }
        // A worker bound to the main run loop would time out here.
        #expect(completed.wait(timeout: .now() + 1) == .success)
        worker.shutdown()
    }
    @Test func commandsAreSerializedAcrossBootstrap() {
        let worker = InputRunLoop()
        let completed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var values: [Int] = []
        for value in 0..<30 {
            worker.perform { lock.lock(); values.append(value); lock.unlock() }
        }
        worker.perform { completed.signal() }
        #expect(completed.wait(timeout: .now() + 1) == .success)
        lock.lock(); let actual = values; lock.unlock()
        #expect(actual == Array(0..<30))
        worker.shutdown()
    }
}
