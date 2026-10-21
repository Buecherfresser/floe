import SwiftUI
import UniformTypeIdentifiers

struct AppSwitcherSettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @State private var newShortcutKey = ""
    @State private var fnUsage: FnKeySetting.Usage? = FnKeySetting.current

    private var apps: [AppShortcut] { configManager.config.appSwitcher.apps }

    var body: some View {
        Form {
            Section {
                Toggle("Use fn as app switcher", isOn: enabledBinding)
                Text("fn + key jumps to the app's window or opens the app. fn + shift + key pulls its window onto the desktop you're on. Turning this on sets the 🌐 key's own action to \"Do Nothing\", and turning it off restores it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if configManager.config.appSwitcher.enabled {
                if fnUsage != .doNothing {
                    Section {
                        HStack {
                            Label("\"Press 🌐 key to\" is set to \(fnUsage?.title ?? "the system default"), so it fires after every fn shortcut.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Fix") {
                                FnKeySetting.disable()
                                fnUsage = FnKeySetting.current
                            }
                        }
                    }
                }

                Section("Apps") {
                    ForEach(apps, id: \.key) { shortcut in
                        HStack {
                            Text("fn \(shortcut.key.uppercased())")
                                .font(.system(.body, design: .rounded))
                                .frame(width: 50, alignment: .leading)
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
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("Key", text: $newShortcutKey, prompt: Text("Key"))
                            .labelsHidden()
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
                        Text("\"\(newShortcutKey)\" is already taken or isn't a key Floe knows.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { fnUsage = FnKeySetting.current }
    }

    private var enabledBinding: Binding<Bool> {
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
        KeyCode.from(newShortcutKey) != nil && !apps.contains { $0.key == newShortcutKey }
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
}
