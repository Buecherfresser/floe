import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var accessibilityService: AccessibilityService
    @EnvironmentObject private var core: FloeCore
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 24) {
            header
            permissionCard
            if accessibilityService.isTrusted {
                readyCard
            }
        }
        .padding(32)
        .frame(width: 480)
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Floe")
                .font(.title.bold())
            Text("A lightweight tiling window manager for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var permissionCard: some View {
        GroupBox {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: accessibilityService.isTrusted
                          ? "checkmark.circle.fill" : "lock.shield")
                        .font(.title2)
                        .foregroundStyle(accessibilityService.isTrusted ? .green : .orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility Access")
                            .font(.headline)
                        Text(accessibilityService.isTrusted
                             ? "Permission granted. You're all set."
                             : "Floe needs accessibility access to focus and manage windows.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                if !accessibilityService.isTrusted {
                    VStack(spacing: 8) {
                        Button(action: { accessibilityService.promptForPermission() }) {
                            Text("Grant Accessibility Access")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("Check Again") {
                            accessibilityService.checkPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("After granting access in System Settings, click \"Check Again\".")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var readyCard: some View {
        VStack(spacing: 12) {
            Text("Focus follows mouse is ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: {
                core.start()
                dismissWindow(id: "onboarding")
            }) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
