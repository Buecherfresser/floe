import AppKit
import ApplicationServices

/// Opens the configured apps' new windows on their own desktop — the first
/// window after launch and every one after. Windows that exist when Floe
/// starts stay where they are, and so does a window once the user has moved
/// it: each window is placed only once.
final class AppDesktopService: @unchecked Sendable {

    private let accessibilityService: AccessibilityService
    private let spacesService: SpacesService

    private let lock = NSLock()
    private var config: AppDesktopsConfig
    private var axObservers: [pid_t: AXObserver] = [:]
    /// Windows already placed (or there before we looked), with their owner.
    private var seenWindows: [CGWindowID: pid_t] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    /// A launching app's first window can appear before its AX observer is
    /// registered, so look again a few times after launch.
    private static let launchChecks: [DispatchTimeInterval] = [.milliseconds(300), .seconds(1), .milliseconds(2500)]

    init(accessibilityService: AccessibilityService, spacesService: SpacesService, config: AppDesktopsConfig) {
        self.accessibilityService = accessibilityService
        self.spacesService = spacesService
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        Log.info("AppDesktops: starting with \(config.apps.count) app(s)")
        registerWorkspaceObservers()
        observeRunningApps()
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(nc.removeObserver)
        workspaceObservers.removeAll()
        lock.withLock {
            for pid in axObservers.keys { removeObserverLocked(pid) }
            seenWindows.removeAll()
        }
    }

    func update(config newConfig: AppDesktopsConfig) {
        lock.withLock { config = newConfig }
        // Stop watching apps that were removed; start on ones that were added.
        let wanted = Set(runningConfiguredApps().map(\.processIdentifier))
        lock.withLock {
            for pid in axObservers.keys where !wanted.contains(pid) { removeObserverLocked(pid) }
        }
        observeRunningApps()
    }

    // MARK: - Observation

    private func registerWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.desktop(for: app) != nil else { return }
            self.addObserver(for: app.processIdentifier)
            for delay in Self.launchChecks {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.placeNewWindows(of: app.processIdentifier)
                }
            }
        }
        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            self.lock.withLock {
                self.removeObserverLocked(pid)
                self.seenWindows = self.seenWindows.filter { $0.value != pid }
            }
        }
        workspaceObservers = [launch, terminate]
    }

    /// Watches configured apps that are already running. Their current
    /// windows count as placed.
    private func observeRunningApps() {
        for app in runningConfiguredApps() {
            let pid = app.processIdentifier
            guard !lock.withLock({ axObservers[pid] != nil }) else { continue }
            let existing = windows(of: pid).map(\.id)
            lock.withLock { for id in existing { seenWindows[id] = pid } }
            addObserver(for: pid)
        }
    }

    private func addObserver(for pid: pid_t) {
        if lock.withLock({ axObservers[pid] != nil }) { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, appDesktopObserverCallback, &observer) == .success, let observer else {
            Log.error("AppDesktops: could not observe pid \(pid)")
            return
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        lock.withLock { axObservers[pid] = observer }
    }

    /// Caller holds `lock`.
    private func removeObserverLocked(_ pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func windowCreated(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        placeNewWindows(of: pid)
    }

    // MARK: - Placement

    private func placeNewWindows(of pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), let desktop = desktop(for: app) else { return }
        let bundleID = app.bundleIdentifier ?? ""

        for window in windows(of: pid) {
            let isNew = lock.withLock { () -> Bool in
                guard seenWindows[window.id] == nil else { return false }
                seenWindows[window.id] = pid
                return true
            }
            guard isNew else { continue }
            guard !spacesService.isPulling(bundleID: bundleID) else {
                Log.info("AppDesktops: \(bundleID) window \(window.id) is being pulled, leaving it")
                continue
            }
            // The user opened it if the app is in front; otherwise it opened
            // by itself and shouldn't drag the user along.
            let follow = app.isActive
            Log.info("AppDesktops: \(bundleID) opened window \(window.id), sending it to desktop \(desktop) (follow=\(follow))")
            spacesService.openOnDesktop(windowID: window.id, pid: pid, element: window.element, desktop: desktop, follow: follow)
        }
    }

    private func windows(of pid: pid_t) -> [(id: CGWindowID, element: AXUIElement)] {
        accessibilityService.windows(for: pid).compactMap { element, _ in
            guard accessibilityService.isStandardWindow(element),
                  let id = accessibilityService.windowID(of: element) else { return nil }
            return (id, element)
        }
    }

    private func desktop(for app: NSRunningApplication) -> Int? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return lock.withLock { config.enabled ? config.desktop(forBundleID: bundleID) : nil }
    }

    private func runningConfiguredApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && desktop(for: $0) != nil }
    }
}

private func appDesktopObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<AppDesktopService>.fromOpaque(refcon).takeUnretainedValue().windowCreated(element)
}
