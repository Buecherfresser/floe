import Foundation
import CoreGraphics

// MARK: - Focus Follows Mouse

struct FocusFollowsMouseConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var delay: Int
    var ignoreApps: [String]

    static let `default` = FocusFollowsMouseConfig(
        enabled: true,
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

    var cgFlag: CGEventFlags {
        switch self {
        case .alt:   return .maskAlternate
        case .shift: return .maskShift
        case .ctrl:  return .maskControl
        case .cmd:   return .maskCommand
        }
    }

    static func flags(from set: Set<Modifier>) -> CGEventFlags {
        var flags = CGEventFlags()
        for mod in set { flags.insert(mod.cgFlag) }
        return flags
    }

    /// Relevant modifier mask for matching (ignoring caps lock, num lock, etc.)
    static let relevantMask = CGEventFlags([
        .maskAlternate, .maskShift, .maskControl, .maskCommand,
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

    static let `default` = HotkeysConfig(enabled: false, bindings: [])
}

// MARK: - Spaces

/// Strategy for moving windows between spaces.
enum SpaceMoveMethod: String, Codable, Equatable, Sendable {
    /// Try CGS private APIs first; fall back to mouse-drag simulation.
    case auto
    /// Always use mouse-drag simulation (works without SIP).
    case mouseDrag
    /// Always use CGS private APIs (requires SIP disabled on macOS 15+).
    case cgsPrivateAPI
}

struct SpacesConfig: Codable, Equatable, Sendable {
    var moveMethod: SpaceMoveMethod

    static let `default` = SpacesConfig(moveMethod: .mouseDrag)
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
        enabled: false,
        gaps: .default,
        splitRatio: 0.5,
        autoBalance: true,
        rules: []
    )
}

// MARK: - Top-Level Configuration

struct Configuration: Equatable, Sendable {
    var focusFollowsMouse: FocusFollowsMouseConfig
    var hotkeys: HotkeysConfig
    var spaces: SpacesConfig
    var tiling: TilingConfig
    var debug: Bool

    static let `default` = Configuration(
        focusFollowsMouse: .default,
        hotkeys: .default,
        spaces: .default,
        tiling: .default,
        debug: false
    )
}

extension Configuration: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusFollowsMouse, hotkeys, spaces, tiling, debug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusFollowsMouse = try c.decodeIfPresent(FocusFollowsMouseConfig.self, forKey: .focusFollowsMouse) ?? .default
        hotkeys = try c.decodeIfPresent(HotkeysConfig.self, forKey: .hotkeys) ?? .default
        spaces = try c.decodeIfPresent(SpacesConfig.self, forKey: .spaces) ?? .default
        tiling = try c.decodeIfPresent(TilingConfig.self, forKey: .tiling) ?? .default
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }
}
