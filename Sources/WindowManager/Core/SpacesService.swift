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
/// Space switching uses simulated Mission Control keyboard shortcuts (Ctrl+N).
/// Window movement uses mouse-drag simulation (grab title bar, switch space,
/// release) by default.  When configured, the CGS private API path can be used
/// instead (requires SIP disabled on macOS 15+).
final class SpacesService: @unchecked Sendable {

    var moveMethod: SpaceMoveMethod = .mouseDrag

    // MARK: - Space Switching

    /// Switches to the space at the given 1-based index by simulating
    /// the Mission Control shortcut Ctrl+Number.
    /// Requires "Switch to Desktop N" shortcuts enabled in System Settings.
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
    ///
    /// Exploits the macOS behaviour where a held window travels with a
    /// space switch: we simulate mouse-down on the title bar, fire the
    /// Ctrl+Number shortcut that Mission Control listens for, then release
    /// the mouse after the transition animation.
    func moveWindowToSpace(at index: Int) {
        guard index >= 1, index <= 10 else {
            Log.error("Spaces: moveWindowToSpace index \(index) out of range 1-10")
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

    /// Moves the focused window to the next space (Ctrl+Right) via mouse-drag.
    func moveWindowToNextSpace() {
        guard let keyCode = KeyCode.from("right") else { return }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToNextSpace — could not determine focused window frame")
            return
        }

        Log.info("Spaces: moving focused window to next space via mouse-drag + Ctrl+Right")
        performMouseDragSpaceSwitch(windowFrame: frame, keyCode: keyCode, flags: .maskControl)
    }

    /// Moves the focused window to the previous space (Ctrl+Left) via mouse-drag.
    func moveWindowToPreviousSpace() {
        guard let keyCode = KeyCode.from("left") else { return }
        guard let frame = focusedWindowFrame() else {
            Log.error("Spaces: moveWindowToPreviousSpace — could not determine focused window frame")
            return
        }

        Log.info("Spaces: moving focused window to previous space via mouse-drag + Ctrl+Left")
        performMouseDragSpaceSwitch(windowFrame: frame, keyCode: keyCode, flags: .maskControl)
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

    // MARK: - Focused Window

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
