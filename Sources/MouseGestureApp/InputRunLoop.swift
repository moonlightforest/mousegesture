import Foundation
import CoreFoundation

/// Owns the event tap. AppKit and AX never execute on this thread.
final class InputRunLoop {
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var pending: [() -> Void] = []
    private var stopped = false
    private var thread: Thread?

    init() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "MouseGesture.InputListener"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }
    func perform(_ body: @escaping () -> Void) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard let loop else { pending.append(body); lock.unlock(); return }
        lock.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(loop)
    }
    func shutdown() {
        perform { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.stopped = true; self.lock.unlock()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
    private func run() {
        let loop = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        guard let keepAlive = CFRunLoopSourceCreate(nil, 0, &context) else { return }
        CFRunLoopAddSource(loop, keepAlive, .defaultMode)
        lock.lock(); self.loop = loop; let initial = pending; pending.removeAll(); lock.unlock()
        for command in initial { command() }
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
        lock.lock(); self.loop = nil; stopped = true; pending.removeAll(); lock.unlock()
    }
}
