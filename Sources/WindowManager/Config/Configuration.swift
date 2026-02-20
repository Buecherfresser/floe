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
    case focusSpaceNext
    case focusSpacePrev
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusSpace, moveWindowToSpace
        case moveWindowToSpaceNext, moveWindowToSpacePrev
        case focusSpaceNext, focusSpacePrev
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
            if keyed.contains(.moveWindowToSpaceNext) { self = .moveWindowToSpaceNext; return }
            if keyed.contains(.moveWindowToSpacePrev) { self = .moveWindowToSpacePrev; return }
            if keyed.contains(.focusSpaceNext) { self = .focusSpaceNext; return }
            if keyed.contains(.focusSpacePrev) { self = .focusSpacePrev; return }
        }

        // Plain string for parameterless actions
        if let single = try? decoder.singleValueContainer(),
           let str = try? single.decode(String.self) {
            switch str {
            case "moveWindowToSpaceNext": self = .moveWindowToSpaceNext; return
            case "moveWindowToSpacePrev": self = .moveWindowToSpacePrev; return
            case "focusSpaceNext": self = .focusSpaceNext; return
            case "focusSpacePrev": self = .focusSpacePrev; return
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
        case .moveWindowToSpaceNext:
            var c = encoder.singleValueContainer()
            try c.encode("moveWindowToSpaceNext")
        case .moveWindowToSpacePrev:
            var c = encoder.singleValueContainer()
            try c.encode("moveWindowToSpacePrev")
        case .focusSpaceNext:
            var c = encoder.singleValueContainer()
            try c.encode("focusSpaceNext")
        case .focusSpacePrev:
            var c = encoder.singleValueContainer()
            try c.encode("focusSpacePrev")
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

// MARK: - Top-Level Configuration

struct Configuration: Equatable, Sendable {
    var focusFollowsMouse: FocusFollowsMouseConfig
    var hotkeys: HotkeysConfig
    var spaces: SpacesConfig
    var debug: Bool

    static let `default` = Configuration(
        focusFollowsMouse: .default,
        hotkeys: .default,
        spaces: .default,
        debug: false
    )
}

extension Configuration: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusFollowsMouse, hotkeys, spaces, debug
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusFollowsMouse = try c.decodeIfPresent(FocusFollowsMouseConfig.self, forKey: .focusFollowsMouse) ?? .default
        hotkeys = try c.decodeIfPresent(HotkeysConfig.self, forKey: .hotkeys) ?? .default
        spaces = try c.decodeIfPresent(SpacesConfig.self, forKey: .spaces) ?? .default
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }
}
