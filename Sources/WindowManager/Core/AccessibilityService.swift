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
}
