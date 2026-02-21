import CoreGraphics

/// Maps human-readable key names to macOS virtual key codes.
enum KeyCode {
    static func from(_ name: String) -> CGKeyCode? {
        return keyMap[name.lowercased()]
    }

    static func name(for code: CGKeyCode) -> String? {
        return reverseMap[code]
    }

    private static let keyMap: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]

        // Letters
        let letters: [(String, CGKeyCode)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03),
            ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
            ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C),
            ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
            ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22),
            ("p", 0x23), ("l", 0x25), ("j", 0x26), ("k", 0x28),
            ("n", 0x2D), ("m", 0x2E),
        ]
        for (name, code) in letters { map[name] = code }

        // Numbers
        let numbers: [(String, CGKeyCode)] = [
            ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
            ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C),
            ("9", 0x19), ("0", 0x1D),
        ]
        for (name, code) in numbers { map[name] = code }

        // Punctuation & symbols
        let symbols: [(String, CGKeyCode)] = [
            ("minus", 0x1B), ("-", 0x1B),
            ("equal", 0x18), ("=", 0x18),
            ("leftbracket", 0x21), ("[", 0x21),
            ("rightbracket", 0x1E), ("]", 0x1E),
            ("backslash", 0x2A), ("\\", 0x2A),
            ("semicolon", 0x29), (";", 0x29),
            ("quote", 0x27), ("'", 0x27),
            ("comma", 0x2B), (",", 0x2B),
            ("period", 0x2F), (".", 0x2F),
            ("slash", 0x2C), ("/", 0x2C),
            ("grave", 0x32), ("`", 0x32),
        ]
        for (name, code) in symbols { map[name] = code }

        // Navigation & editing
        let navigation: [(String, CGKeyCode)] = [
            ("return", 0x24), ("enter", 0x24),
            ("tab", 0x30),
            ("space", 0x31),
            ("delete", 0x33), ("backspace", 0x33),
            ("escape", 0x35), ("esc", 0x35),
            ("forwarddelete", 0x75),
            ("home", 0x73),
            ("end", 0x77),
            ("pageup", 0x74),
            ("pagedown", 0x79),
        ]
        for (name, code) in navigation { map[name] = code }

        // Arrow keys
        let arrows: [(String, CGKeyCode)] = [
            ("left", 0x7B), ("right", 0x7C),
            ("down", 0x7D), ("up", 0x7E),
        ]
        for (name, code) in arrows { map[name] = code }

        // Function keys
        let functionKeys: [(String, CGKeyCode)] = [
            ("f1", 0x7A), ("f2", 0x78), ("f3", 0x63), ("f4", 0x76),
            ("f5", 0x60), ("f6", 0x61), ("f7", 0x62), ("f8", 0x64),
            ("f9", 0x65), ("f10", 0x6D), ("f11", 0x67), ("f12", 0x6F),
        ]
        for (name, code) in functionKeys { map[name] = code }

        return map
    }()

    private static let reverseMap: [CGKeyCode: String] = {
        var map: [CGKeyCode: String] = [:]
        let preferred: [(CGKeyCode, String)] = [
            (0x00, "a"), (0x01, "s"), (0x02, "d"), (0x03, "f"),
            (0x04, "h"), (0x05, "g"), (0x06, "z"), (0x07, "x"),
            (0x08, "c"), (0x09, "v"), (0x0B, "b"), (0x0C, "q"),
            (0x0D, "w"), (0x0E, "e"), (0x0F, "r"), (0x10, "y"),
            (0x11, "t"), (0x1F, "o"), (0x20, "u"), (0x22, "i"),
            (0x23, "p"), (0x25, "l"), (0x26, "j"), (0x28, "k"),
            (0x2D, "n"), (0x2E, "m"),
            (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"),
            (0x17, "5"), (0x16, "6"), (0x1A, "7"), (0x1C, "8"),
            (0x19, "9"), (0x1D, "0"),
            (0x24, "return"), (0x30, "tab"), (0x31, "space"),
            (0x33, "delete"), (0x35, "escape"),
            (0x7B, "left"), (0x7C, "right"), (0x7D, "down"), (0x7E, "up"),
        ]
        for (code, name) in preferred { map[code] = name }
        return map
    }()
}
