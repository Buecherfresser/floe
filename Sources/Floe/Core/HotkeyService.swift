import CoreGraphics
import Foundation

/// Intercepts global keyboard events via CGEventTap, matches them against
/// registered hotkey bindings, and fires actions. Matched hotkeys are consumed
/// (not passed through to other applications).
final class HotkeyService: @unchecked Sendable {
    typealias ActionHandler = @Sendable (Action) -> Void

    private let handler: ActionHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private let lock = NSLock()
    private(set) var isRunning = false

    /// Key: (keyCode, modifierFlags) -> Action. Updated atomically via lock.
    private var bindingMap: [BindingKey: Action] = [:]

    init(handler: @escaping ActionHandler) {
        self.handler = handler
    }

    // MARK: - Binding Management

    func updateBindings(_ bindings: [HotkeyBinding]) {
        var newMap: [BindingKey: Action] = [:]

        for binding in bindings {
            guard let keyCode = binding.hotkey.keyCode else {
                Log.error("Hotkeys: unknown key \"\(binding.hotkey.key)\" in binding, skipping")
                continue
            }
            let flags = Modifier.flags(from: binding.hotkey.modifiers)
            let key = BindingKey(keyCode: keyCode, flags: flags)
            newMap[key] = binding.action
        }

        lock.withLock { bindingMap = newMap }
        Log.info("Hotkeys: updated \(newMap.count) binding(s)")
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let thread = Thread { [weak self] in
            self?.runEventTap()
        }
        thread.name = "com.jonasdrechsel.floe.hotkeys"
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
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        tapThread?.cancel()
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        isRunning = false
    }

    // MARK: - Event Tap

    private func runEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: userInfo
        ) else {
            Log.error("Hotkeys: failed to create CGEventTap — is accessibility permission granted?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.tapRunLoop = runLoop

        Log.info("Hotkeys: event tap created and running")
        CFRunLoopRun()
    }

    // MARK: - Event Matching

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("Hotkeys: tap was disabled (type=\(type.rawValue)), re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return event
        }

        guard type == .keyDown || type == .keyUp else { return event }

        // Pass through synthetic events posted by SpacesService
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticEventTag {
            return event
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = event.flags
        let modFlags = rawFlags.intersection(Modifier.relevantMask)

        let key = BindingKey(keyCode: keyCode, flags: modFlags)
        let action: Action? = lock.withLock { bindingMap[key] }

        guard let action else { return event }

        // Only dispatch on keyDown to avoid double-firing
        if type == .keyDown {
            Log.debug("Hotkeys: matched keyCode=\(keyCode) flags=\(modFlags.rawValue) -> \(action)")
            let handler = self.handler
            DispatchQueue.global(qos: .userInteractive).async {
                handler(action)
            }
        }

        // Return nil to consume the event for both keyDown and keyUp
        return nil
    }
}

// MARK: - Internal Types

private struct BindingKey: Hashable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(flags.rawValue)
    }

    static func == (lhs: BindingKey, rhs: BindingKey) -> Bool {
        return lhs.keyCode == rhs.keyCode && lhs.flags == rhs.flags
    }
}

// MARK: - C Callback

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if let resultEvent = service.handleEvent(type: type, event: event) {
        return Unmanaged.passRetained(resultEvent)
    }

    // nil = event consumed
    return nil
}
