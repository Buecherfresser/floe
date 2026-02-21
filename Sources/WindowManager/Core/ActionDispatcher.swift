import Foundation

/// Routes hotkey actions to the appropriate service.
final class ActionDispatcher: @unchecked Sendable {
    private let spacesService: SpacesService

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

        case .focusSpaceNext:
            spacesService.focusNextSpace()

        case .focusSpacePrev:
            spacesService.focusPreviousSpace()

        case .toggleTiling:
            Log.info("ActionDispatcher: toggleTiling not yet implemented")

        case .balanceWindows:
            Log.info("ActionDispatcher: balanceWindows not yet implemented")

        case .increaseSplitRatio:
            Log.info("ActionDispatcher: increaseSplitRatio not yet implemented")

        case .decreaseSplitRatio:
            Log.info("ActionDispatcher: decreaseSplitRatio not yet implemented")
        }
    }
}
