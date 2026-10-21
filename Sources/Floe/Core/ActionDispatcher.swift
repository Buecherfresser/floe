import Foundation

/// Routes hotkey actions to the appropriate service.
final class ActionDispatcher: @unchecked Sendable {
    private let spacesService: SpacesService
    var tilingService: TilingService?
    var configManager: ConfigManager?

    init(spacesService: SpacesService) {
        self.spacesService = spacesService
    }

    /// A window leaving the current space produces no AX notification, so
    /// retile explicitly once the move has completed.
    private var retileAfterMove: @Sendable () -> Void {
        { [weak self] in self?.tilingService?.retile() }
    }

    func dispatch(_ action: Action) {
        switch action {
        case .focusSpace(let index):
            spacesService.focusSpace(at: index)

        case .moveWindowToSpace(let index):
            spacesService.moveWindowToSpace(at: index, completion: retileAfterMove)

        case .moveWindowToSpaceNext:
            spacesService.moveWindowToNextSpace(completion: retileAfterMove)

        case .moveWindowToSpacePrev:
            spacesService.moveWindowToPreviousSpace(completion: retileAfterMove)

        case .moveWindowToSpaceAndReturn(let index):
            spacesService.moveWindowToSpaceAndReturn(at: index, completion: retileAfterMove)

        case .moveWindowToSpaceNextAndReturn:
            spacesService.moveWindowToNextSpaceAndReturn(completion: retileAfterMove)

        case .moveWindowToSpacePrevAndReturn:
            spacesService.moveWindowToPreviousSpaceAndReturn(completion: retileAfterMove)

        case .focusSpaceNext:
            spacesService.focusNextSpace()

        case .focusSpacePrev:
            spacesService.focusPreviousSpace()

        case .focusApp(let bundleID):
            spacesService.focusApp(bundleID: bundleID)

        case .pullApp(let bundleID):
            spacesService.pullApp(bundleID: bundleID, completion: retileAfterMove)

        case .toggleTiling:
            DispatchQueue.main.async { [weak self] in
                self?.configManager?.update { $0.tiling.enabled.toggle() }
            }

        case .balanceWindows:
            tilingService?.balance()

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
