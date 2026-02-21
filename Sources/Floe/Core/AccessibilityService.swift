@preconcurrency import ApplicationServices
import AppKit

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
        let activated = nsApp.activate()
        Log.debug("AX: activate pid=\(pid) name=\(nsApp.localizedName ?? "?") result=\(activated)")
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
    nonisolated func setWindowFrame(element: AXUIElement, frame: CGRect) {
        var position = frame.origin
        var size = CGSize(width: frame.width, height: frame.height)

        if let posValue = AXValueCreate(.cgPoint, &position) {
            let posResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            if posResult != .success {
                Log.debug("AX: setWindowFrame position failed (\(posResult.rawValue))")
            }
        }

        if let sizeValue = AXValueCreate(.cgSize, &size) {
            let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            if sizeResult != .success {
                Log.debug("AX: setWindowFrame size failed (\(sizeResult.rawValue))")
            }
        }

        // Set position again after resize — some apps adjust origin when resized
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        }
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
