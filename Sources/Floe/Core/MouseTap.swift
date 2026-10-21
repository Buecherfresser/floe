import CoreGraphics
import Foundation

/// Active event tap for left mouse down/drag/up, used by tiling for ⌃-drag
/// resizing and to notice when the user finishes dragging a window. The
/// handler runs on the tap's thread and returns `true` to swallow the event.
final class MouseTap: @unchecked Sendable {
    typealias Handler = @Sendable (CGEventType, CGPoint, CGEventFlags) -> Bool

    fileprivate let handler: Handler
    private let lock = NSLock()
    fileprivate var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var isRunning = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        lock.withLock {
            guard !isRunning else { return }
            isRunning = true
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "com.jonasdrechsel.floe.mousetap"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    func stop() {
        lock.withLock {
            guard isRunning else { return }
            isRunning = false
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let runLoop { CFRunLoopStop(runLoop) }
            tap = nil
            runLoop = nil
        }
    }

    private func run() {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("MouseTap: failed to create event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let shouldRun = lock.withLock { () -> Bool in
            // stop() may have run before the tap existed.
            guard isRunning else { return false }
            self.tap = tap
            self.runLoop = CFRunLoopGetCurrent()
            return true
        }
        guard shouldRun else {
            CFMachPortInvalidate(tap)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    fileprivate func reenable() {
        lock.withLock {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }
}

private func mouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }

    if tap.handler(type, event.location, event.flags) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
