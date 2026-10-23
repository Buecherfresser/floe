import Foundation
import CoreGraphics

// MARK: - Focus Follows Mouse

struct FocusFollowsMouseConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var delay: Int
    var ignoreApps: [String]

    // Off by default: it takes getting used to.
    static let `default` = FocusFollowsMouseConfig(
        enabled: false,
        delay: 10,
        ignoreApps: []
    )
}

// MARK: - Hotkeys

enum Modifier: String, Codable, Hashable, Sendable, CaseIterable {
    case alt
    case shift
    case ctrl
    case cmd
    /// The fn / 🌐 key.
    case fn

    var cgFlag: CGEventFlags {
        switch self {
        case .alt:   return .maskAlternate
        case .shift: return .maskShift
        case .ctrl:  return .maskControl
        case .cmd:   return .maskCommand
        case .fn:    return .maskSecondaryFn
        }
    }

    static func flags(from set: Set<Modifier>) -> CGEventFlags {
        var flags = CGEventFlags()
        for mod in set { flags.insert(mod.cgFlag) }
        return flags
    }

    /// Relevant modifier mask for matching (ignoring caps lock, num lock, etc.)
    static let relevantMask = CGEventFlags([
        .maskAlternate, .maskShift, .maskControl, .maskCommand, .maskSecondaryFn,
    ])
}

struct Hotkey: Codable, Hashable, Sendable {
    var modifiers: Set<Modifier>
    var key: String

    var keyCode: CGKeyCode? { KeyCode.from(key) }
}

enum Action: Equatable, Sendable {
    case focusSpace(Int)
    case moveWindowToSpace(Int)
    case moveWindowToSpaceNext
    case moveWindowToSpacePrev
    case moveWindowToSpaceAndReturn(Int)
    case moveWindowToSpaceNextAndReturn
    case moveWindowToSpacePrevAndReturn
    case focusSpaceNext
    case focusSpacePrev
    case toggleTiling
    case balanceWindows
    case increaseSplitRatio
    case decreaseSplitRatio
    /// Bring the app's most recent window to front (switching to its space),
    /// or launch the app. Value: bundle identifier.
    case focusApp(String)
    /// Move the app's most recent window onto the current space and focus it,
    /// or launch the app. Value: bundle identifier.
    case pullApp(String)
    /// Re-read the settings file and restart every service, e.g. after the
    /// menu bar or Dock changed size.
    case reloadFloe
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusSpace, moveWindowToSpace
        case moveWindowToSpaceNext, moveWindowToSpacePrev
        case moveWindowToSpaceAndReturn
        case moveWindowToSpaceNextAndReturn, moveWindowToSpacePrevAndReturn
        case focusSpaceNext, focusSpacePrev
        case toggleTiling, balanceWindows
        case increaseSplitRatio, decreaseSplitRatio
        case focusApp, pullApp
        case reloadFloe
    }

    init(from decoder: Decoder) throws {
        // Keyed container: { focusSpace: 1 } or { moveWindowToSpace: 2 }
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            if let v = try keyed.decodeIfPresent(Int.self, forKey: .focusSpace) {
                self = .focusSpace(v); return
            }
            if let v = try keyed.decodeIfPresent(Int.self, forKey: .moveWindowToSpace) {
                self = .moveWindowToSpace(v); return
            }
            if let v = try keyed.decodeIfPresent(Int.self, forKey: .moveWindowToSpaceAndReturn) {
                self = .moveWindowToSpaceAndReturn(v); return
            }
            if let v = try keyed.decodeIfPresent(String.self, forKey: .focusApp) {
                self = .focusApp(v); return
            }
            if let v = try keyed.decodeIfPresent(String.self, forKey: .pullApp) {
                self = .pullApp(v); return
            }
            if keyed.contains(.moveWindowToSpaceNext) { self = .moveWindowToSpaceNext; return }
            if keyed.contains(.moveWindowToSpacePrev) { self = .moveWindowToSpacePrev; return }
            if keyed.contains(.moveWindowToSpaceNextAndReturn) { self = .moveWindowToSpaceNextAndReturn; return }
            if keyed.contains(.moveWindowToSpacePrevAndReturn) { self = .moveWindowToSpacePrevAndReturn; return }
            if keyed.contains(.focusSpaceNext) { self = .focusSpaceNext; return }
            if keyed.contains(.focusSpacePrev) { self = .focusSpacePrev; return }
            if keyed.contains(.toggleTiling) { self = .toggleTiling; return }
            if keyed.contains(.balanceWindows) { self = .balanceWindows; return }
            if keyed.contains(.increaseSplitRatio) { self = .increaseSplitRatio; return }
            if keyed.contains(.decreaseSplitRatio) { self = .decreaseSplitRatio; return }
            if keyed.contains(.reloadFloe) { self = .reloadFloe; return }
        }

        // Plain string for parameterless actions
        if let single = try? decoder.singleValueContainer(),
           let str = try? single.decode(String.self) {
            switch str {
            case "moveWindowToSpaceNext": self = .moveWindowToSpaceNext; return
            case "moveWindowToSpacePrev": self = .moveWindowToSpacePrev; return
            case "moveWindowToSpaceNextAndReturn": self = .moveWindowToSpaceNextAndReturn; return
            case "moveWindowToSpacePrevAndReturn": self = .moveWindowToSpacePrevAndReturn; return
            case "focusSpaceNext": self = .focusSpaceNext; return
            case "focusSpacePrev": self = .focusSpacePrev; return
            case "toggleTiling": self = .toggleTiling; return
            case "balanceWindows": self = .balanceWindows; return
            case "increaseSplitRatio": self = .increaseSplitRatio; return
            case "decreaseSplitRatio": self = .decreaseSplitRatio; return
            case "reloadFloe": self = .reloadFloe; return
            default: break
            }
        }

        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown action format")
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .focusSpace(let i):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(i, forKey: .focusSpace)
        case .moveWindowToSpace(let i):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(i, forKey: .moveWindowToSpace)
        case .moveWindowToSpaceAndReturn(let i):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(i, forKey: .moveWindowToSpaceAndReturn)
        case .moveWindowToSpaceNext:
            var c = encoder.singleValueContainer()
            try c.encode("moveWindowToSpaceNext")
        case .moveWindowToSpacePrev:
            var c = encoder.singleValueContainer()
            try c.encode("moveWindowToSpacePrev")
        case .moveWindowToSpaceNextAndReturn:
            var c = encoder.singleValueContainer()
            try c.encode("moveWindowToSpaceNextAndReturn")
        case .moveWindowToSpacePrevAndReturn:
            var c = encoder.singleValueContainer()
            try c.encode("moveWindowToSpacePrevAndReturn")
        case .focusSpaceNext:
            var c = encoder.singleValueContainer()
            try c.encode("focusSpaceNext")
        case .focusSpacePrev:
            var c = encoder.singleValueContainer()
            try c.encode("focusSpacePrev")
        case .toggleTiling:
            var c = encoder.singleValueContainer()
            try c.encode("toggleTiling")
        case .balanceWindows:
            var c = encoder.singleValueContainer()
            try c.encode("balanceWindows")
        case .increaseSplitRatio:
            var c = encoder.singleValueContainer()
            try c.encode("increaseSplitRatio")
        case .decreaseSplitRatio:
            var c = encoder.singleValueContainer()
            try c.encode("decreaseSplitRatio")
        case .reloadFloe:
            var c = encoder.singleValueContainer()
            try c.encode("reloadFloe")
        case .focusApp(let bundleID):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bundleID, forKey: .focusApp)
        case .pullApp(let bundleID):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bundleID, forKey: .pullApp)
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Sendable {
    var hotkey: Hotkey
    var action: Action
}

struct HotkeysConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var bindings: [HotkeyBinding]

    /// Ctrl+N switches to desktop N (the shortcut macOS users already know),
    /// Ctrl+Shift+N sends the focused window there, Ctrl+Option+R reloads Floe.
    static let `default` = HotkeysConfig(
        enabled: true,
        bindings: (1...9).flatMap { n in [
            HotkeyBinding(hotkey: Hotkey(modifiers: [.ctrl], key: "\(n)"), action: .focusSpace(n)),
            HotkeyBinding(hotkey: Hotkey(modifiers: [.ctrl, .shift], key: "\(n)"), action: .moveWindowToSpaceAndReturn(n)),
        ] } + [reloadBinding]
    )

    static let reloadBinding = HotkeyBinding(hotkey: Hotkey(modifiers: [.ctrl, .alt], key: "r"), action: .reloadFloe)
}

// MARK: - Tiling

struct TilingGaps: Codable, Equatable, Sendable {
    var inner: Int
    var outer: Int

    static let `default` = TilingGaps(inner: 8, outer: 8)
}

struct TilingRule: Codable, Equatable, Sendable {
    var app: String
    var tiled: Bool
}

struct TilingConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var gaps: TilingGaps
    var splitRatio: Double
    var autoBalance: Bool
    var rules: [TilingRule]

    static let `default` = TilingConfig(
        enabled: true,
        gaps: .default,
        splitRatio: 0.5,
        autoBalance: true,
        rules: []
    )
}

// MARK: - App Switcher

/// One fn-key app shortcut: fn+key focuses the app, fn+shift+key pulls it
/// onto the current space.
struct AppShortcut: Codable, Equatable, Sendable {
    var key: String
    var bundleID: String
    var name: String
}

struct AppSwitcherConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var apps: [AppShortcut]

    /// The hotkey bindings these shortcuts expand to.
    var bindings: [HotkeyBinding] {
        guard enabled else { return [] }
        return apps.flatMap { app in [
            HotkeyBinding(hotkey: Hotkey(modifiers: [.fn], key: app.key), action: .focusApp(app.bundleID)),
            HotkeyBinding(hotkey: Hotkey(modifiers: [.fn, .shift], key: app.key), action: .pullApp(app.bundleID)),
        ] }
    }

    static let `default` = AppSwitcherConfig(
        enabled: false,
        apps: [
            AppShortcut(key: "s", bundleID: "com.spotify.client", name: "Spotify"),
            AppShortcut(key: "b", bundleID: "com.apple.Safari", name: "Safari"),
            AppShortcut(key: "g", bundleID: "com.google.Chrome", name: "Google Chrome"),
            AppShortcut(key: "c", bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
            AppShortcut(key: "t", bundleID: "com.apple.Terminal", name: "Terminal"),
            AppShortcut(key: "f", bundleID: "com.apple.finder", name: "Finder"),
            AppShortcut(key: "d", bundleID: "com.hnc.Discord", name: "Discord"),
            AppShortcut(key: "o", bundleID: "com.microsoft.Outlook", name: "Microsoft Outlook"),
            AppShortcut(key: "m", bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
            AppShortcut(key: "e", bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
            AppShortcut(key: "n", bundleID: "md.obsidian", name: "Obsidian"),
            AppShortcut(key: "p", bundleID: "com.postmanlabs.mac", name: "Postman"),
            AppShortcut(key: "l", bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        ]
    )
}

// MARK: - Desktop Layouts

/// How many desktops each monitor gets for a given number of connected monitors.
struct DesktopLayout: Codable, Equatable, Sendable {
    /// Number of connected monitors this layout applies to.
    var monitors: Int
    /// Desktop count per monitor, in monitor order (main display first).
    var desktops: [Int]

    var totalDesktops: Int { desktops.reduce(0, +) }

    /// 1-based desktop numbers on the given 0-based monitor.
    func desktopRange(forMonitor index: Int) -> ClosedRange<Int>? {
        guard desktops.indices.contains(index), desktops[index] > 0 else { return nil }
        let start = desktops.prefix(index).reduce(0, +) + 1
        return start...(start + desktops[index] - 1)
    }
}

struct DesktopLayoutsConfig: Codable, Equatable, Sendable {
    /// When on, Floe creates/removes desktops so each monitor matches the
    /// layout for the current monitor count, and moves windows back to their
    /// desktops when monitors are reconnected.
    var enabled: Bool
    var layouts: [DesktopLayout]

    func layout(forMonitorCount count: Int) -> DesktopLayout? {
        layouts.first { $0.monitors == count && $0.desktops.count == count }
    }

    static let `default` = DesktopLayoutsConfig(
        enabled: false,
        layouts: [
            DesktopLayout(monitors: 1, desktops: [9]),
            DesktopLayout(monitors: 2, desktops: [9, 9]),
            DesktopLayout(monitors: 3, desktops: [9, 6, 6]),
        ]
    )
}

// MARK: - Top-Level Configuration

struct Configuration: Equatable, Sendable {
    var focusFollowsMouse: FocusFollowsMouseConfig
    var hotkeys: HotkeysConfig
    var tiling: TilingConfig
    var desktopLayouts: DesktopLayoutsConfig
    var appSwitcher: AppSwitcherConfig
    var debug: Bool

    static let `default` = Configuration(
        focusFollowsMouse: .default,
        hotkeys: .default,
        tiling: .default,
        desktopLayouts: .default,
        appSwitcher: .default,
        debug: false
    )
}

extension Configuration: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusFollowsMouse, hotkeys, tiling, desktopLayouts, appSwitcher, debug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusFollowsMouse = try c.decodeIfPresent(FocusFollowsMouseConfig.self, forKey: .focusFollowsMouse) ?? .default
        hotkeys = try c.decodeIfPresent(HotkeysConfig.self, forKey: .hotkeys) ?? .default
        tiling = try c.decodeIfPresent(TilingConfig.self, forKey: .tiling) ?? .default
        desktopLayouts = try c.decodeIfPresent(DesktopLayoutsConfig.self, forKey: .desktopLayouts) ?? .default
        appSwitcher = try c.decodeIfPresent(AppSwitcherConfig.self, forKey: .appSwitcher) ?? .default
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }
}
