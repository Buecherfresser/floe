import AppKit
import CoreGraphics
import Foundation

/// Magic value set on synthetic keyboard events so our HotkeyService
/// knows to pass them through instead of consuming them.
let kSyntheticEventTag: Int64 = 0x574D_5350 // "WMSP"

/// Delay after mouse-down before starting the drag (µs).
/// Just enough for the event to register — the window server processes
/// events in well under 1 ms, but we give it a small buffer.
private let kMouseDownSettleDelay: useconds_t = 5_000 // 5 ms

/// Delay after the drag movement before posting the space-switch key (µs).
private let kDragSettleDelay: useconds_t = 20_000 // 20 ms

/// Delay between posting key-down and key-up for the space switch (µs).
private let kKeyHoldDelay: useconds_t = 20_000 // 20 ms

/// Delay after key-up before releasing the mouse (µs).
/// With "Reduce motion" or animations disabled this can be very short;
/// the window server just needs a moment to commit the space change.
private let kSpaceAnimationDelay: useconds_t = 50_000 // 50 ms

/// Vertical offset from window origin to approximate the title bar centre.
private let kTitleBarOffset: CGFloat = 12

/// Pixels to nudge the mouse during the drag to initiate a window grab.
private let kDragNudge: CGFloat = 1

// MARK: - SpacesService

/// Provides space switching and window-to-space movement.
///
/// Space switching uses simulated Mission Control keyboard shortcuts (Ctrl+N)
/// or CGS private APIs when SIP is disabled.
/// Window movement uses mouse-drag simulation by default, or CGS private APIs
/// when available and configured.
final class SpacesService: @unchecked Sendable {

    var moveMethod: SpaceMoveMethod = .mouseDrag

    /// Detected SIP status, set by ``verifyCGSAvailability()``.
    private(set) var sipStatus: SIPStatus = .unknown

    /// Set to `true` after ``verifyCGSAvailability()`` confirms the CGS
    /// private APIs are actually functional (not silently neutered).
    private(set) var cgsVerified = false

    /// Checks SIP status and runs a CGS smoke test.  Should be called once
    /// at startup.  The result is cached in ``sipStatus`` and ``cgsVerified``.
    func verifyCGSAvailability() {
        sipStatus = querySIPStatus()
        Log.info("Spaces: SIP status = \(sipStatus)")

        guard sipStatus == .disabled else {
            Log.info("Spaces: SIP is not disabled — CGS path unavailable")
            cgsVerified = false
            return
        }

        guard CGSSpaceService.isAvailable else {
            Log.info("Spaces: CGS symbols not loaded")
            cgsVerified = false
            return
        }

        cgsVerified = CGSSpaceService.verifyFunctional()
        Log.info("Spaces: CGS verification \(cgsVerified ? "passed" : "failed")")
    }

    /// Whether to use the CGS path for the current operation, given the
    /// configured ``moveMethod``.
    private var useCGS: Bool {
        switch moveMethod {
        case .cgsPrivateAPI: return cgsVerified
        case .auto:          return cgsVerified
        case .mouseDrag:     return false
        }
    }

    // MARK: - Space Switching
    //
    // Always uses keyboard simulation.  CGSManagedDisplaySetCurrentSpace
    // only composites windows without updating the Dock's internal state
    // (which requires code injection, as yabai does via its scripting
    // addition).  Keyboard simulation is reliable and fast.

    /// Switches to the space at the given 1-based index by simulating
    /// the Mission Control shortcut Ctrl+Number.
    func focusSpace(at index: Int) {
        guard index >= 1, index <= 10 else {
            Log.error("Spaces: focusSpace index \(index) out of range 1-10")
            return
        }

        let digit = index == 10 ? "0" : "\(index)"
        guard let keyCode = KeyCode.from(digit) else {
            Log.error("Spaces: no keycode for \"\(digit)\"")
            return
        }

        Log.info("Spaces: switching to space \(index) via Ctrl+\(digit)")
        postSyntheticKey(keyCode: keyCode, flags: .maskControl)
    }

    /// Switches to the next space (Ctrl+Right).
    func focusNextSpace() {
        guard let keyCode = KeyCode.from("right") else { return }
        Log.info("Spaces: switching to next space via Ctrl+Right")
        postSyntheticKey(keyCode: keyCode, flags: .maskControl)
    }

    /// Switches to the previous space (Ctrl+Left).
    func focusPreviousSpace() {
        guard let keyCode = KeyCode.from("left") else { return }
        Log.info("Spaces: switching to previous space via Ctrl+Left")
        postSyntheticKey(keyCode: keyCode, flags: .maskControl)
    }

    // MARK: - Window Movement

    /// Moves the focused window to the space at the given 1-based index.
    func moveWindowToSpace(at index: Int) {
        guard index >= 1, index <= 10 else {
            Log.error("Spaces: moveWindowToSpace index \(index) out of range 1-10")
            return
        }

        if useCGS, let wid = focusedWindowID() {
            Log.info("Spaces: moving window \(wid) to space \(index) via CGS")
            CGSSpaceService.moveWindow(wid, toSpaceAt: index)
            return
        }

        let digit = index == 10 ? "0" : "\(index)"
        guard let keyCode = KeyCode.from(digit) else {
            Log.error("Spaces: moveWindowToSpace — no keycode for \"\(digit)\"")
            return
        }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToSpace — could not determine focused window frame")
            return
        }

        Log.info("Spaces: moving focused window to space \(index) via mouse-drag + Ctrl+\(digit)")
        performMouseDragSpaceSwitch(windowFrame: frame, keyCode: keyCode, flags: .maskControl)
    }

    /// Moves the focused window to the next space.
    func moveWindowToNextSpace() {
        if useCGS, let wid = focusedWindowID(), let current = CGSSpaceService.currentSpaceIndex() {
            let spaces = CGSSpaceService.userSpaceIDs()
            let next = current < spaces.count ? current + 1 : 1
            Log.info("Spaces: moving window \(wid) to next space (\(next)) via CGS")
            CGSSpaceService.moveWindow(wid, toSpaceAt: next)
            return
        }

        guard let keyCode = KeyCode.from("right") else { return }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToNextSpace — could not determine focused window frame")
            return
        }
        Log.info("Spaces: moving focused window to next space via mouse-drag + Ctrl+Right")
        performMouseDragSpaceSwitch(windowFrame: frame, keyCode: keyCode, flags: .maskControl)
    }

    /// Moves the focused window to the previous space.
    func moveWindowToPreviousSpace() {
        if useCGS, let wid = focusedWindowID(), let current = CGSSpaceService.currentSpaceIndex() {
            let spaces = CGSSpaceService.userSpaceIDs()
            let prev = current > 1 ? current - 1 : spaces.count
            Log.info("Spaces: moving window \(wid) to previous space (\(prev)) via CGS")
            CGSSpaceService.moveWindow(wid, toSpaceAt: prev)
            return
        }

        guard let keyCode = KeyCode.from("left") else { return }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToPreviousSpace — could not determine focused window frame")
            return
        }
        Log.info("Spaces: moving focused window to previous space via mouse-drag + Ctrl+Left")
        performMouseDragSpaceSwitch(windowFrame: frame, keyCode: keyCode, flags: .maskControl)
    }

    // MARK: - Move Window And Return

    /// Moves the focused window to a specific space, then switches back to the current space.
    func moveWindowToSpaceAndReturn(at index: Int) {
        guard index >= 1, index <= 10 else {
            Log.error("Spaces: moveWindowToSpaceAndReturn index \(index) out of range 1-10")
            return
        }

        // CGS path: moveWindow doesn't change the active space, so no return needed.
        if useCGS, let wid = focusedWindowID() {
            Log.info("Spaces: moving window \(wid) to space \(index) via CGS (staying on current space)")
            CGSSpaceService.moveWindow(wid, toSpaceAt: index)
            return
        }

        let digit = index == 10 ? "0" : "\(index)"
        guard let targetKeyCode = KeyCode.from(digit) else {
            Log.error("Spaces: moveWindowToSpaceAndReturn — no keycode for \"\(digit)\"")
            return
        }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToSpaceAndReturn — could not determine focused window frame")
            return
        }

        // Determine current space index for the return trip
        let returnIndex = CGSSpaceService.currentSpaceIndex()

        Log.info("Spaces: moving window to space \(index) via drag, then returning to space \(returnIndex.map(String.init) ?? "?")")
        performMouseDragSpaceSwitchAndReturn(
            windowFrame: frame,
            keyCode: targetKeyCode,
            flags: .maskControl,
            returnIndex: returnIndex
        )
    }

    /// Moves the focused window to the next space, then switches back.
    func moveWindowToNextSpaceAndReturn() {
        if useCGS, let wid = focusedWindowID(), let current = CGSSpaceService.currentSpaceIndex() {
            let spaces = CGSSpaceService.userSpaceIDs()
            let next = current < spaces.count ? current + 1 : 1
            Log.info("Spaces: moving window \(wid) to next space (\(next)) via CGS (staying)")
            CGSSpaceService.moveWindow(wid, toSpaceAt: next)
            return
        }

        guard let keyCode = KeyCode.from("right") else { return }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToNextSpaceAndReturn — could not determine focused window frame")
            return
        }
        guard let returnKeyCode = KeyCode.from("left") else { return }

        Log.info("Spaces: moving window to next space via drag, then returning (Ctrl+Left)")
        performMouseDragSpaceSwitchAndReturn(
            windowFrame: frame,
            keyCode: keyCode,
            flags: .maskControl,
            returnKeyCode: returnKeyCode,
            returnFlags: .maskControl
        )
    }

    /// Moves the focused window to the previous space, then switches back.
    func moveWindowToPreviousSpaceAndReturn() {
        if useCGS, let wid = focusedWindowID(), let current = CGSSpaceService.currentSpaceIndex() {
            let spaces = CGSSpaceService.userSpaceIDs()
            let prev = current > 1 ? current - 1 : spaces.count
            Log.info("Spaces: moving window \(wid) to previous space (\(prev)) via CGS (staying)")
            CGSSpaceService.moveWindow(wid, toSpaceAt: prev)
            return
        }

        guard let keyCode = KeyCode.from("left") else { return }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToPreviousSpaceAndReturn — could not determine focused window frame")
            return
        }
        guard let returnKeyCode = KeyCode.from("right") else { return }

        Log.info("Spaces: moving window to previous space via drag, then returning (Ctrl+Right)")
        performMouseDragSpaceSwitchAndReturn(
            windowFrame: frame,
            keyCode: keyCode,
            flags: .maskControl,
            returnKeyCode: returnKeyCode,
            returnFlags: .maskControl
        )
    }

    /// Performs the drag, waits for the space animation, then switches back.
    /// If `returnIndex` is provided, uses Ctrl+digit. Otherwise uses `returnKeyCode`.
    private func performMouseDragSpaceSwitchAndReturn(
        windowFrame frame: CGRect,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        returnIndex: Int? = nil,
        returnKeyCode: CGKeyCode? = nil,
        returnFlags: CGEventFlags = .maskControl
    ) {
        let clickPoint = CGPoint(
            x: frame.midX,
            y: frame.origin.y + kTitleBarOffset
        )
        let dragPoint = CGPoint(
            x: clickPoint.x + kDragNudge,
            y: clickPoint.y
        )

        DispatchQueue.global(qos: .userInteractive).async { [self] in
            // 1–5: Same drag sequence as performMouseDragSpaceSwitch
            postMouseEvent(.leftMouseDown, at: clickPoint)
            usleep(kMouseDownSettleDelay)
            postMouseEvent(.leftMouseDragged, at: dragPoint)
            usleep(kDragSettleDelay)
            postSyntheticKeyDown(keyCode: keyCode, flags: flags)
            usleep(kKeyHoldDelay)
            postSyntheticKeyUp(keyCode: keyCode, flags: flags)
            usleep(kSpaceAnimationDelay)
            postMouseEvent(.leftMouseUp, at: dragPoint)

            // 6: Wait for the space transition to settle, then switch back
            usleep(kSpaceAnimationDelay)

            if let returnIndex, returnIndex >= 1, returnIndex <= 10 {
                let digit = returnIndex == 10 ? "0" : "\(returnIndex)"
                if let retKeyCode = KeyCode.from(digit) {
                    Log.info("Spaces: returning to space \(returnIndex) via Ctrl+\(digit)")
                    postSyntheticKey(keyCode: retKeyCode, flags: returnFlags)
                }
            } else if let returnKeyCode {
                postSyntheticKey(keyCode: returnKeyCode, flags: returnFlags)
            }
        }
    }

    // MARK: - Mouse-Drag Space Switch

    /// Holds the window via a synthetic mouse-down on its title bar, nudges
    /// the mouse to initiate the drag, fires the space-switch keystroke
    /// (key-down, pause, key-up), waits for the transition animation, then
    /// releases the mouse.
    ///
    /// Uses a **private** event source for mouse events so they don't
    /// inherit keyboard modifier state from the session — otherwise macOS
    /// interprets Ctrl+mouseUp as a right-click.
    ///
    /// Runs on a background thread so the blocking `usleep` calls don't
    /// stall the caller.
    private func performMouseDragSpaceSwitch(
        windowFrame frame: CGRect,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) {
        let clickPoint = CGPoint(
            x: frame.midX,
            y: frame.origin.y + kTitleBarOffset
        )
        let dragPoint = CGPoint(
            x: clickPoint.x + kDragNudge,
            y: clickPoint.y
        )

        DispatchQueue.global(qos: .userInteractive).async { [self] in
            // 1. Mouse-down on the title bar.
            postMouseEvent(.leftMouseDown, at: clickPoint)
            usleep(kMouseDownSettleDelay)

            // 2. Small drag to actually initiate the window grab.
            postMouseEvent(.leftMouseDragged, at: dragPoint)
            usleep(kDragSettleDelay)

            // 3. Key-down: begin the space switch (Ctrl held).
            postSyntheticKeyDown(keyCode: keyCode, flags: flags)
            usleep(kKeyHoldDelay)

            // 4. Key-up: complete the keystroke.
            postSyntheticKeyUp(keyCode: keyCode, flags: flags)
            usleep(kSpaceAnimationDelay)

            // 5. Release the mouse on the new space.
            postMouseEvent(.leftMouseUp, at: dragPoint)
        }
    }

    // MARK: - Focused Window Helpers

    /// Returns the CGWindowID of the frontmost app's focused window by
    /// matching the AX window position against CGWindowList.
    private func focusedWindowID() -> CGWindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Pick the first on-screen, layer-0 window belonging to the
        // frontmost app.
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return windowID
        }

        return nil
    }

    private func focusedWindowFrame() -> CGRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = windows.first else {
            return nil
        }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    // MARK: - Synthetic Mouse Events

    /// Posts a synthetic mouse event at the given screen-coordinate point.
    ///
    /// Uses a **private** event source so the event's modifier flags are
    /// not polluted by whatever keys happen to be held at post time.
    /// This prevents macOS from interpreting a plain left-click as
    /// Ctrl+click (right-click) when Ctrl is down for the space switch.
    private func postMouseEvent(_ type: CGEventType, at point: CGPoint) {
        let source = CGEventSource(stateID: .privateState)

        let mouseButton: CGMouseButton = switch type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            .right
        default:
            .left
        }

        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: mouseButton
        ) else {
            Log.error("Spaces: failed to create CGEvent for mouse type \(type.rawValue)")
            return
        }

        // Explicitly clear all modifier flags so macOS never treats this
        // as a modified click (Ctrl+click → right-click, etc.).
        event.flags = CGEventFlags()

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Synthetic Keyboard Events

    /// Posts a tagged key-down + key-up pair so our HotkeyService passes
    /// it through.  Used for space-focus shortcuts.
    private func postSyntheticKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        postSyntheticKeyDown(keyCode: keyCode, flags: flags)
        postSyntheticKeyUp(keyCode: keyCode, flags: flags)
    }

    private func postSyntheticKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            Log.error("Spaces: failed to create key-down CGEvent for keycode \(keyCode)")
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventTag)
        event.post(tap: .cghidEventTap)
    }

    private func postSyntheticKeyUp(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("Spaces: failed to create key-up CGEvent for keycode \(keyCode)")
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventTag)
        event.post(tap: .cghidEventTap)
    }
}
