import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var accessibilityService: AccessibilityService
    @EnvironmentObject private var core: WindowManagerCore

    @State private var newIgnoreApp = ""

    var body: some View {
        Form {
            accessibilitySection
            focusFollowsMouseSection
            hotkeysSection
            spacesSection
            advancedSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 520)
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
    private var hotkeysSection: some View {
        Section("Hotkeys") {
            Toggle("Enabled", isOn: binding(\.hotkeys.enabled))

            if configManager.config.hotkeys.enabled {
                let bindings = configManager.config.hotkeys.bindings
                if bindings.isEmpty {
                    Text("No hotkeys configured. Edit config.yaml to add bindings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                        HStack {
                            Text(describeHotkey(binding.hotkey))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(describeAction(binding.action))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Configure bindings in ~/.config/window-manager/config.yaml")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func describeHotkey(_ hotkey: Hotkey) -> String {
        var parts: [String] = []
        let sortedMods = hotkey.modifiers.sorted { $0.rawValue < $1.rawValue }
        for mod in sortedMods {
            switch mod {
            case .ctrl:  parts.append("Ctrl")
            case .alt:   parts.append("Alt")
            case .shift: parts.append("Shift")
            case .cmd:   parts.append("Cmd")
            }
        }
        parts.append(hotkey.key.uppercased())
        return parts.joined(separator: " + ")
    }

    private func describeAction(_ action: Action) -> String {
        switch action {
        case .focusSpace(let i):        return "Focus space \(i)"
        case .moveWindowToSpace(let i): return "Move to space \(i)"
        case .moveWindowToSpaceNext:    return "Move window to next space"
        case .moveWindowToSpacePrev:    return "Move window to previous space"
        case .focusSpaceNext:           return "Next space"
        case .focusSpacePrev:           return "Previous space"
        }
    }

    @ViewBuilder
    private var spacesSection: some View {
        Section("Spaces") {
            Picker("Window move method", selection: binding(\.spaces.moveMethod)) {
                Text("Mouse Drag").tag(SpaceMoveMethod.mouseDrag)
                Text("Auto").tag(SpaceMoveMethod.auto)
                Text("CGS Private API").tag(SpaceMoveMethod.cgsPrivateAPI)
            }

            moveMethodDescription
        }
    }

    @ViewBuilder
    private var moveMethodDescription: some View {
        switch configManager.config.spaces.moveMethod {
        case .mouseDrag:
            Text("Grabs the window title bar and simulates a space switch keyboard shortcut. No SIP changes required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .auto:
            if core.cgsAvailable {
                Label("Using private APIs (SIP disabled)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("Using mouse drag (SIP enabled)", systemImage: "hand.draw.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .cgsPrivateAPI:
            if core.cgsAvailable {
                Label("Private APIs verified and active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(cgsUnavailableReason, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text("Requires SIP to be at least partially disabled (csrutil disable --without fs).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cgsUnavailableReason: String {
        switch core.sipStatus {
        case .enabled:  return "SIP is enabled — private APIs are blocked"
        case .unknown:  return "Could not determine SIP status"
        case .disabled: return "Private APIs failed to load despite SIP being disabled"
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
