import CoreGraphics
import Foundation

/// Observes global mouse-moved events via a CGEventTap running on a dedicated thread.
final class EventTapService: @unchecked Sendable {
    typealias MouseMovedHandler = @Sendable (CGPoint) -> Void

    fileprivate let handler: MouseMovedHandler
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        tapThread?.cancel()
        eventTap = nil
        runLoopSource = nil
        tapThread = nil
        isRunning = false
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source

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
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .mouseMoved else {
        return Unmanaged.passRetained(event)
    }

    let location = event.location
    service.handler(location)

    return Unmanaged.passRetained(event)
}
