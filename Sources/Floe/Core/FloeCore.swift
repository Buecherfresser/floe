import Foundation
import Combine

@MainActor
final class FloeCore: ObservableObject {
    let configManager: ConfigManager
    let accessibilityService: AccessibilityService

    private var focusFollowsMouse: FocusFollowsMouse?
    private var hotkeyService: HotkeyService?
    private var tilingService: TilingService?
    private var desktopLayoutService: DesktopLayoutService?
    private let spacesService: SpacesService
    private lazy var actionDispatcher = ActionDispatcher(spacesService: spacesService)
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var isRunning = false
    /// Set by Pause in the menu. Config changes must not quietly restart
    /// everything while paused.
    private var isPaused = false
    /// Config changes only apply once `start()` ran (Accessibility granted).
    private var hasStarted = false
    @Published private(set) var hotkeysActive = false

    init(configManager: ConfigManager, accessibilityService: AccessibilityService) {
        self.configManager = configManager
        self.accessibilityService = accessibilityService
        self.spacesService = SpacesService(accessibilityService: accessibilityService)
        actionDispatcher.configManager = configManager

        configManager.$config
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                guard let self, self.hasStarted, !self.isPaused else { return }
                self.applyConfig(config)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard accessibilityService.isTrusted else {
            Log.error("Core: cannot start — accessibility not trusted")
            return
        }
        Log.info("Core: starting")
        hasStarted = true
        isPaused = false
        applyConfig(configManager.config)
        isRunning = true
    }

    /// Pauses everything until `start()`.
    func pause() {
        isPaused = true
        stop()
    }

    func stop() {
        focusFollowsMouse?.stop()
        focusFollowsMouse = nil
        stopHotkeys()
        stopTiling()
        stopDesktopLayouts()
        isRunning = false
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    private func applyConfig(_ config: Configuration) {
        Log.isEnabled = config.debug
        Log.info("Core: applyConfig debug=\(config.debug) ffm.enabled=\(config.focusFollowsMouse.enabled) hotkeys.enabled=\(config.hotkeys.enabled) trusted=\(accessibilityService.isTrusted)")

        applyFocusFollowsMouse(config)
        applyHotkeys(config)
        applyTiling(config)
        applyDesktopLayouts(config)
    }

    // MARK: - Desktop Layouts

    /// Re-applies the desktop layout for the connected monitors.
    func applyDesktopLayoutNow() {
        desktopLayoutService?.applyNow()
    }

    private func applyDesktopLayouts(_ config: Configuration) {
        if config.desktopLayouts.enabled && accessibilityService.isTrusted {
            if let service = desktopLayoutService {
                service.update(config: config.desktopLayouts)
            } else {
                let service = DesktopLayoutService(config: config.desktopLayouts) { [weak self] in
                    DispatchQueue.main.async { self?.tilingService?.retile() }
                }
                desktopLayoutService = service
                service.start()
            }
        } else {
            stopDesktopLayouts()
        }
    }

    private func stopDesktopLayouts() {
        desktopLayoutService?.stop()
        desktopLayoutService = nil
    }

    // MARK: - Focus Follows Mouse

    private func applyFocusFollowsMouse(_ config: Configuration) {
        if config.focusFollowsMouse.enabled && accessibilityService.isTrusted {
            if let ffm = focusFollowsMouse {
                ffm.config = config.focusFollowsMouse
            } else {
                let ffm = FocusFollowsMouse(
                    accessibilityService: accessibilityService,
                    config: config.focusFollowsMouse
                )
                focusFollowsMouse = ffm
                ffm.start()
            }
            isRunning = true
        } else {
            focusFollowsMouse?.stop()
            focusFollowsMouse = nil
            if !config.focusFollowsMouse.enabled && !config.hotkeys.enabled {
                isRunning = false
            }
        }
    }

    // MARK: - Hotkeys

    private func applyHotkeys(_ config: Configuration) {
        // The app switcher's fn shortcuts run through the hotkey service too.
        let bindings = (config.hotkeys.enabled ? config.hotkeys.bindings : []) + config.appSwitcher.bindings
        if !bindings.isEmpty && accessibilityService.isTrusted {
            if let hks = hotkeyService {
                hks.updateBindings(bindings)
            } else {
                let dispatcher = actionDispatcher
                let hks = HotkeyService { action in
                    dispatcher.dispatch(action)
                }
                hks.updateBindings(bindings)
                hks.start()
                hotkeyService = hks
            }
            hotkeysActive = true
            isRunning = true
        } else {
            stopHotkeys()
        }
    }

    private func stopHotkeys() {
        hotkeyService?.stop()
        hotkeyService = nil
        hotkeysActive = false
    }

    // MARK: - Tiling

    private func applyTiling(_ config: Configuration) {
        if config.tiling.enabled && accessibilityService.isTrusted {
            if let ts = tilingService {
                ts.config = config.tiling
            } else {
                let ts = TilingService(
                    accessibilityService: accessibilityService,
                    config: config.tiling
                )
                tilingService = ts
                actionDispatcher.tilingService = ts
                ts.start()
            }
            isRunning = true
        } else {
            stopTiling()
        }
    }

    private func stopTiling() {
        tilingService?.stop()
        tilingService = nil
        actionDispatcher.tilingService = nil
    }
}
