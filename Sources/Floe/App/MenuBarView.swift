import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var core: FloeCore
    @EnvironmentObject private var accessibilityService: AccessibilityService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            ForEach(SystemCheck.issues()) { issue in
                SettingsLink {
                    Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                }
            }
            Divider()
            toggleButton
            Divider()
            Button("Show Welcome...") {
                openWindow(id: "onboarding")
            }
            SettingsLink {
                Text("Settings...")
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if !accessibilityService.isTrusted { return .red }
        return core.isRunning ? .green : .gray
    }

    private var statusText: String {
        if !accessibilityService.isTrusted { return "Accessibility access required" }
        if !core.isRunning { return "Paused" }
        var features: [String] = []
        let config = core.configManager.config
        if config.tiling.enabled { features.append("tiling") }
        if core.hotkeysActive { features.append("hotkeys") }
        if config.focusFollowsMouse.enabled { features.append("focus follows mouse") }
        return features.isEmpty ? "Active" : "Active: \(features.joined(separator: ", "))"
    }

    @ViewBuilder
    private var toggleButton: some View {
        Button(core.isRunning ? "Pause" : "Resume") {
            core.toggle()
        }
        .disabled(!accessibilityService.isTrusted)
    }
}
