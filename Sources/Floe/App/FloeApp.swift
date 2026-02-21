import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let configManager = ConfigManager()
    let accessibilityService = AccessibilityService()
    lazy var core = FloeCore(
        configManager: configManager,
        accessibilityService: accessibilityService
    )

    var hasLaunchedBefore: Bool {
        UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    func markLaunched() {
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
    }

    func startIfReady() {
        if accessibilityService.isTrusted {
            core.start()
        }
    }
}

@main
struct FloeApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState.core)
                .environmentObject(appState.accessibilityService)
                .task {
                    if !appState.hasLaunchedBefore {
                        openWindow(id: "onboarding")
                        appState.markLaunched()
                    }
                    appState.startIfReady()
                }
        } label: {
            Image(systemName: "macwindow.on.rectangle")
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
            OnboardingView()
                .environmentObject(appState.accessibilityService)
                .environmentObject(appState.core)
        }
        .windowResizability(.contentSize)
    }
}
