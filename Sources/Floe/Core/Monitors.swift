import AppKit
import CoreGraphics

/// A connected, non-mirrored display.
struct Monitor: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    /// Matches `ManagedDisplay.identifier` when "Displays have separate Spaces" is on.
    let uuid: String
    let name: String
    /// Bounds in CG global coordinates (origin top-left of the primary display).
    let bounds: CGRect
    let isMain: Bool
}

enum Monitors {

    /// Connected monitors in Floe's order: the main display (the one with
    /// the menu bar in System Settings › Displays) first, then the rest left
    /// to right, top to bottom. Desktop numbers follow this order.
    static func ordered() -> [Monitor] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }

        let names = Dictionary(
            NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                return (id, screen.localizedName)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let monitors = ids.prefix(Int(count)).compactMap { id -> Monitor? in
            // Mirrored displays share a space with the display they mirror.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = uuidString(for: id) else { return nil }
            return Monitor(
                displayID: id,
                uuid: uuid,
                name: names[id] ?? "Display \(id)",
                bounds: CGDisplayBounds(id),
                isMain: CGDisplayIsMain(id) != 0
            )
        }

        return monitors.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.bounds.minX != b.bounds.minX { return a.bounds.minX < b.bounds.minX }
            return a.bounds.minY < b.bounds.minY
        }
    }

    static func monitor(withUUID uuid: String) -> Monitor? {
        ordered().first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
