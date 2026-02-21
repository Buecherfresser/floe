import CoreGraphics
import AppKit
import Foundation

/// Implements focus-follows-mouse by listening to mouse-moved events,
/// throttling lookups, and focusing the window under the cursor.
final class FocusFollowsMouse: @unchecked Sendable {
    private let accessibilityService: AccessibilityService

    private let configLock = NSLock()
    private var _config: FocusFollowsMouseConfig
    var config: FocusFollowsMouseConfig {
        get { configLock.withLock { _config } }
        set { configLock.withLock { _config = newValue } }
    }

    private var eventTapService: EventTapService?

    // All throttle state is accessed exclusively on throttleQueue
    private let throttleQueue = DispatchQueue(label: "com.jonasdrechsel.floe.focus-throttle")
    private var lastFocusedWindowID: CGWindowID = 0
    private var lastLookupTime: UInt64 = 0
    private var trailingWorkItem: DispatchWorkItem?

    private static let ignoredWindowOwners: Set<String> = ["Window Server", "Dock"]
    private static let minimumWindowLayer = 0
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    init(accessibilityService: AccessibilityService, config: FocusFollowsMouseConfig) {
        self.accessibilityService = accessibilityService
        self._config = config
    }

    func start() {
        stop()

        let service = EventTapService { [weak self] point in
            self?.handleMouseMoved(to: point)
        }
        service.start()
        eventTapService = service
    }

    func stop() {
        eventTapService?.stop()
        eventTapService = nil
        trailingWorkItem?.cancel()
        trailingWorkItem = nil
    }

    // MARK: - Mouse Handling (Throttle)

    private func handleMouseMoved(to point: CGPoint) {
        let cfg = config
        guard cfg.enabled else { return }

        throttleQueue.async { [weak self] in
            self?.throttledLookup(at: point, config: cfg)
        }
    }

    /// All throttle bookkeeping happens here, serialized on throttleQueue.
    private func throttledLookup(at point: CGPoint, config: FocusFollowsMouseConfig) {
        let now = mach_absolute_time()
        let intervalNanos = UInt64(max(0, config.delay)) * 1_000_000

        trailingWorkItem?.cancel()
        trailingWorkItem = nil

        let elapsed = now &- lastLookupTime
        if elapsed >= intervalNanos {
            lastLookupTime = now
            focusWindowUnderCursor(at: point, config: config)
        } else {
            let remaining = intervalNanos &- elapsed
            let remainingMs = Int(remaining / 1_000_000)
            let workItem = DispatchWorkItem { [weak self] in
                self?.lastLookupTime = mach_absolute_time()
                self?.focusWindowUnderCursor(at: point, config: config)
            }
            trailingWorkItem = workItem
            throttleQueue.asyncAfter(
                deadline: .now() + .milliseconds(max(1, remainingMs)),
                execute: workItem
            )
        }
    }

    private func focusWindowUnderCursor(at point: CGPoint, config: FocusFollowsMouseConfig) {
        guard let windowInfo = windowUnderPoint(point) else {
            Log.debug("FFM: no window found at (\(point.x), \(point.y))")
            return
        }

        let pid = windowInfo.pid
        let wid = windowInfo.windowID
        let name = windowInfo.ownerName ?? "<unknown>"

        if wid == lastFocusedWindowID {
            return
        }

        if let appName = windowInfo.ownerName,
           config.ignoreApps.contains(appName) {
            Log.debug("FFM: \(appName) is in ignoreApps, skipping")
            return
        }

        Log.debug("FFM: focusing wid=\(wid) pid=\(pid) (\(name)), previousWid=\(lastFocusedWindowID)")
        lastFocusedWindowID = wid

        let ax = accessibilityService
        let origin = windowInfo.bounds.origin
        DispatchQueue.main.async {
            ax.focusApp(pid: pid)
            ax.raiseWindow(pid: pid, targetOrigin: origin)
        }
    }

    // MARK: - Window Lookup

    private struct WindowInfo {
        let pid: pid_t
        let windowID: CGWindowID
        let ownerName: String?
        let bounds: CGRect
    }

    private func windowUnderPoint(_ point: CGPoint) -> WindowInfo? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            Log.debug("FFM/windowLookup: CGWindowListCopyWindowInfo returned nil")
            return nil
        }

        Log.debug("FFM/windowLookup: \(infoList.count) windows on screen, cursor at (\(point.x), \(point.y))")

        for info in infoList {
            guard let boundsDict = info[kCGWindowBounds] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let layer = info[kCGWindowLayer] as? Int,
                  let windowID = info[kCGWindowNumber] as? CGWindowID else {
                continue
            }

            let ownerName = info[kCGWindowOwnerName] as? String

            guard layer == Self.minimumWindowLayer else { continue }

            if pid == Self.ownPID {
                continue
            }

            if let ownerName, Self.ignoredWindowOwners.contains(ownerName) {
                continue
            }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            if bounds.contains(point) {
                Log.debug("FFM/windowLookup: hit \(ownerName ?? "?") pid=\(pid) wid=\(windowID) bounds=\(bounds)")
                return WindowInfo(pid: pid, windowID: windowID, ownerName: ownerName, bounds: bounds)
            }
        }

        Log.debug("FFM/windowLookup: no window contains cursor point")
        return nil
    }
}
