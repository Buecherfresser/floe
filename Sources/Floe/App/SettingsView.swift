import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var accessibilityService: AccessibilityService
    @EnvironmentObject private var core: FloeCore

    @State private var newIgnoreApp = ""
    @State private var newRuleApp = ""
    @State private var newRuleTiled = false
    @State private var monitors: [Monitor] = Monitors.ordered()
    @State private var newShortcutKey = ""
    @State private var fnUsage: FnKeySetting.Usage? = FnKeySetting.current

    var body: some View {
        Form {
            accessibilitySection
            focusFollowsMouseSection
            hotkeysSection
            appSwitcherSection
            tilingSection
            desktopLayoutsSection
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
            case .fn:    parts.append("Fn")
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
        case .focusApp(let bundleID):           return "Focus \(appName(bundleID))"
        case .pullApp(let bundleID):            return "Pull \(appName(bundleID)) here"
        }
    }

    private func appName(_ bundleID: String) -> String {
        configManager.config.appSwitcher.apps.first { $0.bundleID == bundleID }?.name ?? bundleID
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
    private var appSwitcherSection: some View {
        Section("App Switcher") {
            Toggle("Use fn as app switcher", isOn: appSwitcherEnabled)
            Text("fn + key jumps to the app's window (or opens the app). fn + shift + key pulls its window onto the current desktop. Turning this on sets the 🌐 key's own action to “Do Nothing”; turning it off restores it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if configManager.config.appSwitcher.enabled {
                if fnUsage != .doNothing {
                    HStack {
                        Label("“Press 🌐 key to” is set to \(fnUsage?.title ?? "the system default") — it will fire after every fn shortcut.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Fix") {
                            FnKeySetting.disable()
                            fnUsage = FnKeySetting.current
                        }
                    }
                }

                ForEach(configManager.config.appSwitcher.apps, id: \.key) { shortcut in
                    HStack {
                        Text("fn  \(shortcut.key.uppercased())")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .leading)
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(shortcut.name)
                        } else {
                            Text("\(shortcut.name) (not installed)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            configManager.update { $0.appSwitcher.apps.removeAll { $0.key == shortcut.key } }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Key", text: $newShortcutKey)
                        .frame(width: 60)
                        .onChange(of: newShortcutKey) { _, value in
                            newShortcutKey = String(value.lowercased().prefix(1))
                        }
                    Menu("Add App…") {
                        ForEach(runningRegularApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                addShortcut(bundleID: app.bundleIdentifier, name: app.localizedName)
                            }
                        }
                        Divider()
                        Button("Choose from Applications…") { chooseApplication() }
                    }
                    .disabled(!isValidNewShortcutKey)
                }
                if !newShortcutKey.isEmpty && !isValidNewShortcutKey {
                    Text("“\(newShortcutKey)” is already used or isn't a key Floe knows.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var appSwitcherEnabled: Binding<Bool> {
        Binding(
            get: { configManager.config.appSwitcher.enabled },
            set: { enabled in
                if enabled { FnKeySetting.disable() } else { FnKeySetting.restore() }
                fnUsage = FnKeySetting.current
                configManager.update { $0.appSwitcher.enabled = enabled }
            }
        )
    }

    private var runningRegularApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private var isValidNewShortcutKey: Bool {
        KeyCode.from(newShortcutKey) != nil
            && !configManager.config.appSwitcher.apps.contains { $0.key == newShortcutKey }
    }

    private func addShortcut(bundleID: String?, name: String?) {
        guard let bundleID, isValidNewShortcutKey else { return }
        let shortcut = AppShortcut(key: newShortcutKey, bundleID: bundleID, name: name ?? bundleID)
        configManager.update { config in
            config.appSwitcher.apps.append(shortcut)
            config.appSwitcher.apps.sort { $0.key < $1.key }
        }
        newShortcutKey = ""
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        addShortcut(bundleID: bundle.bundleIdentifier, name: name)
    }

    @ViewBuilder
    private var desktopLayoutsSection: some View {
        Section("Desktop Layouts") {
            Toggle("Manage desktops per monitor setup", isOn: binding(\.desktopLayouts.enabled))
            Text("Keeps desktop numbers stable when monitors come and go. Floe adds and removes desktops so each monitor gets the count below, and moves windows back to their desktop number. Windows on desktops that don't exist in a smaller setup wait on the last desktop and return when the monitor is reconnected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if configManager.config.desktopLayouts.enabled {
                if !CGSSpaceService.displays().contains(where: { $0.identifier != "Main" }) && monitors.count > 1 {
                    Label("Turn on \"Displays have separate Spaces\" in System Settings › Desktop & Dock.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected monitors")
                        .font(.headline)
                    ForEach(Array(monitors.enumerated()), id: \.offset) { index, monitor in
                        Text("Monitor \(index + 1): \(monitor.name)\(monitor.isMain ? " (main display)" : "")")
                            .foregroundStyle(.secondary)
                    }
                    Text("Monitor 1 is the main display; the others follow from left to right.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                ForEach(1...3, id: \.self) { count in
                    layoutEditor(monitorCount: count)
                }

                HStack {
                    Spacer()
                    Button("Apply Now") { core.applyDesktopLayoutNow() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            monitors = Monitors.ordered()
        }
    }

    @ViewBuilder
    private func layoutEditor(monitorCount count: Int) -> some View {
        let layout = desktopLayout(forMonitorCount: count)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(count == 1 ? "1 monitor" : "\(count) monitors")
                    .font(.headline)
                if count == monitors.count {
                    Text("current")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text("\(layout.totalDesktops) desktops")
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<count, id: \.self) { monitorIndex in
                Stepper(value: desktopCountBinding(monitorCount: count, monitorIndex: monitorIndex), in: 1...16) {
                    HStack {
                        Text("Monitor \(monitorIndex + 1)")
                        if count == monitors.count, monitors.indices.contains(monitorIndex) {
                            Text(monitors[monitorIndex].name)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if let range = layout.desktopRange(forMonitor: monitorIndex) {
                            Text(range.count == 1 ? "Desktop \(range.lowerBound)" : "Desktops \(range.lowerBound)–\(range.upperBound)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func desktopLayout(forMonitorCount count: Int) -> DesktopLayout {
        configManager.config.desktopLayouts.layout(forMonitorCount: count)
            ?? DesktopLayoutsConfig.default.layout(forMonitorCount: count)
            ?? DesktopLayout(monitors: count, desktops: Array(repeating: 6, count: count))
    }

    private func desktopCountBinding(monitorCount count: Int, monitorIndex: Int) -> Binding<Int> {
        Binding(
            get: { desktopLayout(forMonitorCount: count).desktops[monitorIndex] },
            set: { newValue in
                var layout = desktopLayout(forMonitorCount: count)
                layout.desktops[monitorIndex] = max(1, min(16, newValue))
                configManager.update { config in
                    config.desktopLayouts.layouts.removeAll { $0.monitors == count }
                    config.desktopLayouts.layouts.append(layout)
                    config.desktopLayouts.layouts.sort { $0.monitors < $1.monitors }
                }
            }
        )
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
