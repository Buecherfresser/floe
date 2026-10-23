import SwiftUI

struct DesktopsSettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var core: FloeCore
    @ViewState private var monitors: [Monitor] = Monitors.ordered()

    var body: some View {
        Form {
            Section {
                Toggle("Keep desktop numbers per monitor setup", isOn: configManager.binding(\.desktopLayouts.enabled))
                Text("When monitors come and go, Floe adds and removes desktops so each monitor gets the count below, and moves every window back to its desktop number. Windows from a desktop the smaller setup lacks wait on the last desktop until the monitor is back. Floe briefly opens Mission Control to do this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if configManager.config.desktopLayouts.enabled {
                Section("Connected monitors") {
                    ForEach(Array(monitors.enumerated()), id: \.offset) { index, monitor in
                        LabeledContent("Monitor \(index + 1)", value: monitor.name + (monitor.isMain ? " (main display)" : ""))
                    }
                    Text("Monitor 1 is the main display, the others follow from left to right.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(1...3, id: \.self) { count in
                    Section {
                        layoutEditor(monitorCount: count)
                    } header: {
                        HStack {
                            Text(count == 1 ? "1 monitor" : "\(count) monitors")
                            if count == monitors.count {
                                Text("current")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                            Spacer()
                            Text("\(desktopLayout(forMonitorCount: count).totalDesktops) desktops")
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Apply Now") { core.applyDesktopLayoutNow() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            monitors = Monitors.ordered()
        }
    }

    @ViewBuilder
    private func layoutEditor(monitorCount count: Int) -> some View {
        let layout = desktopLayout(forMonitorCount: count)
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
}
