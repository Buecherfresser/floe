import SwiftUI

extension ConfigManager {
    /// A binding into the config that saves on every change.
    func binding<T>(_ keyPath: WritableKeyPath<Configuration, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

enum HotkeyFormat {
    /// "fn⌃⇧1", in the order macOS menus use.
    static func describe(_ hotkey: Hotkey) -> String {
        guard !hotkey.key.isEmpty else { return "" }
        let order: [(Modifier, String)] = [(.fn, "fn "), (.ctrl, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.cmd, "⌘")]
        let modifiers = order.filter { hotkey.modifiers.contains($0.0) }.map(\.1).joined()
        return modifiers + keySymbol(hotkey.key)
    }

    private static func keySymbol(_ key: String) -> String {
        switch key.lowercased() {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "return", "enter": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "delete", "backspace": "⌫"
        case "forwarddelete": "⌦"
        case "escape", "esc": "⎋"
        case "minus": "-"
        case "equal": "="
        default: key.uppercased()
        }
    }
}

/// The hotkey actions as the Settings picker offers them.
enum ActionKind: String, CaseIterable, Identifiable {
    case focusSpace, focusSpaceNext, focusSpacePrev
    case moveToSpace, moveToSpaceNext, moveToSpacePrev
    case moveToSpaceAndStay, moveToSpaceNextAndStay, moveToSpacePrevAndStay
    case toggleTiling, balanceWindows, increaseSplitRatio, decreaseSplitRatio
    case reloadFloe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusSpace: "Go to desktop"
        case .focusSpaceNext: "Go to next desktop"
        case .focusSpacePrev: "Go to previous desktop"
        case .moveToSpace: "Move window to desktop and follow"
        case .moveToSpaceNext: "Move window to next desktop and follow"
        case .moveToSpacePrev: "Move window to previous desktop and follow"
        case .moveToSpaceAndStay: "Send window to desktop"
        case .moveToSpaceNextAndStay: "Send window to next desktop"
        case .moveToSpacePrevAndStay: "Send window to previous desktop"
        case .toggleTiling: "Turn tiling on or off"
        case .balanceWindows: "Balance windows"
        case .increaseSplitRatio: "Grow first window"
        case .decreaseSplitRatio: "Shrink first window"
        case .reloadFloe: "Reload Floe"
        }
    }

    var needsDesktop: Bool {
        self == .focusSpace || self == .moveToSpace || self == .moveToSpaceAndStay
    }

    func action(desktop: Int) -> Action {
        switch self {
        case .focusSpace: .focusSpace(desktop)
        case .focusSpaceNext: .focusSpaceNext
        case .focusSpacePrev: .focusSpacePrev
        case .moveToSpace: .moveWindowToSpace(desktop)
        case .moveToSpaceNext: .moveWindowToSpaceNext
        case .moveToSpacePrev: .moveWindowToSpacePrev
        case .moveToSpaceAndStay: .moveWindowToSpaceAndReturn(desktop)
        case .moveToSpaceNextAndStay: .moveWindowToSpaceNextAndReturn
        case .moveToSpacePrevAndStay: .moveWindowToSpacePrevAndReturn
        case .toggleTiling: .toggleTiling
        case .balanceWindows: .balanceWindows
        case .increaseSplitRatio: .increaseSplitRatio
        case .decreaseSplitRatio: .decreaseSplitRatio
        case .reloadFloe: .reloadFloe
        }
    }

    /// `nil` for the app switcher's actions, which have their own tab.
    static func from(_ action: Action) -> (kind: ActionKind, desktop: Int)? {
        switch action {
        case .focusSpace(let n): (.focusSpace, n)
        case .focusSpaceNext: (.focusSpaceNext, 1)
        case .focusSpacePrev: (.focusSpacePrev, 1)
        case .moveWindowToSpace(let n): (.moveToSpace, n)
        case .moveWindowToSpaceNext: (.moveToSpaceNext, 1)
        case .moveWindowToSpacePrev: (.moveToSpacePrev, 1)
        case .moveWindowToSpaceAndReturn(let n): (.moveToSpaceAndStay, n)
        case .moveWindowToSpaceNextAndReturn: (.moveToSpaceNextAndStay, 1)
        case .moveWindowToSpacePrevAndReturn: (.moveToSpacePrevAndStay, 1)
        case .toggleTiling: (.toggleTiling, 1)
        case .balanceWindows: (.balanceWindows, 1)
        case .increaseSplitRatio: (.increaseSplitRatio, 1)
        case .decreaseSplitRatio: (.decreaseSplitRatio, 1)
        case .reloadFloe: (.reloadFloe, 1)
        case .focusApp, .pullApp: nil
        }
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }
}
