import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let configManager = ConfigManager()
    let accessibilityService = AccessibilityService()
    lazy var core = FloeCore(
        configManager: configManager,
        accessibilityService: accessibilityService
    )

    /// The welcome opens at launch until the user has gone through it, so
    /// quitting halfway brings it back next time.
    let showsWelcome = !OnboardingModel.isFinished

    init() {
        if showsWelcome {
            // A window manager should be there after every restart.
            LoginItem.setEnabled(true)
        }
        // Start right at launch, not only once the menu bar menu is opened.
        DispatchQueue.main.async { [weak self] in self?.startIfReady() }
    }

    func startIfReady() {
        if accessibilityService.isTrusted {
            core.start()
        }
    }
}

/// Floe's icon in the menu bar, which the welcome shows too.
enum MenuBarIcon {
    static let symbol = "macwindow.on.rectangle"
}

@main
struct FloeApp: App {
    @StateObject private var appState = AppState()

    init() {
        Diagnostics.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState.core)
                .environmentObject(appState.accessibilityService)
                .task { appState.startIfReady() }
        } label: {
            Image(systemName: MenuBarIcon.symbol)
        }

        Settings {
            SettingsView()
                .environmentObject(appState.configManager)
                .environmentObject(appState.accessibilityService)
                .environmentObject(appState.core)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
        }

        Window("Welcome", id: "onboarding") {
            OnboardingView(
                accessibility: appState.accessibilityService,
                core: appState.core,
                configManager: appState.configManager
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // The menu bar menu's content only loads once it's clicked, so the
        // welcome opens itself until it's finished.
        .defaultLaunchBehavior(appState.showsWelcome ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}
