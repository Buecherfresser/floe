import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var accessibilityService: AccessibilityService
    @ObservedObject private var updater = Updater.shared

    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var issues: [SystemIssue] = []
    @State private var newIgnoredApp = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: accessibilityService.isTrusted ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(accessibilityService.isTrusted ? .green : .red)
                    Text(accessibilityService.isTrusted ? "Accessibility access granted" : "Floe needs Accessibility access")
                    Spacer()
                    if !accessibilityService.isTrusted {
                        Button("Grant Access") { accessibilityService.promptForPermission() }
                    }
                }

                Toggle("Open Floe at login", isOn: Binding(
                    get: { openAtLogin },
                    set: { enabled in
                        LoginItem.setEnabled(enabled)
                        openAtLogin = LoginItem.isEnabled
                        loginNeedsApproval = LoginItem.needsApproval
                    }
                ))
                if loginNeedsApproval {
                    HStack {
                        Text("Allow Floe under Login Items in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                        }
                    }
                }
            }

            Section("Checks") {
                if issues.isEmpty {
                    Label("Nothing on this Mac gets in Floe's way.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(issue.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = issue.settingsURL {
                            Button("Open System Settings") { NSWorkspace.shared.open(url) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Check Again") { issues = SystemCheck.issues() }
                    .controlSize(.small)
            }

            Section("Focus follows mouse") {
                Toggle("Focus the window under the mouse", isOn: configManager.binding(\.focusFollowsMouse.enabled))
                if configManager.config.focusFollowsMouse.enabled {
                    Stepper(value: delayBinding, in: 0...1000, step: 5) {
                        HStack {
                            Text("Delay")
                            Spacer()
                            Text("\(configManager.config.focusFollowsMouse.delay) ms")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(configManager.config.focusFollowsMouse.ignoreApps, id: \.self) { app in
                        HStack {
                            Text(app)
                            Spacer()
                            Button(role: .destructive) {
                                configManager.update { $0.focusFollowsMouse.ignoreApps.removeAll { $0 == app } }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Ignore app", text: $newIgnoredApp, prompt: Text("App name, e.g. Finder"))
                            .onSubmit(addIgnoredApp)
                        Button("Add", action: addIgnoredApp)
                            .disabled(newIgnoredApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: AppVersion.current)
                updateStatus
                if updater.installMethod != .development {
                    Toggle("Install updates automatically", isOn: Binding(
                        get: { updater.installsAutomatically },
                        set: { updater.installsAutomatically = $0 }
                    ))
                }
            }

            Section {
                Toggle("Debug logging", isOn: configManager.binding(\.debug))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            issues = SystemCheck.issues()
            openAtLogin = LoginItem.isEnabled
            loginNeedsApproval = LoginItem.needsApproval
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        HStack {
            switch updater.state {
            case .idle:
                Text("Installed via \(updater.installMethod.title)")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            case .upToDate:
                Label("Floe is up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .available(let release):
                Label("Floe \(release.version) is available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Link("What's new", destination: release.pageURL)
                    .controlSize(.small)
            case .updating(let message):
                ProgressView().controlSize(.small)
                Text(message)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if case .available(let release) = updater.state, updater.installMethod != .development {
                Button("Update") { updater.install(release) }
            } else if updater.state != .checking, !isUpdating {
                Button("Check Now") { updater.check() }
            }
        }
    }

    private var isUpdating: Bool {
        if case .updating = updater.state { return true }
        return false
    }

    private var delayBinding: Binding<Int> {
        Binding(
            get: { max(0, configManager.config.focusFollowsMouse.delay) },
            set: { newValue in configManager.update { $0.focusFollowsMouse.delay = max(0, newValue) } }
        )
    }

    private func addIgnoredApp() {
        let name = newIgnoredApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.update { config in
            if !config.focusFollowsMouse.ignoreApps.contains(name) { config.focusFollowsMouse.ignoreApps.append(name) }
        }
        newIgnoredApp = ""
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
