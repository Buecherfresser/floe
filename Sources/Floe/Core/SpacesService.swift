@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// Magic value set on synthetic keyboard events so our HotkeyService
/// knows to pass them through instead of consuming them.
let kSyntheticEventTag: Int64 = 0x574D_5350 // "WMSP"

/// How long to wait for a space switch to become visible before giving up
/// on the gesture and falling back to the keyboard shortcut.
private let kSpaceSwitchTimeout: TimeInterval = 0.3
private let kSpaceSwitchPollInterval: useconds_t = 5_000 // 5 ms

// MARK: - Dock Swipe Gesture Fields
//
// Undocumented CGEvent fields used to synthesize a Dock swipe (the
// four-finger "switch space" trackpad gesture). Posting a Began/Ended pair
// with a huge velocity switches one space with no animation.
//
// Attribution: technique from BetterTouchTool, documented by
// https://github.com/jurplel/InstantSpaceSwitcher and used by yabai.

private let kCGSEventTypeField = CGEventField(rawValue: 55)!
private let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
private let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
private let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
private let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
private let kCGEventGesturePhase = CGEventField(rawValue: 132)!

private let kCGSEventDockControl: Int64 = 30
private let kIOHIDEventTypeDockSwipe: Int64 = 23
private let kCGGestureMotionHorizontal: Int64 = 1
private let kCGSGesturePhaseBegan: Int64 = 1
private let kCGSGesturePhaseEnded: Int64 = 4

// MARK: - SpacesService

/// Provides space switching and window-to-space movement.
///
/// Space switching synthesizes high-velocity Dock swipe gestures (instant,
/// no Mission Control shortcuts needed), falling back to Ctrl+N.
/// Window movement uses SkyLight's bridged `MoveWindowsToManagedSpace`
/// operation, which the Dock executes on our behalf — no SIP changes or
/// Dock injection required.
final class SpacesService: @unchecked Sendable {

    private let accessibilityService: AccessibilityService

    /// Serializes space operations so rapid hotkey presses don't interleave.
    private let queue = DispatchQueue(label: "com.jonasdrechsel.floe.spaces", qos: .userInteractive)

    init(accessibilityService: AccessibilityService) {
        self.accessibilityService = accessibilityService
    }

    // MARK: - Space Switching

    /// Switches to "Desktop N" (1-based, counted across displays).
    func focusSpace(at index: Int) {
        queue.async { [self] in
            guard let target = CGSSpaceService.spaceID(forIndex: index) else {
                Log.error("Spaces: focusSpace — no desktop \(index)")
                return
            }
            Log.info("Spaces: switching to desktop \(index) (space \(target))")
            focus(space: target)
        }
    }

    /// Switches to the next space on the focused display (like Ctrl+Right).
    func focusNextSpace() {
        queue.async { [self] in focusAdjacentSpace(offset: 1) }
    }

    /// Switches to the previous space on the focused display (like Ctrl+Left).
    func focusPreviousSpace() {
        queue.async { [self] in focusAdjacentSpace(offset: -1) }
    }

    private func focusAdjacentSpace(offset: Int) {
        let current = spaceUnderCursor()
        // Mission Control order, including fullscreen spaces — same as Ctrl+Arrow.
        guard let display = CGSSpaceService.display(containing: current),
              let idx = display.missionControlIndex(of: current),
              display.spaces.indices.contains(idx + offset) else {
            Log.info("Spaces: no space at offset \(offset) from \(current)")
            return
        }
        let target = display.spaces[idx + offset].id
        Log.info("Spaces: switching by \(offset) to space \(target)")
        focus(space: target)
    }

    /// Makes `target` the visible space on its display. Blocks until the
    /// switch is observable (or times out). Must run on `queue`.
    @discardableResult
    private func focus(space target: CGSSpaceID) -> Bool {
        guard let display = CGSSpaceService.display(containing: target),
              let fromIndex = display.missionControlIndex(of: display.currentSpace),
              let toIndex = display.missionControlIndex(of: target) else {
            Log.error("Spaces: space \(target) not found on any display")
            return focusViaKeyboard(space: target)
        }

        let delta = toIndex - fromIndex
        // macOS restores focus itself when switching on the focused display;
        // only a switch on the other display needs Floe to move focus.
        let focusedDisplay = CGSSpaceService.display(containing: CGSSpaceService.currentSpaceID())?.identifier
        let isOtherDisplay = focusedDisplay != display.identifier
        if delta == 0 {
            // Already visible — but possibly on the display without focus.
            // Already visible: bring the cursor and keyboard focus there —
            // you may be looking at (and focused on) the other display.
            moveCursor(toDisplay: display.identifier)
            if isOtherDisplay {
                Log.info("Spaces: space \(target) already visible, moving focus to its display")
                takeKeyboardFocus(space: target)
            } else if let focused = focusedWindow(), !CGSSpaceService.spaces(forWindow: focused.id).contains(target) {
                focusFrontmostWindow(onSpace: target)
            }
            return true
        }

        moveCursor(toDisplay: display.identifier)
        FocusFollowsMouse.suppress(for: .milliseconds(700))
        postDockSwipes(count: abs(delta), direction: delta > 0 ? 1 : -1)

        if waitForCurrentSpace(target, on: display.identifier) {
            if isOtherDisplay { takeKeyboardFocus(space: target) }
            return true
        }

        Log.info("Spaces: gesture switch to \(target) not observed, falling back to keyboard")
        return focusViaKeyboard(space: target)
    }

    private func postDockSwipes(count: Int, direction: Double) {
        guard let event = CGEvent(source: nil) else {
            Log.error("Spaces: failed to create dock swipe event")
            return
        }
        event.setIntegerValueField(kCGSEventTypeField, value: kCGSEventDockControl)
        event.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        event.setIntegerValueField(kCGEventGestureSwipeMotion, value: kCGGestureMotionHorizontal)
        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: direction)
        event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: direction * 9999)

        for _ in 0..<count {
            event.setIntegerValueField(kCGEventGesturePhase, value: kCGSGesturePhaseBegan)
            event.post(tap: .cgSessionEventTap)
            event.setIntegerValueField(kCGEventGesturePhase, value: kCGSGesturePhaseEnded)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func waitForCurrentSpace(_ target: CGSSpaceID, on displayIdentifier: String) -> Bool {
        let deadline = Date().addingTimeInterval(kSpaceSwitchTimeout)
        while Date() < deadline {
            let current = CGSSpaceService.displays().first { $0.identifier == displayIdentifier }?.currentSpace
            if current == target { return true }
            usleep(kSpaceSwitchPollInterval)
        }
        return false
    }

    /// Ctrl+N fallback. Only desktops 1–10 have a shortcut, and the shortcuts
    /// must be enabled in System Settings › Keyboard › Keyboard Shortcuts.
    private func focusViaKeyboard(space target: CGSSpaceID) -> Bool {
        guard let index = CGSSpaceService.userSpaceIDs().firstIndex(of: target).map({ $0 + 1 }),
              index <= 10,
              let keyCode = KeyCode.from(index == 10 ? "0" : "\(index)") else {
            Log.error("Spaces: no keyboard shortcut for space \(target)")
            return false
        }
        Log.info("Spaces: switching to desktop \(index) via Ctrl+\(index % 10)")
        postSyntheticKey(keyCode: keyCode, flags: .maskControl)
        return true
    }

    /// Switching a display's space doesn't move keyboard focus to that display.
    /// Focus the desktop's frontmost window. Right after a switch the window
    /// list may not show the new desktop's windows yet, so give it a moment.
    /// An empty desktop keeps the old focus: activating another app (Finder)
    /// would make macOS jump to wherever that app has a window.
    private func takeKeyboardFocus(space target: CGSSpaceID) {
        let deadline = Date().addingTimeInterval(0.2)
        repeat {
            if focusFrontmostWindow(onSpace: target) { return }
            usleep(25_000)
        } while Date() < deadline
        Log.info("Spaces: no window to focus on space \(target)")
    }

    /// Mouse follows focus: after jumping to a window, put the cursor into it
    /// (unless it's already there) — otherwise you're still looking at the
    /// old spot, and focus-follows-mouse hands focus back on the next move.
    private func moveCursor(into window: FocusedWindow) {
        guard let frame = accessibilityService.windowFrame(of: window.element) else { return }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard !frame.contains(cursor) else { return }
        FocusFollowsMouse.ignoreCurrentHover()
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The Dock applies swipes to the display under the cursor, so move the
    /// cursor there first when targeting another display.
    private func moveCursor(toDisplay identifier: String) {
        guard identifier != "Main", let monitor = Monitors.monitor(withUUID: identifier) else { return }

        let cursor = CGEvent(source: nil)?.location ?? .zero
        guard !monitor.bounds.contains(cursor) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: monitor.bounds.midX, y: monitor.bounds.midY))
    }

    // MARK: - Window Movement

    /// Moves the focused window to "Desktop N" and follows it there.
    func moveWindowToSpace(at index: Int, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard let target = CGSSpaceService.spaceID(forIndex: index) else {
                Log.error("Spaces: moveWindowToSpace — no desktop \(index)")
                return
            }
            moveFocusedWindow(to: target, follow: true)
            completion?()
        }
    }

    /// Moves the focused window to the next desktop on its display and follows it.
    func moveWindowToNextSpace(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            moveFocusedWindowToAdjacentSpace(offset: 1, follow: true)
            completion?()
        }
    }

    /// Moves the focused window to the previous desktop on its display and follows it.
    func moveWindowToPreviousSpace(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            moveFocusedWindowToAdjacentSpace(offset: -1, follow: true)
            completion?()
        }
    }

    /// Moves the focused window to "Desktop N" while staying on the current space.
    func moveWindowToSpaceAndReturn(at index: Int, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard let target = CGSSpaceService.spaceID(forIndex: index) else {
                Log.error("Spaces: moveWindowToSpaceAndReturn — no desktop \(index)")
                return
            }
            moveFocusedWindow(to: target, follow: false)
            completion?()
        }
    }

    /// Moves the focused window to the next desktop while staying on the current space.
    func moveWindowToNextSpaceAndReturn(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            moveFocusedWindowToAdjacentSpace(offset: 1, follow: false)
            completion?()
        }
    }

    /// Moves the focused window to the previous desktop while staying on the current space.
    func moveWindowToPreviousSpaceAndReturn(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            moveFocusedWindowToAdjacentSpace(offset: -1, follow: false)
            completion?()
        }
    }

    private func moveFocusedWindowToAdjacentSpace(offset: Int, follow: Bool) {
        guard let window = focusedWindow() else {
            Log.error("Spaces: no focused window to move")
            return
        }
        let current = CGSSpaceService.spaces(forWindow: window.id).first ?? CGSSpaceService.currentSpaceID()
        guard let target = CGSSpaceService.adjacentUserSpace(to: current, offset: offset) else {
            Log.info("Spaces: no desktop at offset \(offset) from space \(current)")
            return
        }
        moveWindow(window, to: target, follow: follow)
    }

    private func moveFocusedWindow(to target: CGSSpaceID, follow: Bool) {
        guard let window = focusedWindow() else {
            Log.error("Spaces: no focused window to move")
            return
        }
        moveWindow(window, to: target, follow: follow)
    }

    private func moveWindow(_ window: FocusedWindow, to target: CGSSpaceID, follow: Bool) {
        guard CGSSpaceService.canMoveWindows else {
            Log.error("Spaces: moving windows between spaces is not supported on this macOS version")
            return
        }

        Log.info("Spaces: moving window \(window.id) (pid \(window.pid)) to space \(target), follow=\(follow)")
        // The bridged move keeps the window's frame. For a desktop on another
        // display, put the window onto that display first — while it's still
        // reachable through Accessibility — or it stays visible where it was.
        let source = CGSSpaceService.spaces(forWindow: window.id).first
        let sourceDisplay = source.flatMap { CGSSpaceService.display(containing: $0)?.identifier }
        if let targetDisplay = CGSSpaceService.display(containing: target)?.identifier, targetDisplay != sourceDisplay {
            moveOntoDisplay(of: target, window: window)
        }
        guard CGSSpaceService.moveWindow(window.id, toSpace: target) else { return }

        if follow {
            focus(space: target)
            focusWindow(window)
        } else {
            // The window was focused, so its display's space is the active one.
            focusFrontmostWindow(onSpace: CGSSpaceService.currentSpaceID(), excluding: window.id)
        }
    }

    // MARK: - App Switching

    /// Brings the app's most recent window to front, switching to its space,
    /// or launches the app if it isn't running.
    func focusApp(bundleID: String, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  let windowID = mostRecentWindowID(of: app) else {
                launch(bundleID: bundleID)
                return
            }

            let visibleSpaces = Set(CGSSpaceService.displays().map(\.currentSpace))
            if let space = CGSSpaceService.spaces(forWindow: windowID).first, !visibleSpaces.contains(space) {
                Log.info("Spaces: focusing \(bundleID) window \(windowID) on space \(space)")
                focus(space: space)
            } else {
                Log.info("Spaces: focusing \(bundleID) window \(windowID) (already visible)")
            }
            if let window = focusWindow(id: windowID, of: app) {
                moveCursor(into: window)
            }
        }
    }

    /// Moves the app's most recent window onto the current space (and display)
    /// and focuses it, or launches the app if it isn't running.
    func pullApp(bundleID: String, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            defer { completion?() }
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  let windowID = mostRecentWindowID(of: app) else {
                launch(bundleID: bundleID)
                return
            }

            let current = spaceUnderCursor()
            if !CGSSpaceService.spaces(forWindow: windowID).contains(current) {
                Log.info("Spaces: pulling \(bundleID) window \(windowID) to space \(current)")
                guard CGSSpaceService.moveWindow(windowID, toSpace: current) else { return }
            }
            guard let window = focusWindow(id: windowID, of: app) else { return }
            moveOntoDisplay(of: current, window: window)
            moveCursor(into: window)
        }
    }

    /// Activates the app and raises the window. Accessibility only exposes
    /// windows on visible spaces, so wait briefly for the element to appear
    /// after a space switch or move.
    @discardableResult
    private func focusWindow(id windowID: CGWindowID, of app: NSRunningApplication) -> FocusedWindow? {
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            if let element = axWindow(id: windowID, pid: app.processIdentifier) {
                let window = FocusedWindow(id: windowID, pid: app.processIdentifier, element: element)
                focusWindow(window)
                return window
            }
            usleep(20_000)
        } while Date() < deadline

        Log.info("Spaces: window \(windowID) not accessible, activating app only")
        app.activate()
        return nil
    }

    private func axWindow(id windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first { accessibilityService.windowID(of: $0) == windowID }
    }

    private func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Log.error("Spaces: no application with bundle id \(bundleID)")
            return
        }
        Log.info("Spaces: launching \(bundleID)")
        // For a running app this sends a reopen event, which most apps answer
        // by opening a new window.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The app's frontmost normal window on any desktop. CGWindowList is
    /// ordered front-to-back and, unlike Accessibility, includes windows on
    /// other spaces.
    private func mostRecentWindowID(of app: NSRunningApplication) -> CGWindowID? {
        let pid = app.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }
        let userSpaces = Set(CGSSpaceService.userSpaceIDs())
        for info in infoList {
            guard (info[kCGWindowOwnerPID] as? pid_t) == pid,
                  (info[kCGWindowLayer] as? Int) == 0,
                  (info[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50,
                  let windowID = info[kCGWindowNumber] as? CGWindowID else { continue }
            // Helper and off-screen buffer windows aren't on any desktop.
            if CGSSpaceService.spaces(forWindow: windowID).contains(where: userSpaces.contains) {
                return windowID
            }
        }
        return nil
    }

    /// After moving a window to a space on another display, its frame still
    /// lies on the old display — place it on the target display.
    private func moveOntoDisplay(of space: CGSSpaceID, window: FocusedWindow) {
        guard let display = CGSSpaceService.display(containing: space),
              let monitor = Monitors.monitor(withUUID: display.identifier) ?? Monitors.ordered().first(where: \.isMain),
              let frame = accessibilityService.windowFrame(of: window.element),
              !monitor.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }

        let size = CGSize(width: min(frame.width, monitor.bounds.width), height: min(frame.height, monitor.bounds.height))
        let origin = CGPoint(x: monitor.bounds.midX - size.width / 2, y: monitor.bounds.midY - size.height / 2)
        accessibilityService.setWindowFrame(element: window.element, frame: CGRect(origin: origin, size: size))
    }

    // MARK: - Focus Helpers

    /// The visible space of the display under the cursor — where the user is
    /// looking. Can differ from the keyboard-focused display when the cursor
    /// rests on an empty desktop.
    private func spaceUnderCursor() -> CGSSpaceID {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        if let monitor = Monitors.ordered().first(where: { $0.bounds.contains(cursor) }),
           let display = CGSSpaceService.displays().first(where: { $0.identifier.caseInsensitiveCompare(monitor.uuid) == .orderedSame }) {
            return display.currentSpace
        }
        return CGSSpaceService.currentSpaceID()
    }

    private struct FocusedWindow {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
    }

    private func focusedWindow() -> FocusedWindow? {
        guard let pid = accessibilityService.focusedAppPID() else { return nil }

        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }

        let element = windowRef as! AXUIElement
        guard let windowID = accessibilityService.windowID(of: element) else { return nil }

        return FocusedWindow(id: windowID, pid: pid, element: element)
    }

    private func focusWindow(_ window: FocusedWindow) {
        FocusFollowsMouse.ignoreCurrentHover()
        accessibilityService.focusApp(pid: window.pid)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    /// Focuses the frontmost window on `space` — e.g. after a window left it,
    /// so keyboard input doesn't go to an invisible window.
    @discardableResult
    private func focusFrontmostWindow(onSpace space: CGSSpaceID, excluding excludedID: CGWindowID = 0) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else { return false }

        // CGWindowList is ordered front-to-back.
        for info in infoList {
            guard let layer = info[kCGWindowLayer] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber] as? CGWindowID, windowID != excludedID,
                  let pid = info[kCGWindowOwnerPID] as? pid_t, pid != ownPID,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  CGSSpaceService.spaces(forWindow: windowID).contains(space) else { continue }

            let origin = CGPoint(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0)
            Log.info("Spaces: focusing window \(windowID) (pid \(pid)) on space \(space)")
            FocusFollowsMouse.ignoreCurrentHover()
            accessibilityService.focusApp(pid: pid)
            accessibilityService.raiseWindow(pid: pid, targetOrigin: origin)
            return true
        }
        return false
    }

    // MARK: - Synthetic Keyboard Events

    /// Posts a tagged key-down + key-up pair so our HotkeyService passes
    /// it through.  Used for the space-focus keyboard fallback.
    private func postSyntheticKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        postSyntheticKeyEvent(keyCode: keyCode, flags: flags, keyDown: true)
        postSyntheticKeyEvent(keyCode: keyCode, flags: flags, keyDown: false)
    }

    private func postSyntheticKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            Log.error("Spaces: failed to create key CGEvent for keycode \(keyCode)")
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventTag)
        event.post(tap: .cghidEventTap)
    }
}
