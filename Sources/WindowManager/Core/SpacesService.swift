import AppKit
import CoreGraphics
import Foundation

/// Magic value set on synthetic keyboard events so our HotkeyService
/// knows to pass them through instead of consuming them.
let kSyntheticEventTag: Int64 = 0x574D_5350 // "WMSP"

// MARK: - SpacesService

/// Provides space switching and window-to-space movement.
///
/// Space switching uses simulated Mission Control keyboard shortcuts (Ctrl+N).
/// Window movement uses mouse-drag simulation (grab title bar, switch space, release).
/// Both approaches work without SIP disabled on modern macOS.
final class SpacesService: @unchecked Sendable {

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
    /// TODO: CGS space APIs are neutered on modern macOS without SIP,
    /// and mouse-drag simulation needs further work. For now this is a no-op.
    func moveWindowToSpace(at index: Int) {
        guard index >= 1, index <= 10 else {
            Log.error("Spaces: moveWindowToSpace index \(index) out of range 1-10")
            return
        }
        Log.info("Spaces: moveWindowToSpace(\(index)) — not yet implemented on this macOS version")
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

    // MARK: - Synthetic Keyboard Events

    /// Posts a tagged key press so our HotkeyService passes it through.
    private func postSyntheticKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            Log.error("Spaces: failed to create CGEvent for keycode \(keyCode)")
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags

        // Tag so HotkeyService knows these are ours
        keyDown.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventTag)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
