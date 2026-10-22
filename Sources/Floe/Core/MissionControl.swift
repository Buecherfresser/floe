@preconcurrency import ApplicationServices
import AppKit

/// Creates and removes desktops by driving Mission Control's own controls
/// through Accessibility. Going through the Dock keeps its space model in sync —
/// SkyLight's bridged space operations only update WindowServer and leave
/// Mission Control showing a stale layout.
///
/// Mission Control exposes language-independent identifiers:
///
///     AXGroup id=mc
///       AXGroup id=mc.display            (one per display)
///         AXGroup id=mc.spaces
///           AXList id=mc.spaces.list     (desktop buttons, action AXRemoveDesktop)
///           AXButton id=mc.spaces.add    ("add desktop")
enum MissionControl {

    fileprivate static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    nonisolated(unsafe) private static var busy = false
    private static let busyLock = NSLock()

    /// While Floe drives Mission Control, activating apps would dismiss it.
    static var isBusy: Bool { busyLock.withLock { busy } }
    fileprivate static let openTimeout: TimeInterval = 2.0
    private static let settleDelay: useconds_t = 350_000 // 350 ms for the Dock to animate a change

    /// Opens Mission Control, runs `body`, and closes it again. Returns `false`
    /// if Mission Control didn't open. Blocks — call off the main thread.
    @discardableResult
    static func perform(_ body: (Session) -> Void) -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            Log.error("MissionControl: Dock not running")
            return false
        }
        let windowManager = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first
        let session = Session(
            dock: AXUIElementCreateApplication(dock.processIdentifier),
            windowManager: windowManager.map { AXUIElementCreateApplication($0.processIdentifier) }
        )
        busyLock.withLock { busy = true }
        defer { busyLock.withLock { busy = false } }

        if session.root() == nil {
            NSWorkspace.shared.open(appURL)
        }
        guard session.waitUntil({ $0.root() != nil }, timeout: openTimeout) else {
            Log.error("MissionControl: did not open")
            Compatibility.record(.missionControl, ok: false)
            return false
        }

        body(session)

        NSWorkspace.shared.open(appURL)
        _ = session.waitUntil({ $0.root() == nil }, timeout: openTimeout)
        usleep(settleDelay)
        return true
    }

    final class Session {
        private let dock: AXUIElement
        private let windowManager: AXUIElement?

        fileprivate init(dock: AXUIElement, windowManager: AXUIElement?) {
            self.dock = dock
            self.windowManager = windowManager
        }

        /// Appends a desktop to the display whose Mission Control area
        /// contains `point` (CG global coordinates).
        @discardableResult
        func addDesktop(onDisplayContaining point: CGPoint) -> Bool {
            guard let add = findInDisplay(containing: point, identifier: "mc.spaces.add") else {
                Log.error("MissionControl: no add-desktop button for display at \(point)")
                Compatibility.record(.missionControl, ok: false)
                return false
            }
            Compatibility.record(.missionControl, ok: true)
            let result = AXUIElementPerformAction(add, kAXPressAction as CFString)
            usleep(settleDelay)
            Log.info("MissionControl: add desktop at \(point) -> \(result.rawValue)")
            return result == .success
        }

        /// Removes the desktop at `index` (Mission Control order on that
        /// display, fullscreen spaces included).
        @discardableResult
        func removeDesktop(onDisplayContaining point: CGPoint, at index: Int) -> Bool {
            guard let list = findInDisplay(containing: point, identifier: "mc.spaces.list") else {
                Log.error("MissionControl: no desktop list for display at \(point)")
                Compatibility.record(.missionControl, ok: false)
                return false
            }
            Compatibility.record(.missionControl, ok: true)
            let buttons = children(of: list)
            guard buttons.indices.contains(index) else {
                Log.error("MissionControl: no desktop at index \(index) (have \(buttons.count))")
                return false
            }
            let result = AXUIElementPerformAction(buttons[index], "AXRemoveDesktop" as CFString)
            usleep(settleDelay)
            Log.info("MissionControl: remove desktop \(index) at \(point) -> \(result.rawValue)")
            return result == .success
        }

        // MARK: AX lookup

        /// Mission Control re-lays out (and may even close) while desktops are
        /// added or removed — retry for a moment, reopening it if needed.
        private func findInDisplay(containing point: CGPoint, identifier target: String) -> AXUIElement? {
            let deadline = Date().addingTimeInterval(1.0)
            repeat {
                if root() == nil {
                    NSWorkspace.shared.open(MissionControl.appURL)
                    _ = waitUntil({ $0.root() != nil }, timeout: MissionControl.openTimeout)
                }
                if let display = display(containing: point),
                   let element = descendant(of: display, identifier: target) {
                    return element
                }
                usleep(50_000)
            } while Date() < deadline
            return nil
        }

        /// The element holding one `mc.display` per display while Mission
        /// Control is open. macOS 26 shows Mission Control in the Dock; macOS 27
        /// shows it in WindowManager, with the same identifiers but without the
        /// "mc" group, and leaves an empty "mc" group in the Dock.
        fileprivate func root() -> AXUIElement? {
            if let mc = children(of: dock).first(where: { identifier(of: $0) == "mc" }),
               !children(of: mc).isEmpty {
                return mc
            }
            if let windowManager,
               children(of: windowManager).contains(where: { identifier(of: $0) == "mc.display" }) {
                return windowManager
            }
            return nil
        }

        private func display(containing point: CGPoint) -> AXUIElement? {
            guard let root = root() else { return nil }
            return children(of: root)
                .filter { identifier(of: $0) == "mc.display" }
                .first { frame(of: $0)?.contains(point) ?? false }
        }

        private func descendant(of element: AXUIElement, identifier target: String, depth: Int = 4) -> AXUIElement? {
            for child in children(of: element) {
                if identifier(of: child) == target { return child }
                if depth > 0, let found = descendant(of: child, identifier: target, depth: depth - 1) {
                    return found
                }
            }
            return nil
        }

        fileprivate func waitUntil(_ condition: (Session) -> Bool, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition(self) { return true }
                usleep(20_000)
            }
            return condition(self)
        }

        private func children(of element: AXUIElement) -> [AXUIElement] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
            return ref as? [AXUIElement] ?? []
        }

        private func identifier(of element: AXUIElement) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &ref) == .success else { return nil }
            return ref as? String
        }

        private func frame(of element: AXUIElement) -> CGRect? {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posRef, let sizeRef,
                  CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            return CGRect(origin: origin, size: size)
        }
    }
}
