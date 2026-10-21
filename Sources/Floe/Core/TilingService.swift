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

    /// Ordered list of ALL tracked window IDs — insertion order determines BSP position.
    /// Windows are never removed here except on app termination, so that switching
    /// spaces and coming back preserves the original tiling order.
    private var trackedWindowIDs: [CGWindowID] = []
    /// Tracks which PID owns each tracked window, for cleanup on app termination.
    private var windowOwners: [CGWindowID: pid_t] = [:]
    /// Maps CGWindowID -> AXUIElement for frame manipulation.
    private var windowElements: [CGWindowID: AXUIElement] = [:]
    /// Maps pid_t -> AXObserver for per-app window event observation.
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Windows that refused their tile size (fixed-size windows such as
    /// System Settings). They float for the rest of their lifetime.
    private var floatingWindowIDs: Set<CGWindowID> = []
    /// When a window was first seen staying larger than its tile. Some apps
    /// resize asynchronously, so one reading isn't conclusive.
    private var firstRefusal: [CGWindowID: DispatchTime] = [:]
    private static let refusalRecheckDelay: DispatchTimeInterval = .milliseconds(600)
    /// Apps that snap to a grid (Terminal's character cells) end up this much
    /// larger than asked. More than that means a real minimum size.
    private static let roundingTolerance: CGFloat = 20

    /// Allowed difference between requested and applied size before a
    /// window counts as unable to fill its tile.
    private static let sizeRefusalTolerance: CGFloat = 50

    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: Interactive state (confined to `retileQueue` unless noted)

    /// The layout last applied to a screen, keyed by its visible rect.
    private struct ScreenLayout {
        let windowIDs: [CGWindowID]
        /// Tree without user-adjusted ratios.
        let baseTree: BSPNode
        let rect: CGRect
        let innerGap: CGFloat
        let outerGap: CGFloat
    }
    private var screenLayouts: [String: ScreenLayout] = [:]
    /// Split ratios the user set by resizing, keyed by the set of windows they
    /// apply to — so they survive switching desktops and coming back. An
    /// entry only applies while the windows are in the same order (same tree).
    private var ratioOverrides: [String: (windowIDs: [CGWindowID], ratios: [String: Double])] = [:]

    private static func overrideKey(_ windowIDs: [CGWindowID]) -> String {
        windowIDs.sorted().map(String.init).joined(separator: ",")
    }

    /// The user ratios for the layout currently shown on a screen.
    private func userRatios(onScreen screenKey: String) -> [String: Double]? {
        guard let layout = screenLayouts[screenKey],
              let entry = ratioOverrides[Self.overrideKey(layout.windowIDs)],
              entry.windowIDs == layout.windowIDs else { return nil }
        return entry.ratios
    }

    private func setUserRatios(_ ratios: [String: Double]?, onScreen screenKey: String) {
        guard let layout = screenLayouts[screenKey] else { return }
        ratioOverrides[Self.overrideKey(layout.windowIDs)] = ratios.map { (layout.windowIDs, $0) }
    }
    /// Frames Floe last set, to tell our own moves from the user's.
    private var appliedFrames: [CGWindowID: (frame: CGRect, time: DispatchTime)] = [:]
    private var screenKeyForWindow: [CGWindowID: String] = [:]
    /// Windows the user moved or resized during the current mouse drag.
    private var userAdjustedWindowIDs: Set<CGWindowID> = []
    /// Recent app-initiated frame changes per window, to stop snap-back loops
    /// with apps that keep resizing themselves.
    private var snapBacks: [CGWindowID: [DispatchTime]] = [:]
    /// Windows something else holds in place: right after Floe sets their
    /// tile they jump back to the frame they had (maximized/zoomed windows,
    /// windows in macOS's own edge tiling). Floated with the frame they're
    /// held at; they rejoin the layout once moved away from it.
    private var heldFrames: [CGWindowID: CGRect] = [:]
    private var heldElements: [CGWindowID: AXUIElement] = [:]
    private var holdFights: [CGWindowID: Int] = [:]
    /// Frame each window had just before Floe last changed it.
    private var previousFrames: [CGWindowID: CGRect] = [:]
    /// Windows that took a tile at least once. Only windows that never did
    /// can be "held" — an app adjusting its size now and then (Terminal
    /// snapping to its character grid, a zoom) isn't something holding it.
    private var acceptedTile: Set<CGWindowID> = []
    /// Smallest size each window has been seen to accept (larger than a tile
    /// it refused). The layout widens such windows' tiles instead of
    /// floating them.
    private var minSizes: [CGWindowID: CGSize] = [:]
    /// Last tile requested per window and the frame the window settled at.
    /// Apps that round sizes (Terminal's character grid) settle a few points
    /// off; asking again on every retile only makes them redraw.
    private var settledFrames: [CGWindowID: (target: CGRect, actual: CGRect)] = [:]

    private static let snapBackLimit = 4
    private static let snapBackWindow: DispatchTimeInterval = .seconds(8)
    private static let snapBackSettle: DispatchTimeInterval = .milliseconds(300)
    private var liveApplyPending = false

    /// ⌃-drag resize in progress (accessed under `lock` from the mouse tap).
    private struct ResizeSession {
        let windowID: CGWindowID
        let screenKey: String
        let startMouse: CGPoint
        let startFrame: CGRect
        var baseRatios: [String: Double]
        var movesRightEdge: Bool
        var movesBottomEdge: Bool
        var mouse: CGPoint
        /// Set for a window that isn't tiled: it's resized directly.
        var floatingPID: pid_t? = nil
    }
    /// AX element of the floating window being ⌃-dragged (on `retileQueue`).
    private var floatingResizeElement: (windowID: CGWindowID, element: AXUIElement)?
    private var resizeSession: ResizeSession?
    /// Snapshot of tiled frames for hit-testing from the mouse tap (under `lock`).
    private var tiledFrames: [CGWindowID: CGRect] = [:]
    private var tiledScreenKeys: [CGWindowID: String] = [:]
    private var mouseTap: MouseTap?

    /// Notifications for our own frame changes arrive shortly after we set them.
    private static let ownChangeWindow: DispatchTimeInterval = .milliseconds(300)
    private static let liveApplyInterval: DispatchTimeInterval = .milliseconds(40)

    private let retileQueue = DispatchQueue(label: "com.jonasdrechsel.floe.tiling")
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
        let tap = MouseTap { [weak self] type, location, flags in
            self?.handleMouse(type, at: location, flags: flags) ?? false
        }
        tap.start()
        mouseTap = tap
        scheduleRetile()
    }

    func stop() {
        Log.info("Tiling: stopping")
        unregisterWorkspaceObservers()
        unregisterAllAXObservers()
        mouseTap?.stop()
        mouseTap = nil
        retileQueue.sync {
            pendingRetile?.cancel()
            pendingRetile = nil
        }
        lock.withLock {
            floatingWindowIDs.removeAll()
            firstRefusal.removeAll()
            trackedWindowIDs.removeAll()
            windowOwners.removeAll()
            windowElements.removeAll()
        }
    }

    /// Public entry point to force a retile (e.g. from hotkey).
    func retile() {
        scheduleRetile()
    }

    /// Drops user-adjusted split ratios and retiles.
    func balance() {
        retileQueue.async { [weak self] in
            guard let self else { return }
            self.ratioOverrides.removeAll()
            // Also give floated windows another chance.
            self.lock.withLock {
                self.floatingWindowIDs.removeAll()
                self.firstRefusal.removeAll()
            }
            self.scheduleRetile()
        }
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
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Log.debug("Tiling: app terminated — \(app.localizedName ?? "?") pid=\(pid)")
            self.unregisterAXObserver(for: pid)
            self.removeTrackedWindows(for: pid)
            self.scheduleRetile()
        }

        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRetile()
        }

        let spaceChangeObs = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRetile()
        }

        workspaceObservers = [launchObs, terminateObs, activateObs, spaceChangeObs]
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
        if lock.withLock({ axObservers[pid] != nil }) { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let obs = observer else {
            Log.debug("Tiling: AXObserverCreate failed for pid=\(pid) (error=\(result.rawValue))")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Only observe structural changes. Move/resize notifications are skipped
        // because our own setWindowFrame calls would trigger infinite retile loops.
        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
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

    /// Removes all tracked windows belonging to a terminated app.
    private func removeTrackedWindows(for pid: pid_t) {
        lock.withLock {
            let toRemove = windowOwners.filter { $0.value == pid }.map(\.key)
            for wid in toRemove {
                trackedWindowIDs.removeAll { $0 == wid }
                floatingWindowIDs.remove(wid)
                firstRefusal.removeValue(forKey: wid)
                windowOwners.removeValue(forKey: wid)
                windowElements.removeValue(forKey: wid)
            }
            Log.debug("Tiling: removed \(toRemove.count) tracked window(s) for pid=\(pid)")
        }
    }

    /// Called from the AXObserver C callback on the main run loop.
    fileprivate func handleAXNotification(_ notification: String, element: AXUIElement) {
        Log.debug("Tiling: AX notification=\(notification)")
        if notification == kAXWindowMovedNotification || notification == kAXWindowResizedNotification {
            retileQueue.async { [weak self] in self?.handleFrameChange(of: element) }
        } else if notification == kAXWindowCreatedNotification {
            // A new window often isn't in the window list (or has no final
            // frame) yet when this arrives — look again shortly after.
            scheduleRetile()
            for delay in [300, 1000] {
                retileQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    self?.scheduleRetile()
                }
            }
        } else {
            scheduleRetile()
        }
    }

    // MARK: - Retile

    /// Callable from any thread; the debounce state lives on `retileQueue`.
    private func scheduleRetile(after delay: DispatchTimeInterval = .milliseconds(50)) {
        retileQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRetile?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.performRetile()
            }
            self.pendingRetile = work
            self.retileQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func performRetile() {
        let cfg = config
        guard cfg.enabled else { return }

        let screens = Self.screenRects()
        guard !screens.isEmpty else {
            Log.debug("Tiling: no screens found")
            return
        }

        let tileableWindows = enumerateTileableWindows(config: cfg)
        Log.debug("Tiling: found \(tileableWindows.count) tileable window(s)")

        guard !tileableWindows.isEmpty else { return }

        // Append newly discovered windows — never remove existing ones (they may
        // just be on another space and will reappear when the user switches back).
        lock.lock()
        var newlyTracked: [TileableWindow] = []
        for tw in tileableWindows {
            if !trackedWindowIDs.contains(tw.windowID) {
                trackedWindowIDs.append(tw.windowID)
                windowOwners[tw.windowID] = tw.pid
                newlyTracked.append(tw)
            }
        }
        let observers = axObservers

        var newElements: [CGWindowID: AXUIElement] = [:]
        for tw in tileableWindows {
            newElements[tw.windowID] = tw.element
        }
        windowElements = newElements
        let trackedOrder = trackedWindowIDs
        lock.unlock()

        // Destroyed/minimized notifications fire on the window element, not the
        // app element, so closing one of several windows needs its own observer.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for tw in newlyTracked {
            guard let observer = observers[tw.pid] else { continue }
            for notification in [
                kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                kAXWindowMovedNotification, kAXWindowResizedNotification,
            ] {
                AXObserverAddNotification(observer, tw.element, notification as CFString, selfPtr)
            }
        }

        // A window still close to the tile we gave it a while ago took it.
        // (Right after setting, even a window something else holds shows our
        // frame — it only jumps back a moment later.)
        let settled = DispatchTime.now()
        for tw in tileableWindows where !acceptedTile.contains(tw.windowID) {
            guard let applied = appliedFrames[tw.windowID],
                  settled >= applied.time + Self.refusalRecheckDelay else { continue }
            if abs(tw.bounds.width - applied.frame.width) <= Self.sizeRefusalTolerance,
               abs(tw.bounds.height - applied.frame.height) <= Self.sizeRefusalTolerance,
               abs(tw.bounds.minX - applied.frame.minX) <= Self.sizeRefusalTolerance,
               abs(tw.bounds.minY - applied.frame.minY) <= Self.sizeRefusalTolerance {
                acceptedTile.insert(tw.windowID)
            }
        }

        // Each display shows its own space, so tile each display independently
        // with the windows currently on it.
        var windowsByScreen: [Int: Set<CGWindowID>] = [:]
        let displays = CGSSpaceService.displays()
        for tw in tileableWindows {
            guard let screenIndex = Self.screenIndex(forWindow: tw.windowID, bounds: tw.bounds, in: screens, displays: displays) else { continue }
            windowsByScreen[screenIndex, default: []].insert(tw.windowID)
        }

        let buildFn: ([CGWindowID]) -> BSPNode? = cfg.autoBalance
            ? { BSPTree.buildBalanced(windowIDs: $0) }
            : { BSPTree.build(windowIDs: $0, ratio: min(max(cfg.splitRatio, 0.1), 0.9)) }

        var applied = 0
        var refusedAny = false
        var activeKeys: Set<String> = []
        for (screenIndex, ids) in windowsByScreen {
            // Preserve the original insertion order from trackedWindowIDs.
            let orderedIDs = trackedOrder.filter { ids.contains($0) }
            guard let tree = buildFn(orderedIDs) else { continue }

            let tilingRect = screens[screenIndex].visible
            let key = "\(tilingRect)"
            activeKeys.insert(key)
            Log.debug("Tiling: screen \(screenIndex) rect=\(tilingRect) windows=\(orderedIDs)")

            // Values come straight from YAML; keep them in a range the BSP
            // math can handle.
            let maxGap = min(tilingRect.width, tilingRect.height) / 4
            screenLayouts[key] = ScreenLayout(
                windowIDs: orderedIDs,
                baseTree: tree,
                rect: tilingRect,
                innerGap: min(max(0, CGFloat(cfg.gaps.inner)), maxGap),
                outerGap: min(max(0, CGFloat(cfg.gaps.outer)), maxGap)
            )

            let frames = applyLayout(key, elements: newElements, skipping: userAdjustedWindowIDs)
            for (windowID, frame) in frames {
                guard let element = newElements[windowID],
                      let actual = accessibilityService.windowFrame(of: element) else { continue }
                // A window that got smaller than its recorded minimum can go
                // that small after all.
                if let minimum = minSizes[windowID],
                   actual.width < minimum.width - 2 || actual.height < minimum.height - 2 {
                    minSizes[windowID] = CGSize(width: min(minimum.width, actual.width), height: min(minimum.height, actual.height))
                }
                // A minimum size shows as the window staying *larger* than its
                // tile. Smaller or wildly different readings mean the window
                // was caught mid-change (zoom animation, being dragged) — and
                // nothing counts while a mouse button is held.
                let refused = (actual.width > frame.width + Self.sizeRefusalTolerance
                    || actual.height > frame.height + Self.sizeRefusalTolerance)
                    && !CGEventSource.buttonState(.combinedSessionState, button: .left)
                if refused, userRatios(onScreen: key) != nil {
                    // The user's split squeezes this window below its minimum —
                    // give up the split rather than floating the window.
                    Log.info("Tiling: wid=\(windowID) can't fit the adjusted split — resetting it")
                    setUserRatios(nil, onScreen: key)
                    refusedAny = true
                    continue
                }
                // Learn the minimum size and widen the tile next time. Float
                // only if even the widened tile doesn't fit and that is still
                // the case on a re-check at least `refusalRecheckDelay` later.
                var learnedLarger = false
                if refused {
                    let known = minSizes[windowID] ?? .zero
                    let learned = Self.learnedMinimum(known: known, requested: frame.size, actual: actual.size)
                    learnedLarger = learned.width > known.width + 1 || learned.height > known.height + 1
                    minSizes[windowID] = learned
                    if learnedLarger {
                        Log.info("Tiling: wid=\(windowID) needs at least \(learned) — widening its tile")
                    }
                }
                let now = DispatchTime.now()
                let confirmed = lock.withLock { () -> Bool in
                    guard refused, !learnedLarger else { firstRefusal[windowID] = nil; return false }
                    guard let first = firstRefusal[windowID] else { firstRefusal[windowID] = now; return false }
                    return now >= first + Self.refusalRecheckDelay
                }
                if confirmed {
                    Log.info("Tiling: wid=\(windowID) refused size \(frame.size) (got \(actual.size)) — floating it")
                    lock.withLock {
                        floatingWindowIDs.insert(windowID)
                        firstRefusal[windowID] = nil
                    }
                }
                if refused { refusedAny = true }
            }
            applied += frames.count
        }
        screenLayouts = screenLayouts.filter { activeKeys.contains($0.key) }
        publishTiledFrames()

        Log.info("Tiling: applied \(applied) window frame(s) across \(windowsByScreen.count) screen(s)")

        // Re-tile without the windows that couldn't fill their tile.
        if refusedAny { scheduleRetile(after: Self.refusalRecheckDelay) }
    }

    // MARK: - Applying Layouts

    /// Sets the frames of a screen's layout (with user ratios). Returns the
    /// frames that were applied.
    @discardableResult
    private func applyLayout(
        _ key: String,
        elements: [CGWindowID: AXUIElement]? = nil,
        skipping skipped: Set<CGWindowID> = []
    ) -> [(CGWindowID, CGRect)] {
        guard let layout = screenLayouts[key] else { return [] }
        let tree = effectiveTree(for: layout, key: key)
        let frames = tree.calculateFrames(in: layout.rect, innerGap: layout.innerGap, outerGap: layout.outerGap)
        let elements = elements ?? lock.withLock { windowElements }

        var applied: [(CGWindowID, CGRect)] = []
        for (windowID, frame) in frames {
            screenKeyForWindow[windowID] = key
            guard !skipped.contains(windowID), let element = elements[windowID] else { continue }

            if let settled = settledFrames[windowID], settled.target.isApproximately(frame),
               let current = accessibilityService.windowFrame(of: element), current.isApproximately(settled.actual) {
                applied.append((windowID, frame))
                continue
            }

            Log.debug("Tiling: setting wid=\(windowID) frame=\(frame)")
            appliedFrames[windowID] = (frame, .now())
            if let before = accessibilityService.setWindowFrame(element: element, frame: frame),
               !before.isApproximately(frame) {
                previousFrames[windowID] = before
            }
            if let after = accessibilityService.windowFrame(of: element) {
                settledFrames[windowID] = (frame, after)
            }
            // Stamp again: the moved/resized notifications for our own change
            // arrive after this call returns.
            appliedFrames[windowID] = (frame, .now())
            applied.append((windowID, frame))
        }
        return applied
    }

    /// The screen's tree with the user's ratios, then widened where a window's
    /// tile is smaller than its known minimum size.
    private func effectiveTree(for layout: ScreenLayout, key: String) -> BSPNode {
        var tree = layout.baseTree.applying(ratios: userRatios(onScreen: key) ?? [:])
        for windowID in layout.windowIDs {
            guard let minimum = minSizes[windowID] else { continue }
            let frames = tree.calculateFrames(in: layout.rect, innerGap: layout.innerGap, outerGap: layout.outerGap)
            guard let tile = frames.first(where: { $0.0 == windowID })?.1 else { continue }
            let dw = minimum.width - tile.width
            let dh = minimum.height - tile.height
            guard dw > 1 || dh > 1 else { continue }

            let edges = tree.movableEdges(of: windowID)
            var target = tile
            if dw > 1 {
                if edges.right { target.size.width += dw } else if edges.left { target.origin.x -= dw; target.size.width += dw }
            }
            if dh > 1 {
                if edges.bottom { target.size.height += dh } else if edges.top { target.origin.y -= dh; target.size.height += dh }
            }
            let changes = tree.ratios(fitting: windowID, to: target, in: layout.rect,
                                      innerGap: layout.innerGap, outerGap: layout.outerGap)
            if !changes.isEmpty { tree = tree.applying(ratios: changes) }
        }
        return tree
    }

    private func publishTiledFrames() {
        var frames: [CGWindowID: (frame: CGRect, screenKey: String)] = [:]
        for (key, layout) in screenLayouts {
            for windowID in layout.windowIDs {
                if let applied = appliedFrames[windowID] { frames[windowID] = (applied.frame, key) }
            }
        }
        lock.withLock { tiledFrames = frames.mapValues(\.frame); tiledScreenKeys = frames.mapValues(\.screenKey) }
    }

    /// Stores the split ratios that make `windowID`'s tile match `frame`.
    private func updateRatios(for windowID: CGWindowID, to frame: CGRect, key: String, base: [String: Double]? = nil) {
        guard let layout = screenLayouts[key] else { return }
        var ratios = base ?? userRatios(onScreen: key) ?? [:]
        let tree = layout.baseTree.applying(ratios: ratios)
        let changes = tree.ratios(fitting: windowID, to: frame, in: layout.rect,
                                  innerGap: layout.innerGap, outerGap: layout.outerGap)
        guard !changes.isEmpty || base != nil else { return }
        ratios.merge(changes) { $1 }
        setUserRatios(ratios, onScreen: key)
    }

    // MARK: - User Moves & Resizes

    /// A tiled window moved or resized — by us, by the user, or by the app.
    private func handleFrameChange(of element: AXUIElement) {
        guard let windowID = accessibilityService.windowID(of: element),
              let key = screenKeyForWindow[windowID], let layout = screenLayouts[key],
              lock.withLock({ resizeSession?.windowID }) != windowID,
              let frame = accessibilityService.windowFrame(of: element) else { return }

        if let held = heldFrames[windowID] {
            // Rejoin once the user moves it out of the frame it was held at.
            if !frame.isApproximately(held) && !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                releaseHeldWindow(windowID)
            }
            return
        }

        if let applied = appliedFrames[windowID], DispatchTime.now() < applied.time + Self.ownChangeWindow {
            // Normally our own change — unless the window jumped right back
            // to where it was. Twice in a row: something holds it there.
            // A window with a minimum size keeps the position we gave it and
            // only stays larger. Held means it moved back.
            let movedBack = abs(frame.minX - applied.frame.minX) > 2 || abs(frame.minY - applied.frame.minY) > 2
            if movedBack, !acceptedTile.contains(windowID),
               let previous = previousFrames[windowID], frame.isApproximately(previous),
               !applied.frame.isApproximately(previous, tolerance: Self.sizeRefusalTolerance) {
                let fights = (holdFights[windowID] ?? 0) + 1
                holdFights[windowID] = fights
                if fights >= 2 {
                    let fillsScreen = frame.isApproximately(layout.rect)
                    Log.info("Tiling: wid=\(windowID) is held at \(frame) (\(fillsScreen ? "maximized" : "macOS window tiling?")) — floating it until it's moved")
                    heldFrames[windowID] = frame
                    heldElements[windowID] = element
                    holdFights[windowID] = nil
                    lock.withLock { _ = floatingWindowIDs.insert(windowID) }
                    scheduleRetile()
                }
            }
            return
        }
        if WindowTouches.wasTouched(windowID) { return } // moved by Floe (e.g. to another desktop)
        if let applied = appliedFrames[windowID], frame.isApproximately(applied.frame) { return }
        if let settled = settledFrames[windowID]?.actual, frame.isApproximately(settled) { return }

        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            // The user is dragging the window or one of its edges; act on mouse-up.
            userAdjustedWindowIDs.insert(windowID)
            if let tiled = tiledSize(of: windowID), !frame.size.isApproximately(tiled) {
                // Edge resize: let the neighbours follow while dragging.
                updateRatios(for: windowID, to: frame, key: key)
                scheduleLiveApply(key, skipping: [windowID])
            }
        } else {
            // Moved by the app or a keyboard shortcut — snap back into the
            // layout once the window holds still (apps launching or restoring
            // state set their frame several times in a row), unless the app
            // keeps fighting the layout.
            let now = DispatchTime.now()
            var recent = (snapBacks[windowID] ?? []).filter { now < $0 + Self.snapBackWindow }
            if recent.last.map({ now >= $0 + Self.snapBackSettle }) ?? true {
                recent.append(now)
            }
            snapBacks[windowID] = recent
            if recent.count > Self.snapBackLimit {
                Log.info("Tiling: wid=\(windowID) keeps resizing itself — floating it")
                snapBacks[windowID] = nil
                lock.withLock { _ = floatingWindowIDs.insert(windowID) }
            }
            scheduleRetile(after: Self.snapBackSettle)
        }
    }

    private func scheduleLiveApply(_ key: String, skipping skipped: Set<CGWindowID>) {
        guard !liveApplyPending else { return }
        liveApplyPending = true
        retileQueue.asyncAfter(deadline: .now() + Self.liveApplyInterval) { [weak self] in
            guard let self else { return }
            self.liveApplyPending = false
            let applied = self.applyLayout(key, skipping: skipped)
            if self.learnSqueezedMinimums(applied) {
                self.applyLayout(key, skipping: skipped)
            }
            self.publishTiledFrames()
        }
    }

    private func releaseHeldWindow(_ windowID: CGWindowID) {
        Log.info("Tiling: wid=\(windowID) moved out of its held frame — tiling it again")
        heldFrames[windowID] = nil
        heldElements[windowID] = nil
        holdFights[windowID] = nil
        previousFrames[windowID] = nil
        acceptedTile.remove(windowID)
        settledFrames[windowID] = nil
        lock.withLock { _ = floatingWindowIDs.remove(windowID) }
        scheduleRetile()
    }

    /// The size the window actually has in its tile. Apps that round their
    /// size (Terminal) settle a few points off the tile we asked for, and a
    /// plain move must not look like a resize.
    private func tiledSize(of windowID: CGWindowID) -> CGSize? {
        settledFrames[windowID]?.actual.size ?? appliedFrames[windowID]?.frame.size
    }

    /// Mouse released after the user moved/resized windows: a resize keeps
    /// the new split ratios, a move dropped onto another tiled window swaps
    /// the two, anything else snaps back into the layout.
    private func finishUserInteraction(at mouse: CGPoint) {
        let adjusted = userAdjustedWindowIDs
        userAdjustedWindowIDs.removeAll()

        // A held window the user just dragged out of its frame rejoins.
        if !heldFrames.isEmpty {
            for (windowID, held) in heldFrames {
                if let element = heldElements[windowID], let frame = accessibilityService.windowFrame(of: element),
                   !frame.isApproximately(held) {
                    releaseHeldWindow(windowID)
                }
            }
        }
        guard !adjusted.isEmpty else { return }

        let elements = lock.withLock { windowElements }
        for windowID in adjusted {
            guard let key = screenKeyForWindow[windowID],
                  let element = elements[windowID],
                  let frame = accessibilityService.windowFrame(of: element),
                  let tiled = tiledSize(of: windowID) else { continue }

            if !frame.size.isApproximately(tiled) {
                updateRatios(for: windowID, to: frame, key: key)
                Log.info("Tiling: wid=\(windowID) resized by user — keeping new split")
            } else if let target = tiledWindow(at: mouse, excluding: windowID),
                      screenKeyForWindow[target] == key {
                lock.withLock {
                    if let a = trackedWindowIDs.firstIndex(of: windowID), let b = trackedWindowIDs.firstIndex(of: target) {
                        trackedWindowIDs.swapAt(a, b)
                    }
                }
                // Same tree shape with two leaves exchanged — keep the user's
                // split ratios on both screens involved.
                for (screenKey, override) in ratioOverrides {
                    ratioOverrides[screenKey]?.windowIDs = override.windowIDs.map {
                        $0 == windowID ? target : ($0 == target ? windowID : $0)
                    }
                }
                Log.info("Tiling: swapped wid=\(windowID) with wid=\(target)")
            }
        }
        scheduleRetile()
    }

    private func tiledWindow(at point: CGPoint, excluding excluded: CGWindowID) -> CGWindowID? {
        lock.withLock { tiledFrames }.first { $0.key != excluded && $0.value.contains(point) }?.key
    }

    // MARK: - ⌃-Drag Resize

    /// Called on the mouse tap's thread; returns `true` to consume the event.
    private func handleMouse(_ type: CGEventType, at location: CGPoint, flags: CGEventFlags) -> Bool {
        switch type {
        case .leftMouseDown:
            guard !Self.isReposted(flags: flags) else { return false }
            let modifiers = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            guard modifiers == .maskControl, config.enabled else { return false }
            guard let (windowID, frame, key) = topmostTiledWindow(at: location) else {
                return beginFloatingResize(at: location)
            }

            let session = ResizeSession(
                windowID: windowID, screenKey: key, startMouse: location, startFrame: frame,
                baseRatios: [:],
                movesRightEdge: location.x >= frame.midX,
                movesBottomEdge: location.y >= frame.midY,
                mouse: location
            )
            lock.withLock { resizeSession = session }
            retileQueue.async { [weak self] in
                guard let self, let layout = self.screenLayouts[key] else { return }
                let base = self.userRatios(onScreen: key) ?? [:]
                // Grab "the rim nearest the click", but an edge on the screen
                // boundary can't move — use the opposite one instead.
                let edges = layout.baseTree.movableEdges(of: windowID)
                let alone = !(edges.left || edges.right || edges.top || edges.bottom)
                self.lock.withLock {
                    guard var current = self.resizeSession, current.windowID == windowID else { return }
                    if alone, let pid = self.windowOwners[windowID] {
                        // A lone window has no split to move: resize it freely
                        // and let it float.
                        current.floatingPID = pid
                        self.floatingWindowIDs.insert(windowID)
                        self.resizeSession = current
                        return
                    }
                    current.baseRatios = base
                    if current.movesRightEdge && !edges.right && edges.left { current.movesRightEdge = false }
                    if !current.movesRightEdge && !edges.left && edges.right { current.movesRightEdge = true }
                    if current.movesBottomEdge && !edges.bottom && edges.top { current.movesBottomEdge = false }
                    if !current.movesBottomEdge && !edges.top && edges.bottom { current.movesBottomEdge = true }
                    self.resizeSession = current
                }
            }
            Log.info("Tiling: ⌃-drag resize of wid=\(windowID) started")
            return true

        case .leftMouseDragged:
            let active = lock.withLock { () -> Bool in
                guard resizeSession != nil else { return false }
                resizeSession?.mouse = location
                return true
            }
            guard active else { return false }
            retileQueue.async { [weak self] in self?.scheduleResizeApply() }
            return true

        case .leftMouseUp:
            // End the session here, synchronously: a busy retile queue must
            // not leave the next ordinary click being swallowed.
            let finished = lock.withLock { () -> ResizeSession? in
                guard var session = resizeSession else { return nil }
                session.mouse = location
                resizeSession = nil
                return session
            }
            guard let finished else {
                retileQueue.async { [weak self] in self?.finishUserInteraction(at: location) }
                return false
            }
            if hypot(location.x - finished.startMouse.x, location.y - finished.startMouse.y) < 3 {
                // A plain ⌃-click: hand it to the app (context menu) after all.
                Self.repostControlClick(at: location)
            } else {
                retileQueue.async { [weak self] in self?.applyResizeSession(finished) }
            }
            return true

        default:
            return false
        }
    }

    /// ⌃-drag on a window Floe doesn't tile (floating, fixed-size, excluded
    /// app): resize it directly from the nearest corner.
    private func beginFloatingResize(at location: CGPoint) -> Bool {
        let ownPID = Self.ownPID
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
              let info = infoList.first(where: { info in
                  guard (info[kCGWindowLayer] as? Int) == 0, (info[kCGWindowAlpha] as? Double ?? 1) > 0,
                        let b = info[kCGWindowBounds] as? [String: CGFloat] else { return false }
                  return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(location)
              }),
              let windowID = info[kCGWindowNumber] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID] as? pid_t, pid != ownPID,
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
              let b = info[kCGWindowBounds] as? [String: CGFloat] else { return false }

        let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        let session = ResizeSession(
            windowID: windowID, screenKey: "", startMouse: location, startFrame: frame, baseRatios: [:],
            movesRightEdge: location.x >= frame.midX, movesBottomEdge: location.y >= frame.midY,
            mouse: location, floatingPID: pid
        )
        lock.withLock { resizeSession = session }
        Log.info("Tiling: ⌃-drag resize of floating wid=\(windowID) started")
        return true
    }

    private func applyFloatingResize(_ session: ResizeSession, pid: pid_t) {
        if floatingResizeElement?.windowID != session.windowID {
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let element = windows.first(where: { accessibilityService.windowID(of: $0) == session.windowID }) else { return }
            floatingResizeElement = (session.windowID, element)
        }
        guard let element = floatingResizeElement?.element else { return }

        let dx = session.mouse.x - session.startMouse.x
        let dy = session.mouse.y - session.startMouse.y
        var frame = session.startFrame
        if session.movesRightEdge { frame.size.width += dx } else { frame.origin.x += dx; frame.size.width -= dx }
        if session.movesBottomEdge { frame.size.height += dy } else { frame.origin.y += dy; frame.size.height -= dy }
        guard frame.width >= 100, frame.height >= 100 else { return }
        accessibilityService.setWindowFrame(element: element, frame: frame)
    }

    private func scheduleResizeApply() {
        guard !liveApplyPending else { return }
        liveApplyPending = true
        retileQueue.asyncAfter(deadline: .now() + Self.liveApplyInterval) { [weak self] in
            guard let self else { return }
            self.liveApplyPending = false
            self.applyResizeSession()
        }
    }

    /// Marker on a ⌃-click Floe swallowed and posts again for the app.
    private static let repostTag: Int64 = 0x464C_4F45 // "FLOE"
    nonisolated(unsafe) private static var repostedUntil = DispatchTime(uptimeNanoseconds: 0)

    private static func isReposted(flags: CGEventFlags) -> Bool {
        DispatchTime.now() < repostedUntil
    }

    private static func repostControlClick(at point: CGPoint) {
        DispatchQueue.global(qos: .userInteractive).async {
            repostedUntil = .now() + .milliseconds(300)
            let source = CGEventSource(stateID: .privateState)
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
                event.flags = .maskControl
                event.setIntegerValueField(.eventSourceUserData, value: repostTag)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Resizes the dragged window's tile edge(s) to follow the mouse; the
    /// rest of the screen's layout follows.
    private func applyResizeSession(_ explicit: ResizeSession? = nil) {
        guard let session = explicit ?? lock.withLock({ resizeSession }) else { return }
        if let pid = session.floatingPID {
            applyFloatingResize(session, pid: pid)
            if explicit != nil { floatingResizeElement = nil }
            return
        }
        let dx = session.mouse.x - session.startMouse.x
        let dy = session.mouse.y - session.startMouse.y

        var frame = session.startFrame
        if session.movesRightEdge { frame.size.width += dx } else { frame.origin.x += dx; frame.size.width -= dx }
        if session.movesBottomEdge { frame.size.height += dy } else { frame.origin.y += dy; frame.size.height -= dy }
        guard frame.width >= 100, frame.height >= 100 else { return }

        updateRatios(for: session.windowID, to: frame, key: session.screenKey, base: session.baseRatios)
        let applied = applyLayout(session.screenKey)

        // Stop where a neighbour hits its minimum size: learn that size, and
        // the layout holds the edge there on every further drag step instead
        // of jumping back and forth.
        if learnSqueezedMinimums(applied, except: session.windowID) {
            applyLayout(session.screenKey)
        }
        publishTiledFrames()
    }

    /// Only the dimension a window refused tells us its minimum — the other
    /// one is just its current size.
    private static func learnedMinimum(known: CGSize, requested: CGSize, actual: CGSize) -> CGSize {
        CGSize(
            width: actual.width > requested.width + roundingTolerance ? max(known.width, actual.width) : known.width,
            height: actual.height > requested.height + roundingTolerance ? max(known.height, actual.height) : known.height
        )
    }

    /// Records the minimum size of windows that stayed larger than the tile
    /// they were just given. Returns whether anything new was learned.
    private func learnSqueezedMinimums(_ applied: [(CGWindowID, CGRect)], except dragged: CGWindowID? = nil) -> Bool {
        let elements = lock.withLock { windowElements }
        var learned = false
        for (windowID, requested) in applied where windowID != dragged {
            guard let element = elements[windowID], let actual = accessibilityService.windowFrame(of: element),
                  actual.width > requested.width + Self.roundingTolerance
                    || actual.height > requested.height + Self.roundingTolerance else { continue }
            let known = minSizes[windowID] ?? .zero
            let size = Self.learnedMinimum(known: known, requested: requested.size, actual: actual.size)
            if size.width > known.width + 1 || size.height > known.height + 1 {
                minSizes[windowID] = size
                learned = true
                Log.info("Tiling: wid=\(windowID) can't get smaller than \(size) — holding the edge there")
            }
        }
        return learned
    }

    /// The tiled window under the cursor, unless a floating window covers it.
    private func topmostTiledWindow(at point: CGPoint) -> (CGWindowID, CGRect, String)? {
        let (frames, keys) = lock.withLock { (tiledFrames, tiledScreenKeys) }
        guard frames.values.contains(where: { $0.contains(point) }),
              let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }
        let owners = lock.withLock { windowOwners }
        for info in infoList {
            guard (info[kCGWindowLayer] as? Int) == 0,
                  (info[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let b = info[kCGWindowBounds] as? [String: CGFloat] else { continue }
            let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard bounds.contains(point) else { continue }
            if let frame = frames[windowID], let key = keys[windowID] {
                return (windowID, frame, key)
            }
            // Popovers, tab-drag and status windows of the tiled app itself
            // sit above its window — they belong to the same tile.
            let pid = info[kCGWindowOwnerPID] as? pid_t
            if let tiled = frames.first(where: { owners[$0.key] == pid && $0.value.contains(point) }),
               let key = keys[tiled.key] {
                return (tiled.key, tiled.value, key)
            }
            return nil
        }
        return nil
    }

    // MARK: - Screens

    /// Full and visible (menu bar / Dock excluded) rects of every screen,
    /// in CG global coordinates (origin top-left of the primary screen).
    private static func screenRects() -> [(full: CGRect, visible: CGRect, uuid: String?)] {
        // Cocoa coordinates are flipped relative to the *primary* screen
        // (the one at origin 0,0), not the screen being converted.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }

        func flip(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }
        let monitors = Monitors.ordered()
        return NSScreen.screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return (flip(screen.frame), flip(screen.visibleFrame), monitors.first { $0.displayID == id }?.uuid)
        }
    }

    /// The screen showing the window's space. A window moved to another
    /// display's desktop keeps its old frame, so its position alone can point
    /// at the wrong screen.
    private static func screenIndex(
        forWindow windowID: CGWindowID,
        bounds: CGRect,
        in screens: [(full: CGRect, visible: CGRect, uuid: String?)],
        displays: [ManagedDisplay]
    ) -> Int? {
        let spaces = CGSSpaceService.spaces(forWindow: windowID)
        if let display = displays.first(where: { spaces.contains($0.currentSpace) }), display.identifier != "Main",
           let index = screens.firstIndex(where: { $0.uuid?.caseInsensitiveCompare(display.identifier) == .orderedSame }) {
            return index
        }
        return screenIndex(for: bounds, in: screens)
    }

    /// The screen containing the window's center, falling back to the one
    /// it overlaps most.
    private static func screenIndex(for bounds: CGRect, in screens: [(full: CGRect, visible: CGRect, uuid: String?)]) -> Int? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let idx = screens.firstIndex(where: { $0.full.contains(center) }) {
            return idx
        }
        let overlaps = screens.enumerated().map { i, screen -> (Int, CGFloat) in
            let r = screen.full.intersection(bounds)
            return (i, r.isNull ? 0 : r.width * r.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    // MARK: - Window Enumeration

    private struct TileableWindow {
        let windowID: CGWindowID
        let pid: pid_t
        let ownerName: String?
        let element: AXUIElement
        let bounds: CGRect
    }

    private func enumerateTileableWindows(config: TilingConfig) -> [TileableWindow] {
        let excludedApps = Set(config.rules.filter { !$0.tiled }.map(\.app))

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            Log.debug("Tiling: CGWindowListCopyWindowInfo returned nil")
            return []
        }

        // Build a set of PIDs with .regular activation policy (real user-facing apps).
        // This excludes wallpaper engines, menu bar utilities, background agents, etc.
        let regularPIDs: Set<pid_t> = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )

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
            guard regularPIDs.contains(pid) else { continue }

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

        let floating = lock.withLock { floatingWindowIDs }

        // For each PID, match AX windows to CG windows by window ID (falling
        // back to position+size if the private lookup fails).
        var result: [TileableWindow] = []

        for (pid, cgWindows) in cgWindowsByPID {
            let axWindows = accessibilityService.windows(for: pid)
            let ownerName = NSRunningApplication(processIdentifier: pid)?.localizedName

            var unmatchedCG = cgWindows
            for (axElement, axFrame) in axWindows {
                guard accessibilityService.isStandardWindow(axElement),
                      accessibilityService.isResizable(axElement),
                      !accessibilityService.isFullScreen(axElement) else { continue }

                let index: Int?
                if let windowID = accessibilityService.windowID(of: axElement) {
                    index = unmatchedCG.firstIndex { $0.windowID == windowID }
                } else {
                    index = unmatchedCG.firstIndex { cg in
                        abs(cg.bounds.origin.x - axFrame.origin.x) < 5 &&
                        abs(cg.bounds.origin.y - axFrame.origin.y) < 5 &&
                        abs(cg.bounds.width - axFrame.width) < 5 &&
                        abs(cg.bounds.height - axFrame.height) < 5
                    }
                }
                guard let index else { continue }

                let cg = unmatchedCG.remove(at: index)
                guard !floating.contains(cg.windowID) else { continue }
                result.append(TileableWindow(
                    windowID: cg.windowID,
                    pid: pid,
                    ownerName: ownerName,
                    element: axElement,
                    bounds: cg.bounds
                ))
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

private extension CGRect {
    func isApproximately(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && size.isApproximately(other.size, tolerance: tolerance)
    }
}

private extension CGSize {
    func isApproximately(_ other: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
