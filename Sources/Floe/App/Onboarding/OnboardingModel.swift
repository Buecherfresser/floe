import AppKit
import Combine

/// Walks the user through setup: one step at a time, moving on by itself
/// as soon as macOS reports that a step is done.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Equatable {
        case welcome, accessibility, checks, desktops, practice, apps, done
    }

    /// Setting up desktops for a Mac that has only one.
    enum DesktopSetup: Equatable {
        case offer, working, failed
    }

    /// Where the user is in the practice step: jump away, then come back.
    enum Practice: Equatable {
        case goThere, comeBack, finished
    }

    /// The app switcher step: offer it, then jump to Finder and pull its window over.
    enum AppSwitch: Equatable {
        case offer, jump, pull, finished
    }

    static let finderID = "com.apple.finder"

    /// Whether the user got through the welcome. It keeps the old
    /// first-launch key, so existing installs don't see the welcome again.
    static var isFinished: Bool { UserDefaults.standard.bool(forKey: finishedKey) }
    private static let finishedKey = "hasLaunchedBefore"

    @Published private(set) var step: Step = .welcome
    @Published private(set) var bear: BearClip = .wave
    @Published private(set) var issues: [SystemIssue] = []
    @Published private(set) var waitingForAccess = false
    @Published private(set) var justGranted = false
    @Published private(set) var practice: Practice = .goThere
    @Published private(set) var appSwitch: AppSwitch = .offer
    @Published private(set) var desktopSetup: DesktopSetup = .offer
    /// Whether desktop layouts stay on after the welcome set up the desktops.
    @Published var keepDesktopLayouts = true
    /// More than one desktop exists, so the desktop shortcuts do something.
    @Published private(set) var hasDesktops = false
    @Published private(set) var confetti = 0
    @Published var opensAtLogin = LoginItem.isEnabled
    /// The shortcuts for desktop 2 and back to 1, when both desktops exist.
    /// The welcome teaches the built-in defaults, which a new install has.
    private(set) var practiceKeys: (there: String, back: String)?
    /// The default modifiers for switching desktops and sending windows there.
    private(set) var desktopModifiers: (focus: String?, send: String?)

    private let accessibility: AccessibilityService
    private let core: FloeCore
    private let configManager: ConfigManager
    private var timer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private let needsDesktops: Bool

    init(accessibility: AccessibilityService, core: FloeCore, configManager: ConfigManager) {
        self.accessibility = accessibility
        self.core = core
        self.configManager = configManager
        issues = SystemCheck.issues()
        let hasDesktops = CGSSpaceService.spaceID(forIndex: 2) != nil
        // A new Mac has one desktop, and the desktop shortcuts need more.
        needsDesktops = !hasDesktops && Configuration.default.hotkeys.enabled
        self.hasDesktops = hasDesktops
        practiceKeys = Self.practiceKeys(in: .default)
        desktopModifiers = Self.desktopModifiers(in: .default)
    }

    /// The steps this Mac needs, in order. Steps with nothing to do are left out.
    var steps: [Step] {
        var steps: [Step] = [.welcome, .accessibility]
        if !issues.isEmpty || step == .checks { steps.append(.checks) }
        if needsDesktops { steps.append(.desktops) }
        if practiceKeys != nil || needsDesktops { steps.append(.practice) }
        steps.append(.apps)
        steps.append(.done)
        return steps
    }

    var progress: Double {
        let all = steps
        guard let index = all.firstIndex(of: step) else { return 0 }
        return Double(index) / Double(max(all.count - 1, 1))
    }

    private static func practiceKeys(in config: Configuration) -> (there: String, back: String)? {
        let hotkeys = config.hotkeys
        guard hotkeys.enabled,
              let there = hotkeys.bindings.first(where: { $0.action == .focusSpace(2) }),
              let back = hotkeys.bindings.first(where: { $0.action == .focusSpace(1) }),
              CGSSpaceService.spaceID(forIndex: 2) != nil else { return nil }
        return (HotkeyFormat.describe(there.hotkey), HotkeyFormat.describe(back.hotkey))
    }

    private static func desktopModifiers(in config: Configuration) -> (focus: String?, send: String?) {
        guard config.hotkeys.enabled else { return (nil, nil) }
        func modifiers(for actions: [Action]) -> String? {
            guard let binding = config.hotkeys.bindings.first(where: { actions.contains($0.action) }) else { return nil }
            var hotkey = binding.hotkey
            hotkey.key = "1"
            return String(HotkeyFormat.describe(hotkey).dropLast())
        }
        return (modifiers(for: [.focusSpace(1)]),
                modifiers(for: [.moveWindowToSpace(1), .moveWindowToSpaceAndReturn(1)]))
    }

    var appSwitcherOn: Bool { configManager.config.appSwitcher.enabled }

    /// How many desktops desktop layouts give this Mac's monitor setup.
    var layoutDesktopCount: Int? {
        configManager.config.desktopLayouts.layout(forMonitorCount: NSScreen.screens.count)?.totalDesktops
    }

    /// Finder's letter for the app switcher, from the config or the defaults.
    var finderKey: String {
        let apps = configManager.config.appSwitcher.apps + AppSwitcherConfig.default.apps
        return apps.first { $0.bundleID == Self.finderID }?.key.uppercased() ?? "F"
    }

    // MARK: - Moving through the steps

    func next() {
        let all = steps
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return }
        enter(all[index + 1])
    }

    private func enter(_ next: Step) {
        stopWatching()
        step = next
        switch next {
        case .welcome:
            bear = .wave
        case .accessibility:
            accessibility.checkPermission()
            if accessibility.isTrusted {
                startCore()
                self.next()
            } else {
                bear = .point
            }
        case .checks:
            issues = SystemCheck.issues()
            if issues.isEmpty {
                self.next()
            } else {
                bear = .oops
                watchIssues()
            }
        case .desktops:
            if hasDesktops {
                self.next()
            } else {
                desktopSetup = .offer
                bear = .point
            }
        case .practice:
            practice = .goThere
            bear = .point
            watchSpaces()
        case .apps:
            bear = .point
            if appSwitcherOn {
                appSwitch = .jump
                watchApps()
            } else {
                appSwitch = .offer
            }
        case .done:
            bear = .cheer
            confetti += 1
        }
    }

    // MARK: - Accessibility

    func requestAccess() {
        accessibility.promptForPermission()
        waitingForAccess = true
        bear = .wait
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccess() }
        }
    }

    private func checkAccess() {
        accessibility.checkPermission()
        guard accessibility.isTrusted else { return }
        timer?.invalidate()
        timer = nil
        startCore()
        waitingForAccess = false
        justGranted = true
        bear = .cheer
        confetti += 1
        // The user is in System Settings; bring the bear back to the front.
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.step == .accessibility else { return }
            self.next()
        }
    }

    // MARK: - Checks

    func openSettings(for issue: SystemIssue) {
        guard let url = issue.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func watchIssues() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.issues.count
                self.issues = SystemCheck.issues()
                if self.issues.count < before { self.bear = .cheer }
                if self.issues.isEmpty {
                    self.stopWatching()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard self?.step == .checks else { return }
                        self?.next()
                    }
                }
            }
        }
    }

    // MARK: - Desktops

    /// Turns on desktop layouts, which create the desktops through Mission
    /// Control, and waits for them. Layouts stay on only if the user keeps them.
    func setUpDesktops() {
        let wasOn = configManager.config.desktopLayouts.enabled
        desktopSetup = .working
        bear = .wait
        configManager.update { $0.desktopLayouts.enabled = true }

        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let created = CGSSpaceService.spaceID(forIndex: 2) != nil
                guard created || Date().timeIntervalSince(started) > 20 else { return }
                self.stopWatching()
                if !self.keepDesktopLayouts && !wasOn {
                    self.configManager.update { $0.desktopLayouts.enabled = false }
                }
                // Mission Control took the focus.
                NSApp.activate()
                guard created else {
                    self.desktopSetup = .failed
                    self.bear = .idle
                    return
                }
                self.hasDesktops = true
                self.practiceKeys = Self.practiceKeys(in: .default)
                self.bear = .cheer
                self.confetti += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard self?.step == .desktops else { return }
                    self?.next()
                }
            }
        }
    }

    /// Moves on without desktops, past the practice that needs them.
    func skipDesktops() {
        enter(.apps)
    }

    // MARK: - Practice

    private func watchSpaces() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    private func spaceChanged() {
        switch practice {
        case .goThere:
            practice = .comeBack
            bear = .cheer
        case .comeBack:
            practice = .finished
            bear = .cheer
            confetti += 1
            stopWatching()
            // Switching desktops hands focus to an app there; take it back.
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard self?.step == .practice else { return }
                self?.next()
            }
        case .finished:
            break
        }
    }

    // MARK: - App switcher

    /// Turns on the app switcher like Settings does, including the 🌐 key
    /// setting, and makes sure Finder has its letter.
    func enableAppSwitcher() {
        FnKeySetting.disable()
        configManager.update { config in
            config.appSwitcher.enabled = true
            if !config.appSwitcher.apps.contains(where: { $0.bundleID == Self.finderID }),
               let finder = AppSwitcherConfig.default.apps.first(where: { $0.bundleID == Self.finderID }) {
                config.appSwitcher.apps.append(finder)
            }
        }
        appSwitch = .jump
        bear = .point
        watchApps()
    }

    private func watchApps() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundleID) }
        }
    }

    /// Activation only fires on a change, so a second Finder activation means
    /// the user came back here and pulled Finder over.
    private func appActivated(_ bundleID: String?) {
        guard bundleID == Self.finderID else { return }
        switch appSwitch {
        case .jump:
            appSwitch = .pull
            bear = .cheer
        case .pull:
            appSwitch = .finished
            bear = .cheer
            confetti += 1
            stopWatching()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard self?.step == .apps else { return }
                NSApp.activate()
                self?.next()
            }
        case .offer, .finished:
            break
        }
    }

    // MARK: - Done

    func setOpensAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        opensAtLogin = LoginItem.isEnabled
    }

    func finish() {
        stopWatching()
        startCore()
        UserDefaults.standard.set(true, forKey: Self.finishedKey)
    }

    private func startCore() {
        if !core.isRunning { core.start() }
    }

    /// Shows a step as it looks at one moment, without asking macOS for
    /// anything. For rendering the steps from the diagnostics mode.
    func preview(_ step: Step, bear: BearClip, practice: Practice = .goThere, appSwitch: AppSwitch = .offer,
                 desktopSetup: DesktopSetup = .offer, waiting: Bool = false, granted: Bool = false,
                 issues: [SystemIssue]? = nil) {
        if let issues { self.issues = issues }
        self.desktopSetup = desktopSetup
        self.appSwitch = appSwitch
        self.step = step
        self.bear = bear
        self.practice = practice
        waitingForAccess = waiting
        justGranted = granted
        if practiceKeys == nil { practiceKeys = ("⌃2", "⌃1") }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
    }
}
