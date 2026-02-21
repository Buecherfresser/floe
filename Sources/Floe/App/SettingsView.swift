import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var accessibilityService: AccessibilityService
    @EnvironmentObject private var core: FloeCore

    @State private var newIgnoreApp = ""
    @State private var newRuleApp = ""
    @State private var newRuleTiled = false

    var body: some View {
        Form {
            accessibilitySection
            focusFollowsMouseSection
            hotkeysSection
            tilingSection
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

                Text("Configure bindings in ~/.config/floe/config.yaml")
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
        case .focusSpace(let i):                return "Focus space \(i)"
        case .moveWindowToSpace(let i):         return "Move to space \(i)"
        case .moveWindowToSpaceNext:            return "Move window to next space"
        case .moveWindowToSpacePrev:            return "Move window to previous space"
        case .moveWindowToSpaceAndReturn(let i): return "Move to space \(i) & return"
        case .moveWindowToSpaceNextAndReturn:   return "Move to next space & return"
        case .moveWindowToSpacePrevAndReturn:   return "Move to prev space & return"
        case .focusSpaceNext:                   return "Next space"
        case .focusSpacePrev:                   return "Previous space"
        case .toggleTiling:                     return "Toggle tiling"
        case .balanceWindows:                   return "Balance windows"
        case .increaseSplitRatio:               return "Increase split ratio"
        case .decreaseSplitRatio:               return "Decrease split ratio"
        }
    }

    @ViewBuilder
    private var tilingSection: some View {
        Section("Tiling") {
            Toggle("Enabled", isOn: binding(\.tiling.enabled))

            if configManager.config.tiling.enabled {
                Stepper(value: clampedInnerGap, in: 0...50, step: 1) {
                    HStack {
                        Text("Inner gap")
                        Spacer()
                        Text("\(configManager.config.tiling.gaps.inner) px")
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: clampedOuterGap, in: 0...50, step: 1) {
                    HStack {
                        Text("Outer gap")
                        Spacer()
                        Text("\(configManager.config.tiling.gaps.outer) px")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Split ratio")
                    Slider(
                        value: splitRatioBinding,
                        in: 0.1...0.9,
                        step: 0.05
                    )
                    Text("\(Int(configManager.config.tiling.splitRatio * 100))%")
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                Toggle("Auto-balance", isOn: binding(\.tiling.autoBalance))

                VStack(alignment: .leading, spacing: 8) {
                    Text("App Rules")
                        .font(.headline)

                    ForEach(Array(configManager.config.tiling.rules.enumerated()), id: \.offset) { index, rule in
                        HStack {
                            Text(rule.app)
                            Spacer()
                            Text(rule.tiled ? "Tiled" : "Floating")
                                .font(.caption)
                                .foregroundStyle(rule.tiled ? .green : .secondary)
                            Toggle("", isOn: tilingRuleBinding(at: index))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Button(role: .destructive) {
                                configManager.update { config in
                                    config.tiling.rules.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("App name", text: $newRuleApp)
                            .onSubmit { addTilingRule() }
                        Toggle("Tiled", isOn: $newRuleTiled)
                            .toggleStyle(.switch)
                        Button("Add") { addTilingRule() }
                            .disabled(newRuleApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Text("Apps not listed here will be tiled by default.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section("Advanced") {
            Toggle("Debug logging", isOn: binding(\.debug))
            Text("Prints detailed logs to stdout.")
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

    // MARK: - Tiling Helpers

    private var clampedInnerGap: Binding<Int> {
        Binding(
            get: { max(0, min(50, configManager.config.tiling.gaps.inner)) },
            set: { newValue in
                configManager.update { $0.tiling.gaps.inner = max(0, min(50, newValue)) }
            }
        )
    }

    private var clampedOuterGap: Binding<Int> {
        Binding(
            get: { max(0, min(50, configManager.config.tiling.gaps.outer)) },
            set: { newValue in
                configManager.update { $0.tiling.gaps.outer = max(0, min(50, newValue)) }
            }
        )
    }

    private var splitRatioBinding: Binding<Double> {
        Binding(
            get: { configManager.config.tiling.splitRatio },
            set: { newValue in
                configManager.update { $0.tiling.splitRatio = newValue }
            }
        )
    }

    private func tilingRuleBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { configManager.config.tiling.rules[index].tiled },
            set: { newValue in
                configManager.update { $0.tiling.rules[index].tiled = newValue }
            }
        )
    }

    private func addTilingRule() {
        let name = newRuleApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.update { config in
            if !config.tiling.rules.contains(where: { $0.app == name }) {
                config.tiling.rules.append(TilingRule(app: name, tiled: newRuleTiled))
            }
        }
        newRuleApp = ""
        newRuleTiled = false
    }
}
