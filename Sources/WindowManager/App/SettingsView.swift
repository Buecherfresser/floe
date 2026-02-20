import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var accessibilityService: AccessibilityService

    @State private var newIgnoreApp = ""

    var body: some View {
        Form {
            accessibilitySection
            focusFollowsMouseSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
    }

    // MARK: - Sections

    @ViewBuilder
    private var accessibilitySection: some View {
        Section("Accessibility") {
            HStack {
                Image(systemName: accessibilityService.isTrusted ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .foregroundStyle(accessibilityService.isTrusted ? .green : .red)
                Text(accessibilityService.isTrusted ? "Accessibility access granted" : "Accessibility access required")
                Spacer()
                if !accessibilityService.isTrusted {
                    Button("Grant Access") {
                        accessibilityService.promptForPermission()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var focusFollowsMouseSection: some View {
        Section("Focus Follows Mouse") {
            Toggle("Enabled", isOn: binding(\.focusFollowsMouse.enabled))

            Stepper(value: clampedDelay, in: 0...1000, step: 5) {
                HStack {
                    Text("Delay")
                    Spacer()
                    Text("\(configManager.config.focusFollowsMouse.delay) ms")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Ignored Apps")
                    .font(.headline)

                ForEach(configManager.config.focusFollowsMouse.ignoreApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button(role: .destructive) {
                            configManager.update { config in
                                config.focusFollowsMouse.ignoreApps.removeAll { $0 == app }
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("App name", text: $newIgnoreApp)
                        .onSubmit { addIgnoredApp() }
                    Button("Add") { addIgnoredApp() }
                        .disabled(newIgnoreApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section("Advanced") {
            Toggle("Debug logging", isOn: binding(\.debug))
            Text("Prints detailed logs to stdout. View with: swift run 2>&1")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var clampedDelay: Binding<Int> {
        Binding(
            get: { max(0, configManager.config.focusFollowsMouse.delay) },
            set: { newValue in
                configManager.update { $0.focusFollowsMouse.delay = max(0, newValue) }
            }
        )
    }

    // MARK: - Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<Configuration, T>) -> Binding<T> {
        Binding(
            get: { configManager.config[keyPath: keyPath] },
            set: { newValue in
                configManager.update { config in
                    config[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func addIgnoredApp() {
        let name = newIgnoreApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.update { config in
            if !config.focusFollowsMouse.ignoreApps.contains(name) {
                config.focusFollowsMouse.ignoreApps.append(name)
            }
        }
        newIgnoreApp = ""
    }
}
