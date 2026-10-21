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

    /// While Settings records a new hotkey, every key goes to Settings.
    nonisolated(unsafe) private static var suspended = false
    private static let suspendLock = NSLock()

    static func setSuspended(_ value: Bool) {
        suspendLock.withLock { suspended = value }
    }

    private static var isSuspended: Bool {
        suspendLock.withLock { suspended }
    }

    /// Arrows, F1–F20, Home/End/Page Up/Page Down, Help, Forward Delete.
    static let implicitFnKeyCodes: Set<CGKeyCode> = [
        123, 124, 125, 126,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        115, 119, 116, 121, 114, 117,
    ]

    private let lock = NSLock()
    private let dispatchQueue = DispatchQueue(label: "com.jonasdrechsel.floe.hotkey-actions", qos: .userInteractive)
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
            CFMachPortInvalidate(tap)
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

        // stop() may have run before the tap existed — then don't leave a tap
        // behind that nobody can stop.
        let stillRunning = lock.withLock { () -> Bool in
            guard isRunning else { return false }
            self.eventTap = tap
            self.runLoopSource = source
            self.tapRunLoop = runLoop
            return true
        }
        guard stillRunning else {
            CFMachPortInvalidate(tap)
            return
        }

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.info("Hotkeys: event tap created and running")
        CFRunLoopRun()
    }

    // MARK: - Event Matching

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("Hotkeys: tap was disabled (type=\(type.rawValue)), re-enabling")
            if let tap = lock.withLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return event
        }

        guard type == .keyDown || type == .keyUp else { return event }
        guard !Self.isSuspended else { return event }

        // Pass through synthetic events posted by SpacesService
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticEventTag {
            return event
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = event.flags
        var modFlags = rawFlags.intersection(Modifier.relevantMask)
        // Arrow, F- and navigation keys always report the fn flag on Mac
        // keyboards; only treat fn as a modifier for other keys.
        if Self.implicitFnKeyCodes.contains(keyCode) {
            modFlags.remove(.maskSecondaryFn)
        }

        let key = BindingKey(keyCode: keyCode, flags: modFlags)
        let action: Action? = lock.withLock { bindingMap[key] }

        // macOS reserves some fn+letter combos (fn+C Control Center, …); log
        // what actually arrives so missing shortcuts can be diagnosed.
        if type == .keyDown, modFlags.contains(.maskSecondaryFn) {
            Log.info("Hotkeys: fn keyDown keyCode=\(keyCode) key=\(KeyCode.name(for: keyCode) ?? "?") flags=0x\(String(modFlags.rawValue, radix: 16)) matched=\(action != nil)")
        }

        guard let action else { return event }

        // Only dispatch on the initial keyDown — not keyUp or autorepeat —
        // and in order, so quick successive hotkeys don't race.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown && !isRepeat {
            Log.debug("Hotkeys: matched keyCode=\(keyCode) flags=\(modFlags.rawValue) -> \(action)")
            let handler = self.handler
            dispatchQueue.async {
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
