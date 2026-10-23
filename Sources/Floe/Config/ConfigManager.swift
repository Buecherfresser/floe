import Foundation
import Yams
import Combine

@MainActor
final class ConfigManager: ObservableObject {
    @Published var config: Configuration

    private let configURL: URL
    private nonisolated(unsafe) var fileWatcher: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var fileDescriptor: Int32 = -1
    private var isSaving = false

    static let configDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/floe", isDirectory: true)
    }()

    init() {
        self.configURL = Self.configDirectory.appendingPathComponent("config.yaml")
        self.config = .default
        self.config = loadOrCreate()
        addReloadHotkeyOnce()
        startWatching()
    }

    /// Re-reads the settings file, e.g. for the reload hotkey.
    func reloadFromDisk() {
        if let fromDisk = decodeFromDisk() { config = fromDisk }
    }

    /// Settings from before the reload hotkey existed get it once, unless
    /// Ctrl+Option+R is already taken. Removing it afterwards sticks.
    private func addReloadHotkeyOnce() {
        let key = "addedReloadHotkey"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let reload = HotkeysConfig.reloadBinding
        guard !config.hotkeys.bindings.contains(where: { $0.action == .reloadFloe || $0.hotkey == reload.hotkey }) else { return }
        Log.info("ConfigManager: adding the Ctrl+Option+R reload hotkey")
        update { $0.hotkeys.bindings.append(reload) }
    }

    deinit {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private static let legacyDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/window-manager", isDirectory: true)
    }()

    private func migrateFromLegacyIfNeeded() {
        let fm = FileManager.default
        let legacyConfig = Self.legacyDirectory.appendingPathComponent("config.yaml")
        guard fm.fileExists(atPath: legacyConfig.path),
              !fm.fileExists(atPath: configURL.path) else { return }

        Log.info("ConfigManager: migrating config from \(Self.legacyDirectory.path) to \(Self.configDirectory.path)")
        try? fm.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
        try? fm.moveItem(at: legacyConfig, to: configURL)
        try? fm.removeItem(at: Self.legacyDirectory)
    }

    private func loadOrCreate() -> Configuration {
        let fm = FileManager.default
        migrateFromLegacyIfNeeded()
        if !fm.fileExists(atPath: configURL.path) {
            try? fm.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            save(.default)
            return .default
        }

        return decodeFromDisk() ?? .default
    }

    /// Decodes the config file, logging why it failed. `nil` when the file is
    /// missing or unparseable.
    private func decodeFromDisk() -> Configuration? {
        guard let data = try? Data(contentsOf: configURL),
              let yaml = String(data: data, encoding: .utf8) else { return nil }
        do {
            return try YAMLDecoder().decode(Configuration.self, from: yaml)
        } catch {
            Log.error("ConfigManager: could not parse \(configURL.path): \(error)")
            return nil
        }
    }

    func save(_ configuration: Configuration) {
        isSaving = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isSaving = false
            }
        }

        var toSave = configuration

        // Never discard hotkey bindings that exist on disk. If the in-memory
        // config lost its bindings (e.g. due to a decode failure), preserve
        // whatever the file currently has.
        if toSave.hotkeys.bindings.isEmpty, let onDisk = loadBindingsFromDisk(), !onDisk.isEmpty {
            Log.info("ConfigManager: preserving \(onDisk.count) hotkey binding(s) from disk")
            toSave.hotkeys.bindings = onDisk
        }

        guard let yamlString = try? YAMLEncoder().encode(toSave) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)

        // Keep a copy of a hand-edited file we couldn't parse instead of
        // silently replacing it.
        if fm.fileExists(atPath: configURL.path), decodeFromDisk() == nil {
            let backup = configURL.appendingPathExtension("broken")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: configURL, to: backup)
            Log.error("ConfigManager: backed up unparseable config to \(backup.path)")
        }
        try? yamlString.write(to: configURL, atomically: true, encoding: .utf8)
        self.config = toSave
    }

    /// Reads just the hotkey bindings from the config file on disk,
    /// bypassing the in-memory config. Returns nil if the file can't be read.
    private func loadBindingsFromDisk() -> [HotkeyBinding]? {
        guard let data = try? Data(contentsOf: configURL),
              let yaml = String(data: data, encoding: .utf8),
              let diskConfig = try? YAMLDecoder().decode(Configuration.self, from: yaml) else {
            return nil
        }
        return diskConfig.hotkeys.bindings
    }

    func update(_ transform: (inout Configuration) -> Void) {
        var updated = config
        transform(&updated)
        save(updated)
    }

    // MARK: - File Watching

    private func startWatching() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configURL.path) { return }

        fileDescriptor = open(configURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        // Atomic saves (ours and most editors') replace the file, so the
        // watched inode goes away — re-arm on delete/rename.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .global(qos: .utility)
        )

        // Runs on a background queue: must not be inferred as main-actor
        // isolated, or Swift's runtime isolation check traps.
        source.setEventHandler { @Sendable [weak self, weak source] in
            let replaced = !(source?.data.intersection([.delete, .rename]).isEmpty ?? true)
            DispatchQueue.main.async {
                guard let self else { return }
                if replaced {
                    self.stopWatching()
                    self.startWatching()
                }
                guard !self.isSaving else { return }
                // Keep the current config if the file is mid-write or invalid.
                guard let reloaded = self.decodeFromDisk() else { return }
                if reloaded != self.config {
                    self.config = reloaded
                }
            }
        }

        // Close this source's own descriptor — by the time the handler runs,
        // `fileDescriptor` may already belong to a re-armed watcher.
        let fd = fileDescriptor
        source.setCancelHandler { @Sendable in
            close(fd)
        }

        source.resume()
        fileWatcher = source
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }
}
