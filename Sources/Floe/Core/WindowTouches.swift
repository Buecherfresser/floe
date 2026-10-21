import CoreGraphics
import Foundation

/// Remembers windows whose frame or space Floe itself just changed, so the
/// resulting Accessibility notifications aren't mistaken for the app (or the
/// user) moving the window.
enum WindowTouches {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var touched: [CGWindowID: DispatchTime] = [:]

    static func note(_ windowID: CGWindowID) {
        lock.withLock {
            let now = DispatchTime.now()
            touched[windowID] = now
            if touched.count > 200 {
                touched = touched.filter { now < $0.value + .seconds(5) }
            }
        }
    }

    static func wasTouched(_ windowID: CGWindowID, within interval: DispatchTimeInterval = .milliseconds(600)) -> Bool {
        lock.withLock { touched[windowID].map { DispatchTime.now() < $0 + interval } ?? false }
    }
}
