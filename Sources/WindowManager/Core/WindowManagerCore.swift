import Foundation
import Combine

@MainActor
final class WindowManagerCore: ObservableObject {
    let configManager: ConfigManager
    let accessibilityService: AccessibilityService

    private var focusFollowsMouse: FocusFollowsMouse?
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var isRunning = false

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
        applyConfig(configManager.config)
        isRunning = true
    }

    func stop() {
        focusFollowsMouse?.stop()
        focusFollowsMouse = nil
        isRunning = false
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    private func applyConfig(_ config: Configuration) {
        Log.isEnabled = config.debug
        Log.info("Core: applyConfig debug=\(config.debug) ffm.enabled=\(config.focusFollowsMouse.enabled) trusted=\(accessibilityService.isTrusted)")

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
            if !config.focusFollowsMouse.enabled {
                isRunning = false
            }
        }
    }
}
