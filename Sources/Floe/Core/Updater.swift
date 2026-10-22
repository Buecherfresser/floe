import AppKit
import Foundation
import Security

/// Checks GitHub for a newer release and installs it the same way Floe was
/// installed: Homebrew upgrades the formula, the install script builds the
/// new version from source, and a downloaded app replaces itself with the
/// release's zip.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    nonisolated static let repository = "Buecherfresser/floe"
    static let installScriptURL = "https://raw.githubusercontent.com/\(repository)/main/scripts/install.sh"

    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let zipURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case updating(String)
        /// Installed; Floe restarts into it unless `relaunches` is off.
        case installed(String)
        case failed(String)
    }

    enum InstallMethod: Equatable {
        case homebrew(brew: String)
        case script
        case download
        /// Run from the build folder: updates come from your own builds.
        case development

        var title: String {
            switch self {
            case .homebrew: "Homebrew"
            case .script: "install script"
            case .download: "download"
            case .development: "development build"
            }
        }
    }

    @Published private(set) var state: State = .idle
    let installMethod = Updater.detectInstallMethod()

    private static let automaticKey = "installUpdatesAutomatically"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?
    private var statusTimer: Timer?

    /// Off for the diagnostics `update` command, which checks the result
    /// itself instead of restarting into it.
    var relaunches = true

    private init() {}

    var installsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticKey)
            objectWillChange.send()
        }
    }

    var currentVersion: String { AppVersion.current }

    // MARK: - Checking

    /// Checks shortly after launch and then once a day.
    func start() {
        guard installMethod != .development, timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.check(install: self.installsAutomatically)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.check(install: self.installsAutomatically)
            }
        }
    }

    /// Looks for a newer release and, with `install`, installs it right away.
    func check(install: Bool = false) {
        if case .updating = state { return }
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatestRelease()
                if Self.isVersion(release.version, newerThan: currentVersion) {
                    Log.info("Updater: \(release.version) is available (running \(currentVersion))")
                    state = .available(release)
                    if install && installMethod != .development {
                        self.install(release)
                    }
                } else {
                    state = .upToDate
                }
            } catch {
                Log.error("Updater: check failed: \(error)")
                state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    private static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Floe/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            throw UpdateError("there is no release yet")
        }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let zip = payload.assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url
        return Release(version: version, pageURL: payload.html_url, zipURL: zip)
    }

    /// Compares dotted version numbers ("0.10.0" is newer than "0.9.2").
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func install(_ release: Release) {
        switch installMethod {
        case .homebrew(let brew):
            // `brew upgrade` only looks at the tap again when its own daily
            // auto-update is due, so fetch the tap first.
            state = .updating("Running brew update…")
            run(brew, ["update", "--quiet"]) { [weak self] _, _ in
                guard let self else { return }
                self.state = .updating("Running brew upgrade…")
                self.run(brew, ["upgrade", "floe"]) { ok, output in
                    guard ok else {
                        self.state = .failed("brew upgrade failed: \(output.suffix(200))")
                        return
                    }
                    let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent().path
                    let app = "\(prefix)/opt/floe/Floe.app"
                    // Not Bundle(path:): it caches, and this may be Floe's own path.
                    let installed = NSDictionary(contentsOfFile: "\(app)/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
                    guard installed == release.version else {
                        self.state = .failed("Homebrew still has Floe \(installed ?? "?"). Run brew upgrade floe in Terminal.")
                        return
                    }
                    // Homebrew builds an ad-hoc signed app. Signing it with the
                    // local certificate keeps the Accessibility permission. It
                    // only re-signs when signing is set up: setting it up asks
                    // for a password, which mustn't pop up out of nowhere.
                    self.state = .updating("Signing \(release.version)…")
                    self.run("\(prefix)/bin/floe-sign", ["--if-set-up", app]) { _, output in
                        Log.info("Updater: floe-sign: \(output.suffix(300))")
                        self.finish(release.version, launching: app)
                    }
                }
            }

        case .script:
            // The script builds the new version, then quits and reopens Floe.
            // It runs on its own so it keeps going once Floe has quit, and
            // leaves its exit status behind for Floe to pick up if it fails.
            state = .updating("Building \(release.version)… Floe restarts when it's done.")
            let log = Self.updateLogURL
            let status = log.deletingPathExtension().appendingPathExtension("status")
            let script = log.deletingPathExtension().appendingPathExtension("sh")
            try? FileManager.default.removeItem(at: status)
            let appDir = Bundle.main.bundleURL.deletingLastPathComponent().path
            let launch = relaunches ? "" : " --no-launch"
            let command = "mkdir -p \(shellQuote(log.deletingLastPathComponent().path)) && "
                + "curl -fsSL \(Self.installScriptURL) -o \(shellQuote(script.path)) && "
                + "/bin/bash \(shellQuote(script.path)) --update --app-dir \(shellQuote(appDir))\(launch) > \(shellQuote(log.path)) 2>&1; "
                + "echo $? > \(shellQuote(status.path))"
            do {
                try Self.launchDetached(command)
            } catch {
                state = .failed("Couldn't start the install script: \(error.localizedDescription)")
                return
            }
            watchScript(status: status, log: log, version: release.version)

        case .download:
            guard let zipURL = release.zipURL else {
                state = .failed("Release \(release.version) has no app download.")
                return
            }
            state = .updating("Downloading \(release.version)…")
            Task { await replaceApp(with: zipURL, version: release.version) }

        case .development:
            break
        }
    }

    /// Picks up the install script's exit status. On success the script has
    /// usually quit Floe already.
    private func watchScript(status: URL, log: URL, version: String) {
        let started = Date()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollScript(status: status, log: log, version: version, started: started) }
        }
    }

    private func pollScript(status: URL, log: URL, version: String, started: Date) {
        if let text = try? String(contentsOf: status, encoding: .utf8) {
            statusTimer?.invalidate()
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                state = .installed(version)
            } else {
                let tail = (try? String(contentsOf: log, encoding: .utf8))?
                    .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
                state = .failed("The update failed: \(tail) (full log in \(log.path))")
            }
        } else if Date().timeIntervalSince(started) > 15 * 60 {
            statusTimer?.invalidate()
            state = .failed("The update didn't finish. Details are in \(log.path).")
        }
    }

    /// Downloads the release zip, checks it is a signed Floe of that version,
    /// swaps it in for the running app and relaunches.
    private func replaceApp(with zipURL: URL, version: String) async {
        do {
            let (zip, _) = try await URLSession.shared.download(from: zipURL)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("floe-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            guard await runAsync("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else {
                throw UpdateError("couldn't unpack the download")
            }
            let newApp = work.appendingPathComponent("Floe.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
                throw UpdateError("the download isn't Floe \(version)")
            }
            guard await runAsync("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) else {
                throw UpdateError("the download's signature is broken")
            }

            let current = Bundle.main.bundleURL.path
            let folder = Bundle.main.bundleURL.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: folder) else {
                throw UpdateError("Floe can't replace itself in \(folder). Download the new version from GitHub instead.")
            }
            Log.info("Updater: replacing \(current) with \(version)")
            // Keeps the old app until the new one is in place, and puts it
            // back if copying fails, so a failed update never leaves no Floe.
            let old = "\(current).old"
            let swap = "rm -rf \(shellQuote(old)) && mv \(shellQuote(current)) \(shellQuote(old)) && "
                + "if /usr/bin/ditto \(shellQuote(newApp.path)) \(shellQuote(current)); then rm -rf \(shellQuote(old)); "
                + "else rm -rf \(shellQuote(current)); mv \(shellQuote(old)) \(shellQuote(current)); exit 1; fi"
            if relaunches {
                // Swap once Floe has quit, then start whichever version is there.
                try Self.launchDetached("sleep 1; \(swap); open \(shellQuote(current))")
                NSApp.terminate(nil)
            } else {
                let (ok, output) = await Self.runCapturing("/bin/sh", ["-c", swap])
                state = ok ? .installed(version) : .failed("Couldn't swap in the new version: \(output)")
            }
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    private func finish(_ version: String, launching path: String) {
        state = .installed(version)
        guard relaunches else { return }
        try? Self.launchDetached("sleep 1; open \(shellQuote(path))")
        NSApp.terminate(nil)
    }

    /// True when Floe is ad-hoc signed, so macOS asks for Accessibility
    /// again after every update.
    nonisolated static var isAdHocSigned: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    // MARK: - Install method

    private static func detectInstallMethod() -> InstallMethod {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if path.contains("/Cellar/floe/") {
            let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
            return brew.map { .homebrew(brew: $0) } ?? .download
        }
        if path.contains("/dist/") || path.contains("/dist.noindex/") || path.contains("/.build/") {
            return .development
        }
        // The script writes "script" and the app it installed.
        if let marker = try? String(contentsOf: installMarkerURL, encoding: .utf8) {
            let lines = marker.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.first == "script", lines.count < 2 || lines[1] == Bundle.main.bundleURL.path {
                return .script
            }
        }
        return .download
    }

    /// Written by scripts/install.sh.
    static var installMarkerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Floe/install-method")
    }

    static var updateLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Floe/update.log")
    }

    // MARK: - Processes

    private func run(_ executable: String, _ arguments: [String], completion: @escaping @MainActor (Bool, String) -> Void) {
        Task {
            let (ok, output) = await Self.runCapturing(executable, arguments)
            completion(ok, output)
        }
    }

    private func runAsync(_ executable: String, _ arguments: [String]) async -> Bool {
        await Self.runCapturing(executable, arguments).0
    }

    private nonisolated static func runCapturing(_ executable: String, _ arguments: [String]) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus == 0, output))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (false, error.localizedDescription))
            }
        }
    }

    /// Runs a shell command that outlives Floe.
    static func launchDetached(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup sh -c \(shellQuote(command)) >/dev/null 2>&1 &"]
        try process.run()
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellQuote(_ string: String) -> String { Self.shellQuote(string) }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
