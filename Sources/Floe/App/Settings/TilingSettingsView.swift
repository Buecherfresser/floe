import SwiftUI

struct TilingSettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @ViewState private var newRuleApp = ""

    private var tiling: TilingConfig { configManager.config.tiling }

    var body: some View {
        Form {
            Section {
                Toggle("Tile windows", isOn: configManager.binding(\.tiling.enabled))
                Text("Windows share each display and rearrange when you open, move or resize one. Drop a window onto another to swap them, or hold Control and drag to resize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tiling.enabled {
                Section("Layout") {
                    Stepper(value: gapBinding(\.tiling.gaps.inner), in: 0...50) {
                        valueRow("Gap between windows", "\(tiling.gaps.inner) pt")
                    }
                    Stepper(value: gapBinding(\.tiling.gaps.outer), in: 0...50) {
                        valueRow("Gap at the screen edge", "\(tiling.gaps.outer) pt")
                    }
                    Toggle("Give every window the same space", isOn: configManager.binding(\.tiling.autoBalance))
                    if !tiling.autoBalance {
                        LabeledContent("First window") {
                            HStack {
                                Slider(value: configManager.binding(\.tiling.splitRatio), in: 0.1...0.9, step: 0.05)
                                Text("\(Int(tiling.splitRatio * 100))%")
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                Section("Apps that always float") {
                    ForEach(tiling.rules.filter { !$0.tiled }, id: \.app) { rule in
                        HStack {
                            Text(rule.app)
                            Spacer()
                            Button(role: .destructive) {
                                configManager.update { $0.tiling.rules.removeAll { $0.app == rule.app } }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Float app", text: $newRuleApp, prompt: Text("App name, e.g. Calculator"))
                            .onSubmit(addRule)
                        Button("Add", action: addRule)
                            .disabled(newRuleApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Fixed-size windows like System Settings float on their own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func gapBinding(_ keyPath: WritableKeyPath<Configuration, Int>) -> Binding<Int> {
        Binding(
            get: { max(0, min(50, configManager.config[keyPath: keyPath])) },
            set: { newValue in configManager.update { $0[keyPath: keyPath] = max(0, min(50, newValue)) } }
        )
    }

    private func addRule() {
        let name = newRuleApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        configManager.update { config in
            config.tiling.rules.removeAll { $0.app == name }
            config.tiling.rules.append(TilingRule(app: name, tiled: false))
        }
        newRuleApp = ""
    }
}
