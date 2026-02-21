import Foundation
import Combine

@MainActor
final class WindowManagerCore: ObservableObject {
    let configManager: ConfigManager
    let accessibilityService: AccessibilityService

    private var focusFollowsMouse: FocusFollowsMouse?
    private var hotkeyService: HotkeyService?
    private var tilingService: TilingService?
    private let spacesService = SpacesService()
    private lazy var actionDispatcher = ActionDispatcher(spacesService: spacesService)
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var isRunning = false
    @Published private(set) var hotkeysActive = false
    @Published private(set) var sipStatus: SIPStatus = .unknown
    @Published private(set) var cgsAvailable = false

    init(configManager: ConfigManager, accessibilityService: AccessibilityService) {
        self.configManager = configManager
        self.accessibilityService = accessibilityService

        configManager.$config
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.applyConfig(config)
            }
            .store(in: &cancellables)
    }

    func start() {
        guard accessibilityService.isTrusted else {
            Log.error("Core: cannot start — accessibility not trusted")
            return
        }
        Log.info("Core: starting")
        spacesService.verifyCGSAvailability()
        sipStatus = spacesService.sipStatus
        cgsAvailable = spacesService.cgsVerified
        applyConfig(configManager.config)
        isRunning = true
    }

    func stop() {
        focusFollowsMouse?.stop()
        focusFollowsMouse = nil
        stopHotkeys()
        stopTiling()
        isRunning = false
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    private func applyConfig(_ config: Configuration) {
        Log.isEnabled = config.debug
        Log.info("Core: applyConfig debug=\(config.debug) ffm.enabled=\(config.focusFollowsMouse.enabled) hotkeys.enabled=\(config.hotkeys.enabled) trusted=\(accessibilityService.isTrusted)")

        spacesService.moveMethod = config.spaces.moveMethod
        applyFocusFollowsMouse(config)
        applyHotkeys(config)
        applyTiling(config)
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
        if config.hotkeys.enabled && accessibilityService.isTrusted {
            if let hks = hotkeyService {
                hks.updateBindings(config.hotkeys.bindings)
            } else {
                let dispatcher = actionDispatcher
                let hks = HotkeyService { action in
                    dispatcher.dispatch(action)
                }
                hks.updateBindings(config.hotkeys.bindings)
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
                actionDispatcher.configManager = configManager
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
