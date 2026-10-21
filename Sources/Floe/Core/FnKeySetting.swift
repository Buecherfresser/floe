import Foundation

/// The system "Press 🌐 key to …" setting (System Settings › Keyboard).
/// Pressing and releasing fn triggers that action unless it's "Do Nothing" —
/// which would fire after every fn+key app shortcut.
enum FnKeySetting {
    private static var domain: CFString { "com.apple.HIToolbox" as CFString }
    private static var key: CFString { "AppleFnUsageType" as CFString }
    /// Floe's own default holding the value to restore.
    private static let savedKey = "savedAppleFnUsageType"

    enum Usage: Int {
        case doNothing = 0
        case changeInputSource = 1
        case showEmoji = 2
        case startDictation = 3

        var title: String {
            switch self {
            case .doNothing: "Do Nothing"
            case .changeInputSource: "Change Input Source"
            case .showEmoji: "Show Emoji & Symbols"
            case .startDictation: "Start Dictation"
            }
        }
    }

    /// `nil` when never changed (system default).
    static var current: Usage? {
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue(key, domain) as? Int else { return nil }
        return Usage(rawValue: value)
    }

    /// Sets the 🌐 key to "Do Nothing", remembering the previous value.
    static func disable() {
        guard current != .doNothing else { return }
        UserDefaults.standard.set(current?.rawValue ?? -1, forKey: savedKey)
        write(Usage.doNothing.rawValue as CFNumber)
    }

    /// Restores the value saved by `disable()`.
    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Int else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        write(saved < 0 ? nil : saved as CFNumber)
    }

    private static func write(_ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key, value, domain)
        CFPreferencesAppSynchronize(domain)
        Log.info("FnKey: AppleFnUsageType set to \(value.map { "\($0)" } ?? "default")")
    }
}
