import SwiftUI

struct HotkeysSettingsView: View {
    @EnvironmentObject private var configManager: ConfigManager
    @State private var recordingIndex: Int?

    private var bindings: [HotkeyBinding] { configManager.config.hotkeys.bindings }

    var body: some View {
        Form {
            Section {
                Toggle("Use hotkeys", isOn: configManager.binding(\.hotkeys.enabled))
                Text("Click a shortcut to record a new key combination. Floe handles these keys before any app sees them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if configManager.config.hotkeys.enabled {
                Section("Shortcuts") {
                    ForEach(Array(bindings.enumerated()), id: \.offset) { index, binding in
                        row(index: index, binding: binding)
                    }
                    HStack {
                        Button("Add Shortcut") { addShortcut() }
                        Spacer()
                        if !bindings.isEmpty {
                            Button("Remove All", role: .destructive) {
                                configManager.update { $0.hotkeys.bindings.removeAll() }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(index: Int, binding: HotkeyBinding) -> some View {
        HStack(spacing: 10) {
            KeyRecorder(
                hotkey: hotkeyBinding(at: index),
                isRecording: Binding(
                    get: { recordingIndex == index },
                    set: { recordingIndex = $0 ? index : nil }
                )
            )
            .frame(width: 110)

            if let current = ActionKind.from(binding.action) {
                Picker("Action", selection: kindBinding(at: index, current: current)) {
                    ForEach(ActionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 290)

                if current.kind.needsDesktop {
                    Text("\(current.desktop)")
                        .monospacedDigit()
                        .frame(width: 22, alignment: .trailing)
                    Stepper("Desktop", value: desktopBinding(at: index, current: current), in: 1...22)
                        .labelsHidden()
                }
                Spacer(minLength: 0)
            } else {
                Text("App switcher shortcut")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if isDuplicate(binding.hotkey, at: index) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another shortcut uses the same keys")
            }

            Button(role: .destructive) {
                configManager.update { config in
                    if config.hotkeys.bindings.indices.contains(index) { config.hotkeys.bindings.remove(at: index) }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Bindings (bounds-checked: the list can change underneath)

    private func hotkeyBinding(at index: Int) -> Binding<Hotkey> {
        Binding(
            get: { bindings.indices.contains(index) ? bindings[index].hotkey : Hotkey(modifiers: [], key: "") },
            set: { newValue in
                configManager.update { config in
                    if config.hotkeys.bindings.indices.contains(index) { config.hotkeys.bindings[index].hotkey = newValue }
                }
            }
        )
    }

    private func kindBinding(at index: Int, current: (kind: ActionKind, desktop: Int)) -> Binding<ActionKind> {
        Binding(
            get: { current.kind },
            set: { kind in setAction(kind.action(desktop: current.desktop), at: index) }
        )
    }

    private func desktopBinding(at index: Int, current: (kind: ActionKind, desktop: Int)) -> Binding<Int> {
        Binding(
            get: { current.desktop },
            set: { desktop in setAction(current.kind.action(desktop: desktop), at: index) }
        )
    }

    private func setAction(_ action: Action, at index: Int) {
        configManager.update { config in
            if config.hotkeys.bindings.indices.contains(index) { config.hotkeys.bindings[index].action = action }
        }
    }

    private func addShortcut() {
        configManager.update {
            $0.hotkeys.bindings.append(HotkeyBinding(hotkey: Hotkey(modifiers: [], key: ""), action: .focusSpace(1)))
        }
        recordingIndex = bindings.count - 1
    }

    private func isDuplicate(_ hotkey: Hotkey, at index: Int) -> Bool {
        guard !hotkey.key.isEmpty else { return false }
        return bindings.enumerated().contains { $0.offset != index && $0.element.hotkey == hotkey }
    }
}

/// Click, then press a key combination. Esc cancels.
struct KeyRecorder: View {
    @Binding var hotkey: Hotkey
    @Binding var isRecording: Bool
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(label)
                .font(.system(.body, design: .rounded))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onChange(of: isRecording) { _, recording in
            recording ? startRecording() : stopRecording()
        }
        .onAppear { if isRecording { startRecording() } }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return hotkey.key.isEmpty ? "Record" : HotkeyFormat.describe(hotkey)
    }

    private func startRecording() {
        guard monitor == nil else { return }
        HotkeyService.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyService.setSuspended(false)
        if isRecording { isRecording = false }
    }

    private func handle(_ event: NSEvent) {
        let keyCode = CGKeyCode(event.keyCode)
        let flags = event.modifierFlags
        if keyCode == 0x35, flags.intersection([.command, .control, .option, .shift]).isEmpty {
            stopRecording() // Esc
            return
        }
        guard let name = KeyCode.name(for: keyCode) else {
            NSSound.beep()
            return
        }

        var modifiers = Set<Modifier>()
        if flags.contains(.control) { modifiers.insert(.ctrl) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.cmd) }
        // Arrows and F-keys always report fn; only count it for other keys.
        if flags.contains(.function), !HotkeyService.implicitFnKeyCodes.contains(keyCode) { modifiers.insert(.fn) }

        guard !modifiers.isEmpty else {
            NSSound.beep() // a bare key would block typing it
            return
        }
        hotkey = Hotkey(modifiers: modifiers, key: name)
        stopRecording()
    }
}
