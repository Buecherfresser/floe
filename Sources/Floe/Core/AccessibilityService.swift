@preconcurrency import ApplicationServices
import AppKit

/// Private HIServices call mapping an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
final class AccessibilityService: ObservableObject {
    @Published private(set) var isTrusted = false

    init() {
        checkPermission()
    }

    func checkPermission() {
        isTrusted = AXIsProcessTrusted()
    }

    func promptForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Focus

    nonisolated func focusApp(pid: pid_t) {
        guard let nsApp = NSRunningApplication(processIdentifier: pid) else {
            Log.debug("AX: NSRunningApplication not found for pid=\(pid)")
            return
        }
        // Since macOS 14 activation is cooperative and `activate()` from a
        // background agent is often ignored; setting AXFrontmost isn't.
        let axResult = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue
        )
        let activated = axResult == .success || nsApp.activate()
        Log.debug("AX: activate pid=\(pid) name=\(nsApp.localizedName ?? "?") ax=\(axResult.rawValue) result=\(activated)")
    }

    /// Raises the specific window of a given app whose position matches `targetOrigin`.
    /// Retries once after a short delay if the first attempt returns an error.
    nonisolated func raiseWindow(pid: pid_t, targetOrigin: CGPoint) {
        let result = raiseWindowAttempt(pid: pid, targetOrigin: targetOrigin)
        if result != .success && result != .noValue {
            Log.debug("AX: raiseWindow first attempt failed (\(result.rawValue)), retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in
                let retry = self.raiseWindowAttempt(pid: pid, targetOrigin: targetOrigin)
                Log.debug("AX: raiseWindow retry result=\(retry.rawValue)")
            }
        }
    }

    private nonisolated func raiseWindowAttempt(pid: pid_t, targetOrigin: CGPoint) -> AXError {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            Log.debug("AX: raiseWindow pid=\(pid) — no AX windows (result=\(result.rawValue))")
            return result
        }

        for window in windows {
            var positionRef: CFTypeRef?
            let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
            guard posResult == .success, let posVal = positionRef else { continue }

            var position = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &position)

            if abs(position.x - targetOrigin.x) < 2 && abs(position.y - targetOrigin.y) < 2 {
                let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                Log.debug("AX: raiseWindow pid=\(pid) matched origin=(\(position.x),\(position.y)) result=\(raiseResult.rawValue)")
                return raiseResult
            }
        }

        let raiseResult = AXUIElementPerformAction(windows[0], kAXRaiseAction as CFString)
        Log.debug("AX: raiseWindow pid=\(pid) no origin match, raised first window result=\(raiseResult.rawValue)")
        return raiseResult
    }

    nonisolated func raiseWindow(pid: pid_t, windowIndex: Int = 0) {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success,
              let windows = windowsRef as? [AXUIElement],
              windowIndex < windows.count else {
            Log.debug("AX: raiseWindow pid=\(pid) — no windows found (result=\(result.rawValue))")
            return
        }

        let raiseResult = AXUIElementPerformAction(windows[windowIndex], kAXRaiseAction as CFString)
        Log.debug("AX: raiseWindow pid=\(pid) windowIndex=\(windowIndex) result=\(raiseResult.rawValue)")
    }

    /// Returns the PID of the currently focused application.
    nonisolated func focusedAppPID() -> pid_t? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontApp.processIdentifier
    }

    // MARK: - Window Frame Manipulation

    /// Sets the position and size of an AX window element.
    /// Moves/resizes a window, touching only what actually differs: every
    /// redundant set makes the app redraw, which flickers (retiles happen on
    /// every focus change).
    /// Returns the frame the window had before (nil if unreadable).
    @discardableResult
    nonisolated func setWindowFrame(element: AXUIElement, frame: CGRect) -> CGRect? {
        let current = windowFrame(of: element)
        let tolerance: CGFloat = 1
        let needsMove = current.map { abs($0.minX - frame.minX) > tolerance || abs($0.minY - frame.minY) > tolerance } ?? true
        let needsResize = current.map { abs($0.width - frame.width) > tolerance || abs($0.height - frame.height) > tolerance } ?? true
        guard needsMove || needsResize else { return current }

        if let windowID = windowID(of: element) { WindowTouches.note(windowID) }
        var position = frame.origin
        var size = CGSize(width: frame.width, height: frame.height)

        if needsMove, let posValue = AXValueCreate(.cgPoint, &position) {
            let posResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            if posResult != .success {
                Log.debug("AX: setWindowFrame position failed (\(posResult.rawValue))")
            }
        }

        if needsResize, let sizeValue = AXValueCreate(.cgSize, &size) {
            let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            if sizeResult != .success {
                Log.debug("AX: setWindowFrame size failed (\(sizeResult.rawValue))")
            }

            // Some apps (Electron) ignore a small shrink from a full-height or
            // full-width state, but accept the size when coming from below.
            if let before = current, let after = windowFrame(of: element),
               abs(after.width - before.width) <= tolerance, abs(after.height - before.height) <= tolerance,
               abs(after.width - frame.width) > tolerance || abs(after.height - frame.height) > tolerance {
                var smaller = CGSize(width: frame.width * 0.95, height: frame.height * 0.95)
                if let smallerValue = AXValueCreate(.cgSize, &smaller) {
                    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, smallerValue)
                    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
                }
            }

            // Some apps adjust their origin when resized — correct it if so.
            if let after = windowFrame(of: element),
               abs(after.minX - frame.minX) > tolerance || abs(after.minY - frame.minY) > tolerance,
               let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            }
        }
        return current
    }

    /// Returns AXUIElement windows for a given PID along with their current frames.
    nonisolated func windows(for pid: pid_t) -> [(element: AXUIElement, frame: CGRect)] {
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }

        var results: [(element: AXUIElement, frame: CGRect)] = []
        for window in axWindows {
            // Skip minimized windows
            var minimizedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let minimized = minimizedRef as? Bool, minimized {
                continue
            }

            guard let frame = windowFrame(of: window) else { continue }
            results.append((element: window, frame: frame))
        }
        return results
    }

    /// Reads the current position and size of an AX window element.
    nonisolated func windowFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    nonisolated func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    nonisolated func isFullScreen(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    /// Asks the app to take the window out of native fullscreen. The exit
    /// animates; the window lands back on a desktop when it finishes.
    @discardableResult
    nonisolated func exitFullScreen(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse) == .success
    }

    /// Releases a window from macOS's own window tiling (Window › Move &
    /// Resize › Return to Previous Size). Tiled windows otherwise snap back
    /// to their tile whenever they're moved or resized from outside.
    /// The menu item acts on the app's main window, so make it main first.
    @discardableResult
    nonisolated func untileWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef, CFGetTypeID(menuBarRef) == AXUIElementGetTypeID(),
              let item = findMenuItem(in: menuBarRef as! AXUIElement, identifier: "_zoomUntile:", depth: 5) else {
            return false
        }
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           (enabledRef as? Bool) == false {
            return false // not tiled
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private nonisolated func findMenuItem(in element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard depth > 0,
              AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            var idRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &idRef) == .success,
               (idRef as? String) == identifier {
                return child
            }
            if let found = findMenuItem(in: child, identifier: identifier, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Whether the window can be resized. Fixed-size windows (System Settings,
    /// Calculator, …) can't fill a tile, so tiling leaves them floating.
    nonisolated func isResizable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success,
           !settable.boolValue {
            return false
        }

        // Fixed-size windows report a settable size but disable the zoom button.
        var zoomRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &zoomRef) == .success,
           let zoomRef, CFGetTypeID(zoomRef) == AXUIElementGetTypeID() {
            var enabledRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(zoomRef as! AXUIElement, kAXEnabledAttribute as CFString, &enabledRef) == .success,
               let enabled = enabledRef as? Bool, !enabled {
                return false
            }
        }

        return true
    }

    /// Checks if an AX window element has the standard window subrole (not a dialog, sheet, etc.).
    nonisolated func isStandardWindow(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        var subroleRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String, role == kAXWindowRole as String else {
            return false
        }

        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String {
            return subrole == kAXStandardWindowSubrole as String
        }

        return true
    }
}
