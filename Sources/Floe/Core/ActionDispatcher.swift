import Foundation

/// Routes hotkey actions to the appropriate service.
final class ActionDispatcher: @unchecked Sendable {
    private let spacesService: SpacesService
    var tilingService: TilingService?
    var configManager: ConfigManager?

    init(spacesService: SpacesService) {
        self.spacesService = spacesService
    }

    func dispatch(_ action: Action) {
        switch action {
        case .focusSpace(let index):
            spacesService.focusSpace(at: index)

        case .moveWindowToSpace(let index):
            spacesService.moveWindowToSpace(at: index)

        case .moveWindowToSpaceNext:
            spacesService.moveWindowToNextSpace()

        case .moveWindowToSpacePrev:
            spacesService.moveWindowToPreviousSpace()

        case .moveWindowToSpaceAndReturn(let index):
            spacesService.moveWindowToSpaceAndReturn(at: index)

        case .moveWindowToSpaceNextAndReturn:
            spacesService.moveWindowToNextSpaceAndReturn()

        case .moveWindowToSpacePrevAndReturn:
            spacesService.moveWindowToPreviousSpaceAndReturn()

        case .focusSpaceNext:
            spacesService.focusNextSpace()

        case .focusSpacePrev:
            spacesService.focusPreviousSpace()

        case .toggleTiling:
            DispatchQueue.main.async { [weak self] in
                self?.configManager?.update { $0.tiling.enabled.toggle() }
            }

        case .balanceWindows:
            tilingService?.retile()

        case .increaseSplitRatio:
            DispatchQueue.main.async { [weak self] in
                self?.configManager?.update {
                    $0.tiling.splitRatio = min(0.9, $0.tiling.splitRatio + 0.05)
                }
            }

        case .decreaseSplitRatio:
            DispatchQueue.main.async { [weak self] in
                self?.configManager?.update {
                    $0.tiling.splitRatio = max(0.1, $0.tiling.splitRatio - 0.05)
                }
            }
        }
    }
}
