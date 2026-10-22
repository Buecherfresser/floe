import AppKit

/// Everything a bug report needs in one text: versions, how Floe was
/// installed, the checks, the settings and the recent log.
enum DiagnosticReport {
    static let issuesURL = URL(string: "https://github.com/\(Updater.repository)/issues/new")!

    /// Reading the log takes a few seconds, so that part runs in the background.
    @MainActor
    static func make() async -> String {
        let summary = summary()
        let log = await Task.detached { recentLog() }.value
        return summary + "\n" + log
    }

    @MainActor
    static func summary() -> String {
        var lines: [String] = []
        lines.append("Floe \(AppVersion.current), installed via \(Updater.shared.installMethod.title)")
        lines.append("macOS \(Compatibility.macOSVersion) on \(Compatibility.sysctlString("hw.model")) (\(Compatibility.sysctlString("hw.machine")))")
        lines.append("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")

        let screens = NSScreen.screens.map { screen in
            let size = screen.frame.size
            return "\(screen.localizedName) \(Int(size.width))×\(Int(size.height))"
        }
        lines.append("Displays: \(screens.joined(separator: ", "))")
        lines.append("Desktops: \(CGSSpaceService.displays().map { "\($0.userSpaceIDs.count)" }.joined(separator: " + "))")

        lines.append("")
        lines.append("Checks:")
        for probe in Compatibility.probes() {
            lines.append("  \(probe.ok ? "ok    " : "FAILED") \(probe.name)")
        }
        for feature in Compatibility.Feature.allCases where Compatibility.isFailing(feature) {
            lines.append("  FAILED \(feature.rawValue) (keeps failing)")
        }
        for issue in SystemCheck.issues() where issue.id != "compatibility" {
            lines.append("  issue  \(issue.title)")
        }

        lines.append("")
        lines.append("Settings (~/.config/floe/config.yaml):")
        let config = ConfigManager.configDirectory.appendingPathComponent("config.yaml")
        lines.append((try? String(contentsOf: config, encoding: .utf8)) ?? "  (none)")

        lines.append("")
        lines.append("Log, last 30 minutes:")
        return lines.joined(separator: "\n")
    }

    nonisolated static func recentLog(maxLines: Int = 300) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "30m", "--style", "compact",
                             "--predicate", "subsystem == \"com.jonasdrechsel.floe\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "  (couldn't read the log: \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        // The first line is the column header.
        return lines.dropFirst().suffix(maxLines).joined(separator: "\n")
    }
}
