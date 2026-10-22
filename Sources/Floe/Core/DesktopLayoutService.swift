import AppKit
import CoreGraphics
import Foundation

/// Keeps desktop numbers stable across monitor changes.
///
/// For each monitor count the config defines how many desktops every monitor
/// gets (desktop numbers run monitor by monitor, see `Monitors.ordered()`).
/// Floe remembers which desktop number every window lives on. When monitors
/// are connected or disconnected it:
///
/// 1. adds missing desktops through Mission Control,
/// 2. moves every window back to its desktop number — windows whose desktop
///    doesn't exist in the smaller layout are parked on the last desktop and
///    return once it exists again,
/// 3. removes surplus (now empty) desktops through Mission Control.
///
/// Desktops are only ever created/removed via Mission Control so the Dock's
/// model stays consistent; windows are moved with the bridged SkyLight move.
final class DesktopLayoutService: @unchecked Sendable {

    /// Time to let macOS finish rearranging spaces after a display change
    /// (and to ride out short blips such as a monitor switching inputs).
    private static let reconcileDelay: TimeInterval = 3.0
    private static let homeRecordInterval: TimeInterval = 2.0

    private let queue = DispatchQueue(label: "com.jonasdrechsel.floe.desktop-layouts", qos: .utility)

    // All state below is only touched on `queue`.
    private var config: DesktopLayoutsConfig
    /// Desktop number each window belongs on.
    private var homes: [CGWindowID: Int] = [:]
    /// Windows Floe parked on a fallback desktop because their home desktop
    /// doesn't exist in the current layout, and where they were parked.
    private var parked: [CGWindowID: Int] = [:]
    /// Monitors the current homes were recorded against. Recording pauses
    /// while the connected set differs (a change is pending).
    private var recordedMonitorUUIDs: [String] = []
    private var displaysChanging = false
    private var pendingReconcile: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var didInitialRecord = false
    private var reconcileRetries = 0

    /// Called after windows were moved between desktops (they produce no
    /// Accessibility notification, so tiling needs a nudge).
    private let onWindowsMoved: @Sendable () -> Void

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    init(config: DesktopLayoutsConfig, onWindowsMoved: @escaping @Sendable () -> Void) {
        self.config = config
        self.onWindowsMoved = onWindowsMoved
    }

    // MARK: - Lifecycle

    func start() {
        Log.info("Desktops: starting")
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())

        queue.async { [self] in
            recordedMonitorUUIDs = Monitors.ordered().map(\.uuid)
            recordHomes()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.homeRecordInterval, repeating: Self.homeRecordInterval)
            timer.setEventHandler { [weak self] in self?.recordHomes() }
            timer.resume()
            self.timer = timer

            // Bring the desktops in line with the layout right away (e.g. after
            // enabling the feature or launching with a different monitor setup).
            scheduleReconcile(after: 0.5)
        }
    }

    func stop() {
        Log.info("Desktops: stopping")
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        queue.sync {
            timer?.cancel()
            timer = nil
            pendingReconcile?.cancel()
            pendingReconcile = nil
        }
    }

    func update(config newConfig: DesktopLayoutsConfig) {
        queue.async { [self] in
            let layoutsChanged = newConfig.layouts != config.layouts
            config = newConfig
            // Wait for the user to finish clicking the Settings steppers —
            // every reconcile flashes Mission Control.
            if layoutsChanged { scheduleReconcile(after: 2.0) }
        }
    }

    /// Apply the layout for the current monitors now (Settings "Apply now").
    func applyNow() {
        queue.async { [self] in scheduleReconcile(after: 0) }
    }

    // MARK: - Display Changes

    fileprivate func displayConfigurationChanged(_ flags: CGDisplayChangeSummaryFlags) {
        queue.async { [self] in
            if flags.contains(.beginConfigurationFlag) {
                // Freeze homes before the Dock starts moving spaces around.
                displaysChanging = true
                return
            }
            scheduleReconcile(after: Self.reconcileDelay)
        }
    }

    private func scheduleReconcile(after delay: TimeInterval) {
        pendingReconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        pendingReconcile = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Home Tracking

    private func recordHomes() {
        let monitorList = Monitors.ordered()
        let monitors = monitorList.map(\.uuid)
        guard !displaysChanging, monitors == recordedMonitorUUIDs else { return }

        // Desktop numbers only mean the same thing while every monitor has its
        // layout's desktop count — e.g. after removing a desktop by hand,
        // every number after it would shift. The very first snapshot is taken
        // regardless; it's what the layout gets applied from.
        if didInitialRecord, let layout = config.layout(forMonitorCount: monitorList.count) {
            let counts = monitorList.map { display(for: $0)?.userSpaceIDs.count ?? -1 }
            guard counts == layout.desktops else { return }
        }
        didInitialRecord = true

        let desktopForSpace = desktopNumbers(monitors: monitorList)
        guard !desktopForSpace.isEmpty else { return }

        let windows = Self.managedWindowIDs()
        for windowID in windows {
            let spaces = CGSSpaceService.spaces(forWindow: windowID)
            // Sticky windows (all spaces) and minimized windows have no single home.
            guard spaces.count == 1, let desktop = desktopForSpace[spaces[0]] else { continue }

            if let parkedOn = parked[windowID], parkedOn == desktop {
                continue // still where Floe parked it — keep the real home
            }
            parked[windowID] = nil
            homes[windowID] = desktop
        }

        // Forget only windows that are gone entirely — a window can briefly
        // drop out of the filtered list (resizing, app state changes).
        let alive = Self.allWindowIDs()
        homes = homes.filter { alive.contains($0.key) }
        parked = parked.filter { alive.contains($0.key) }
    }

    // MARK: - Reconcile

    private func reconcile() {
        pendingReconcile = nil
        defer {
            displaysChanging = false
            recordedMonitorUUIDs = Monitors.ordered().map(\.uuid)
        }
        guard config.enabled else { return }

        let monitors = Monitors.ordered()
        guard let layout = config.layout(forMonitorCount: monitors.count) else {
            Log.info("Desktops: no layout for \(monitors.count) monitor(s), leaving desktops as they are")
            return
        }
        guard monitorsHaveOwnSpaces(monitors) else {
            Log.error("Desktops: \"Displays have separate Spaces\" is off — desktop layouts need it")
            return
        }

        Log.info("Desktops: applying layout \(layout.desktops) for \(monitors.count) monitor(s)")

        // 1. Add missing desktops.
        let missing = monitors.enumerated().map { index, monitor in
            max(0, layout.desktops[index] - (display(for: monitor)?.userSpaceIDs.count ?? 0))
        }
        if missing.contains(where: { $0 > 0 }) {
            MissionControl.perform { session in
                for (index, monitor) in monitors.enumerated() {
                    for _ in 0..<missing[index] {
                        session.addDesktop(onDisplayContaining: monitor.center)
                    }
                }
            }
        }

        // 2. Move windows to their desktop numbers.
        let target = targetSpaces(for: layout, monitors: monitors)
        guard target.count == layout.totalDesktops else {
            Log.error("Desktops: expected \(layout.totalDesktops) desktops, found \(target.count) — not moving windows")
            if reconcileRetries < 2 {
                reconcileRetries += 1
                scheduleReconcile(after: Self.reconcileDelay)
            }
            return
        }
        reconcileRetries = 0
        moveWindowsHome(target: target, layout: layout, monitors: monitors)
        onWindowsMoved()

        // 3. Remove surplus desktops, highest index first so indices stay valid.
        let surplus = monitors.enumerated().compactMap { index, monitor -> (Monitor, [Int])? in
            guard let display = display(for: monitor) else { return nil }
            let extra = display.userSpaceIDs.dropFirst(layout.desktops[index])
            let indices = extra.compactMap { display.missionControlIndex(of: $0) }
            return indices.isEmpty ? nil : (monitor, indices.sorted(by: >))
        }
        if !surplus.isEmpty {
            MissionControl.perform { session in
                for (monitor, indices) in surplus {
                    for index in indices {
                        session.removeDesktop(onDisplayContaining: monitor.center, at: index)
                    }
                }
            }
        }

        onWindowsMoved()
        Log.info("Desktops: layout applied")
    }

    /// Desktop number → space, for the given layout on the current displays.
    private func targetSpaces(for layout: DesktopLayout, monitors: [Monitor]) -> [Int: CGSSpaceID] {
        var result: [Int: CGSSpaceID] = [:]
        for (index, monitor) in monitors.enumerated() {
            guard let range = layout.desktopRange(forMonitor: index),
                  let display = display(for: monitor) else { continue }
            for (offset, space) in display.userSpaceIDs.prefix(layout.desktops[index]).enumerated() {
                result[range.lowerBound + offset] = space
            }
        }
        return result
    }

    private func moveWindowsHome(target: [Int: CGSSpaceID], layout: DesktopLayout, monitors: [Monitor]) {
        let fallbackDesktop = layout.totalDesktops
        let keptSpaces = Set(target.values)
        let userSpaces = Set(CGSSpaceService.userSpaceIDs())

        for windowID in Self.managedWindowIDs() {
            let current = CGSSpaceService.spaces(forWindow: windowID)
            // Leave sticky, minimized and fullscreen-app windows alone.
            guard current.count == 1, userSpaces.contains(current[0]) else {
                if homes[windowID] != nil {
                    Log.info("Desktops: not moving window \(windowID) (spaces \(current))")
                }
                continue
            }

            let desktop: Int
            if let home = homes[windowID] {
                if home <= fallbackDesktop {
                    desktop = home
                    parked[windowID] = nil
                } else {
                    desktop = fallbackDesktop
                    parked[windowID] = fallbackDesktop
                }
            } else if !keptSpaces.contains(current[0]) {
                // Unknown window on a desktop that is about to be removed:
                // keep it on the last desktop of the same monitor.
                guard let monitorIndex = monitors.firstIndex(where: { display(for: $0)?.userSpaceIDs.contains(current[0]) ?? false }),
                      let range = layout.desktopRange(forMonitor: monitorIndex) else { continue }
                desktop = range.upperBound
                homes[windowID] = desktop
            } else {
                continue
            }

            guard let space = target[desktop], space != current[0] else { continue }
            Log.info("Desktops: moving window \(windowID) to desktop \(desktop)")
            CGSSpaceService.moveWindow(windowID, toSpace: space)
        }
    }

    // MARK: - Helpers

    private func display(for monitor: Monitor) -> ManagedDisplay? {
        CGSSpaceService.displays().first { $0.identifier.caseInsensitiveCompare(monitor.uuid) == .orderedSame }
    }

    private func monitorsHaveOwnSpaces(_ monitors: [Monitor]) -> Bool {
        monitors.allSatisfy { display(for: $0) != nil }
    }

    /// Space → desktop number. With a layout, each monitor's desktops are
    /// numbered from where its range starts, so an extra desktop on one
    /// monitor doesn't shift the numbers on the next. Desktops beyond a
    /// monitor's count get no number: they're about to be removed.
    private func desktopNumbers(monitors: [Monitor]) -> [CGSSpaceID: Int] {
        guard let layout = config.layout(forMonitorCount: monitors.count) else {
            return Dictionary(
                CGSSpaceService.userSpaceIDs().enumerated().map { ($1, $0 + 1) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        var numbers: [CGSSpaceID: Int] = [:]
        for (space, desktop) in targetSpaces(for: layout, monitors: monitors).map({ ($1, $0) }) {
            numbers[space] = desktop
        }
        return numbers
    }

    private static func allWindowIDs() -> Set<CGWindowID> {
        let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return Set(infoList.compactMap { $0[kCGWindowNumber] as? CGWindowID })
    }

    /// Normal-layer windows of regular apps, on any space.
    private static func managedWindowIDs() -> [CGWindowID] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        let regularPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
        return infoList.compactMap { info in
            guard (info[kCGWindowLayer] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID] as? pid_t, pid != ownPID, regularPIDs.contains(pid),
                  let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let bounds = info[kCGWindowBounds] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 50, (bounds["Height"] ?? 0) >= 50 else { return nil }
            return windowID
        }
    }
}

private extension Monitor {
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

private func displayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    Unmanaged<DesktopLayoutService>.fromOpaque(userInfo).takeUnretainedValue()
        .displayConfigurationChanged(flags)
}
