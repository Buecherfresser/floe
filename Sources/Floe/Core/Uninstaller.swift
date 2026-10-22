import AppKit

/// Removes Floe with the uninstall script bundled in the app, the same one
/// people can run from the README.
@MainActor
enum Uninstaller {
    static var isAvailable: Bool { scriptURL != nil }

    private static var scriptURL: URL? {
        Bundle.main.url(forResource: "uninstall", withExtension: "sh")
    }

    static func uninstall(keepSettings: Bool) {
        guard let script = scriptURL else { return }
        Log.info("Uninstaller: uninstalling (keep settings: \(keepSettings))")
        LoginItem.setEnabled(false)

        // The script deletes the app it lives in, so it runs from a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("floe-uninstall.sh")
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: script, to: copy)) != nil else { return }

        var arguments = keepSettings ? " --keep-settings" : ""
        // A Homebrew install is found through brew; others by their path.
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if !path.contains("/Cellar/floe/") {
            arguments += " --app \(Updater.shellQuote(Bundle.main.bundleURL.path))"
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("floe-uninstall.log").path
        try? Updater.launchDetached("sleep 1; /bin/bash \(Updater.shellQuote(copy.path))\(arguments) > \(Updater.shellQuote(log)) 2>&1")
        NSApp.terminate(nil)
    }
}
