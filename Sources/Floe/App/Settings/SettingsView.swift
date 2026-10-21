import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TilingSettingsView()
                .tabItem { Label("Tiling", systemImage: "rectangle.split.2x1") }
            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            AppSwitcherSettingsView()
                .tabItem { Label("App Switcher", systemImage: "app.badge") }
            DesktopsSettingsView()
                .tabItem { Label("Desktops", systemImage: "rectangle.on.rectangle") }
        }
        .frame(width: 600, height: 560)
    }
}
