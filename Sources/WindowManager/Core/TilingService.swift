@preconcurrency import ApplicationServices
import AppKit
import Foundation

final class TilingService: @unchecked Sendable {
    private let accessibilityService: AccessibilityService

    private let lock = NSLock()
    private var _config: TilingConfig
    var config: TilingConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue }; scheduleRetile() }
    }

    /// Ordered list of tracked window IDs — insertion order determines BSP position.
    private var trackedWindowIDs: [CGWindowID] = []
    /// Maps CGWindowID -> AXUIElement for frame manipulation.
    private var windowElements: [CGWindowID: AXUIElement] = [:]
    /// Maps pid_t -> AXObserver for per-app window event observation.
    private var axObservers: [pid_t: AXObserver] = [:]

    private var workspaceObservers: [NSObjectProtocol] = []

    private let retileQueue = DispatchQueue(label: "com.windowmanager.tiling")
    private var pendingRetile: DispatchWorkItem?

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Control Center",
        "Notification Center", "SystemUIServer",
    ]

    init(accessibilityService: AccessibilityService, config: TilingConfig) {
        self.accessibilityService = accessibilityService
        self._config = config
    }

    // MARK: - Lifecycle

    func start() {
        Log.info("Tiling: starting")
        registerWorkspaceObservers()
        registerAXObserversForRunningApps()
        scheduleRetile()
    }

    func stop() {
        Log.info("Tiling: stopping")
        unregisterWorkspaceObservers()
        unregisterAllAXObservers()
        pendingRetile?.cancel()
        pendingRetile = nil
        lock.withLock {
            trackedWindowIDs.removeAll()
            windowElements.removeAll()
        }
    }

    /// Public entry point to force a retile (e.g. from hotkey).
    func retile() {
        scheduleRetile()
    }

    // MARK: - Workspace Observation

    private func registerWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Log.debug("Tiling: app launched — \(app.localizedName ?? "?") pid=\(app.processIdentifier)")
            self?.registerAXObserver(for: app.processIdentifier)
            self?.scheduleRetile()
        }

        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Log.debug("Tiling: app terminated — \(app.localizedName ?? "?") pid=\(app.processIdentifier)")
            self?.unregisterAXObserver(for: app.processIdentifier)
            self?.scheduleRetile()
        }

        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRetile()
        }

        workspaceObservers = [launchObs, terminateObs, activateObs]
    }

    private func unregisterWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            nc.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - AXObserver (Per-App Window Events)

    private func registerAXObserversForRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            registerAXObserver(for: app.processIdentifier)
        }
    }

    private func registerAXObserver(for pid: pid_t) {
        guard pid != Self.ownPID else { return }
        lock.withLock {
            guard axObservers[pid] == nil else { return }
        }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let obs = observer else {
            Log.debug("Tiling: AXObserverCreate failed for pid=\(pid) (error=\(result.rawValue))")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for notif in notifications {
            AXObserverAddNotification(obs, appElement, notif as CFString, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        lock.withLock {
            axObservers[pid] = obs
        }
        Log.debug("Tiling: registered AXObserver for pid=\(pid)")
    }

    private func unregisterAXObserver(for pid: pid_t) {
        lock.withLock {
            guard let obs = axObservers.removeValue(forKey: pid) else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            Log.debug("Tiling: unregistered AXObserver for pid=\(pid)")
        }
    }

    private func unregisterAllAXObservers() {
        lock.withLock {
            for (pid, obs) in axObservers {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
                Log.debug("Tiling: unregistered AXObserver for pid=\(pid)")
            }
            axObservers.removeAll()
        }
    }

    /// Called from the AXObserver C callback on the main run loop.
    fileprivate func handleAXNotification(_ notification: String, element: AXUIElement) {
        Log.debug("Tiling: AX notification=\(notification)")
        scheduleRetile()
    }

    // MARK: - Retile

    private func scheduleRetile() {
        pendingRetile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performRetile()
        }
        pendingRetile = work
        retileQueue.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    private func performRetile() {
        let cfg = config
        guard cfg.enabled else { return }

        guard let screen = NSScreen.main else {
            Log.debug("Tiling: no main screen found")
            return
        }

        let visibleFrame = screen.visibleFrame
        // Convert from NSScreen coordinates (origin at bottom-left) to CG coordinates (origin at top-left)
        let screenFrame = screen.frame
        let tilingRect = CGRect(
            x: visibleFrame.origin.x,
            y: screenFrame.height - visibleFrame.origin.y - visibleFrame.height,
            width: visibleFrame.width,
            height: visibleFrame.height
        )

        Log.debug("Tiling: retiling in rect=\(tilingRect)")

        let tileableWindows = enumerateTileableWindows(config: cfg)
        Log.debug("Tiling: found \(tileableWindows.count) tileable window(s)")

        guard !tileableWindows.isEmpty else { return }

        let windowIDs = tileableWindows.map(\.windowID)

        // Reconcile tracked order: keep existing order, append new windows, remove gone ones
        lock.lock()
        var newTracked: [CGWindowID] = []
        for wid in trackedWindowIDs {
            if windowIDs.contains(wid) { newTracked.append(wid) }
        }
        for wid in windowIDs {
            if !newTracked.contains(wid) { newTracked.append(wid) }
        }
        trackedWindowIDs = newTracked

        var newElements: [CGWindowID: AXUIElement] = [:]
        for tw in tileableWindows {
            newElements[tw.windowID] = tw.element
        }
        windowElements = newElements
        let orderedIDs = trackedWindowIDs
        lock.unlock()

        let buildFn: ([CGWindowID]) -> BSPNode? = cfg.autoBalance
            ? { BSPTree.buildBalanced(windowIDs: $0) }
            : { BSPTree.build(windowIDs: $0, ratio: cfg.splitRatio) }

        guard let tree = buildFn(orderedIDs) else {
            Log.debug("Tiling: BSPTree.build returned nil")
            return
        }

        let frames = tree.calculateFrames(
            in: tilingRect,
            innerGap: CGFloat(cfg.gaps.inner),
            outerGap: CGFloat(cfg.gaps.outer)
        )

        let elements: [CGWindowID: AXUIElement] = lock.withLock { windowElements }
        for (windowID, frame) in frames {
            guard let element = elements[windowID] else {
                Log.debug("Tiling: no AXUIElement for wid=\(windowID), skipping")
                continue
            }
            Log.debug("Tiling: setting wid=\(windowID) frame=\(frame)")
            accessibilityService.setWindowFrame(element: element, frame: frame)
        }

        Log.info("Tiling: applied \(frames.count) window frame(s)")
    }

    // MARK: - Window Enumeration

    private struct TileableWindow {
        let windowID: CGWindowID
        let pid: pid_t
        let ownerName: String?
        let element: AXUIElement
    }

    private func enumerateTileableWindows(config: TilingConfig) -> [TileableWindow] {
        let excludedApps = Set(config.rules.filter { !$0.tiled }.map(\.app))

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            Log.debug("Tiling: CGWindowListCopyWindowInfo returned nil")
            return []
        }

        // Group CG windows by PID so we can match them to AX windows
        struct CGWindowInfo {
            let windowID: CGWindowID
            let bounds: CGRect
        }
        var cgWindowsByPID: [pid_t: [CGWindowInfo]] = [:]

        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let layer = info[kCGWindowLayer] as? Int,
                  let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds] as? [String: CGFloat] else {
                continue
            }

            guard layer == 0 else { continue }
            guard pid != Self.ownPID else { continue }

            let ownerName = info[kCGWindowOwnerName] as? String
            if let ownerName, Self.ignoredOwners.contains(ownerName) { continue }
            if let ownerName, excludedApps.contains(ownerName) { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            // Skip tiny windows (likely invisible or utility)
            guard bounds.width >= 50 && bounds.height >= 50 else { continue }

            cgWindowsByPID[pid, default: []].append(CGWindowInfo(windowID: windowID, bounds: bounds))
        }

        // For each PID, get AX windows and match to CG windows by position+size
        var result: [TileableWindow] = []

        for (pid, cgWindows) in cgWindowsByPID {
            let axWindows = accessibilityService.windows(for: pid)

            var unmatchedCG = cgWindows
            for (axElement, axFrame) in axWindows {
                guard accessibilityService.isStandardWindow(axElement) else { continue }

                // Find matching CG window by position+size (within tolerance)
                if let idx = unmatchedCG.firstIndex(where: { cg in
                    abs(cg.bounds.origin.x - axFrame.origin.x) < 5 &&
                    abs(cg.bounds.origin.y - axFrame.origin.y) < 5 &&
                    abs(cg.bounds.width - axFrame.width) < 5 &&
                    abs(cg.bounds.height - axFrame.height) < 5
                }) {
                    let cg = unmatchedCG.remove(at: idx)
                    let ownerName = NSRunningApplication(processIdentifier: pid)?.localizedName
                    result.append(TileableWindow(
                        windowID: cg.windowID,
                        pid: pid,
                        ownerName: ownerName,
                        element: axElement
                    ))
                }
            }
        }

        return result
    }
}

// MARK: - AXObserver C Callback

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<TilingService>.fromOpaque(refcon).takeUnretainedValue()
    service.handleAXNotification(notification as String, element: element)
}
