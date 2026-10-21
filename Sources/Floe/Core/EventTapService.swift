import CoreGraphics
import Foundation

/// Observes global mouse-moved events via a CGEventTap running on a dedicated thread.
final class EventTapService: @unchecked Sendable {
    typealias MouseMovedHandler = @Sendable (CGPoint) -> Void

    fileprivate let handler: MouseMovedHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private let lock = NSLock()

    private(set) var isRunning = false

    init(handler: @escaping MouseMovedHandler) {
        self.handler = handler
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let thread = Thread { [weak self] in
            self?.runEventTap()
        }
        thread.name = "com.jonasdrechsel.floe.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        isRunning = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
        }
        tapThread?.cancel()
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        isRunning = false
    }

    fileprivate func reenable() {
        lock.withLock {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        }
    }

    private func runEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            Log.error("EventTap: failed to create CGEventTap — is accessibility permission granted?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // stop() may have run before the tap existed.
        let stillRunning = lock.withLock { () -> Bool in
            guard isRunning else { return false }
            self.eventTap = tap
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            return true
        }
        guard stillRunning else {
            CFMachPortInvalidate(tap)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.info("EventTap: created and running on thread \(Thread.current.name ?? "?")")
        CFRunLoopRun()
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let service = Unmanaged<EventTapService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Log.info("EventTap: tap was disabled (type=\(type.rawValue)), re-enabling")
        service.reenable()
        return Unmanaged.passRetained(event)
    }

    guard type == .mouseMoved else {
        return Unmanaged.passRetained(event)
    }

    let location = event.location
    service.handler(location)

    return Unmanaged.passRetained(event)
}
