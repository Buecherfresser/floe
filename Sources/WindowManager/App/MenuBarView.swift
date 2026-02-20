import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var core: WindowManagerCore
    @EnvironmentObject private var accessibilityService: AccessibilityService

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            Divider()
            toggleButton
            Divider()
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
        return core.isRunning ? "Active" : "Paused"
    }

    @ViewBuilder
    private var toggleButton: some View {
        Button(core.isRunning ? "Pause" : "Resume") {
            core.toggle()
        }
        .disabled(!accessibilityService.isTrusted)
    }
}
