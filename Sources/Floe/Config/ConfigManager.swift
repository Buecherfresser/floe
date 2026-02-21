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
        startWatching()
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

        guard let data = try? Data(contentsOf: configURL),
              let yaml = String(data: data, encoding: .utf8),
              let loaded = try? YAMLDecoder().decode(Configuration.self, from: yaml) else {
            return .default
        }
        return loaded
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

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isSaving else { return }
                let reloaded = self.loadOrCreate()
                if reloaded != self.config {
                    self.config = reloaded
                }
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        source.resume()
        fileWatcher = source
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }
}
