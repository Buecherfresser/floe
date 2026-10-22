import AppKit

/// Things on this Mac that get in Floe's way. Each comes with what to do
/// about it, so Settings and the menu bar can say so directly.
struct SystemIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// System Settings pane to open, if the fix is a setting there.
    let settingsURL: URL?
}

enum SystemCheck {

    /// Window managers and hotkey daemons that move windows or grab the same
    /// keys. Floe and them fight over every window.
    private static let conflictingProcesses = ["yabai", "skhd", "AeroSpace", "Amethyst", "Rectangle", "Magnet", "Moom", "Loop"]

    static func issues() -> [SystemIssue] {
        var issues: [SystemIssue] = []

        let running = runningProcessNames()
        for name in conflictingProcesses where running.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            issues.append(SystemIssue(
                id: "conflict-\(name)",
                title: "\(name) is running",
                detail: "It moves windows and handles hotkeys too, so the two fight over every window. Quit \(name) and remove it from your login items.",
                settingsURL: nil
            ))
        }

        if NSScreen.screens.count > 1, boolPreference("spans-displays", domain: "com.apple.spaces") == true {
            issues.append(SystemIssue(
                id: "spans-displays",
                title: "\"Displays have separate Spaces\" is off",
                detail: "Floe needs every display to have its own desktops. Turn it on in Desktop & Dock and log out once.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
            ))
        }

        if boolPreference("EnableTilingByEdgeDrag", domain: "com.apple.WindowManager") ?? true {
            issues.append(SystemIssue(
                id: "edge-tiling",
                title: "macOS window tiling is on",
                detail: "Dragging a window to a screen edge makes macOS tile it, and macOS then holds it against Floe's layout. Turn off \"Drag windows to screen edges to tile\" in Desktop & Dock.",
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
            ))
        }

        issues += Compatibility.issues()
        return issues
    }

    private static func boolPreference(_ key: String, domain: String) -> Bool? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Bool
    }

    /// Names of all processes of this user (daemons like yabai aren't apps).
    private static func runningProcessNames() -> Set<String> {
        var names = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return names }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return names }

        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }
}
