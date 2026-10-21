import CoreGraphics
import Foundation

/// The window each app last had in front. The window server's list can't
/// tell that apart reliably: hidden windows some apps keep around (Safari)
/// look just like real windows on another desktop.
enum WindowHistory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastWindow: [pid_t: CGWindowID] = [:]

    static func note(pid: pid_t, windowID: CGWindowID) {
        lock.withLock { lastWindow[pid] = windowID }
    }

    static func lastWindow(of pid: pid_t) -> CGWindowID? {
        lock.withLock { lastWindow[pid] }
    }
}
