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

    /// Set after Floe focuses a window itself (hotkeys, app switcher): the
    /// window under the cursor at that moment must not steal focus back —
    /// only entering a different window does.
    nonisolated(unsafe) private static var ignoreHoverFlag = false
    private static let ignoreHoverLock = NSLock()

    static func ignoreCurrentHover() {
        ignoreHoverLock.withLock { ignoreHoverFlag = true }
    }

    /// While a space switch is in flight the window list still shows the old
    /// space's windows — focusing one makes macOS switch right back to it.
    nonisolated(unsafe) private static var suppressedUntil = DispatchTime(uptimeNanoseconds: 0)

    static func suppress(for interval: DispatchTimeInterval = .milliseconds(500)) {
        ignoreHoverLock.withLock {
            let until = DispatchTime.now() + interval
            if until > suppressedUntil { suppressedUntil = until }
        }
    }

    private static var isSuppressed: Bool {
        ignoreHoverLock.withLock { DispatchTime.now() < suppressedUntil }
    }

    private var spaceChangeObserver: NSObjectProtocol?

    private static func consumeIgnoreHover() -> Bool {
        ignoreHoverLock.withLock {
            defer { ignoreHoverFlag = false }
            return ignoreHoverFlag
        }
    }
    private static let minimumWindowLayer = 0
    /// Layers at or above this (status bar, screen saver, cursor) are system
    /// chrome rather than app overlays.
    private static let overlayLayerLimit = Int(CGWindowLevelForKey(.statusWindow))
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

        // Covers the user's own trackpad swipes and Ctrl+Arrow too.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { _ in
            FocusFollowsMouse.suppress()
        }
    }

    func stop() {
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
        }
        spaceChangeObserver = nil
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
        let now = DispatchTime.now().uptimeNanoseconds
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
                self?.lastLookupTime = DispatchTime.now().uptimeNanoseconds
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

        if Self.consumeIgnoreHover() {
            lastFocusedWindowID = wid
            return
        }
        if MissionControl.isBusy || Self.isSuppressed {
            return
        }

        if wid == lastFocusedWindowID {
            return
        }

        // Right after a space switch the window list still reports the old
        // space's windows as on-screen. Focusing one of them activates its app,
        // and macOS then switches back to that app's space.
        guard Self.isOnVisibleSpace(wid, at: point) else {
            Log.debug("FFM: wid=\(wid) is not on a visible space (space switch in progress), skipping")
            return
        }

        if let appName = windowInfo.ownerName,
           config.ignoreApps.contains(appName) {
            Log.debug("FFM: \(appName) is in ignoreApps, skipping")
            return
        }

        Log.debug("FFM: focusing wid=\(wid) pid=\(pid) (\(name)), previousWid=\(lastFocusedWindowID)")
        lastFocusedWindowID = wid
        WindowHistory.note(pid: pid, windowID: wid)

        let ax = accessibilityService
        let origin = windowInfo.bounds.origin
        DispatchQueue.main.async {
            ax.focusApp(pid: pid)
            ax.raiseWindow(pid: pid, targetOrigin: origin)
        }
    }

    // MARK: - Window Lookup

    private static func isOnVisibleSpace(_ windowID: CGWindowID, at point: CGPoint) -> Bool {
        let windowSpaces = CGSSpaceService.spaces(forWindow: windowID)
        // Unknown membership (e.g. API unavailable) — don't block focusing.
        guard !windowSpaces.isEmpty else { return true }
        let displays = CGSSpaceService.displays()
        // Prefer the display under the cursor: the window must be on the space
        // that display is showing.
        if let monitor = Monitors.ordered().first(where: { $0.bounds.contains(point) }),
           let display = displays.first(where: { $0.identifier.caseInsensitiveCompare(monitor.uuid) == .orderedSame }) {
            return windowSpaces.contains(display.currentSpace)
        }
        let visible = Set(displays.map(\.currentSpace))
        return windowSpaces.contains { visible.contains($0) }
    }

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

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // A menu, popover or panel above normal windows is under the
            // cursor — focusing the window beneath it would close it.
            if layer > Self.minimumWindowLayer, layer < Self.overlayLayerLimit,
               bounds.contains(point), ownerName.map({ !Self.ignoredWindowOwners.contains($0) }) ?? true {
                Log.debug("FFM/windowLookup: overlay \(ownerName ?? "?") layer=\(layer) under cursor, skipping")
                return nil
            }

            guard layer == Self.minimumWindowLayer else { continue }

            if pid == Self.ownPID {
                continue
            }

            if let ownerName, Self.ignoredWindowOwners.contains(ownerName) {
                continue
            }

            if bounds.contains(point) {
                Log.debug("FFM/windowLookup: hit \(ownerName ?? "?") pid=\(pid) wid=\(windowID) bounds=\(bounds)")
                return WindowInfo(pid: pid, windowID: windowID, ownerName: ownerName, bounds: bounds)
            }
        }

        Log.debug("FFM/windowLookup: no window contains cursor point")
        return nil
    }
}
