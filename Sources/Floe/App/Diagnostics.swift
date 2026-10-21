@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Developer diagnostics, run instead of the app when launched with
/// `--diag <command> [args…] --out <file>`.
///
/// Launch through LaunchServices so the process runs with Floe's own
/// Accessibility grant (a process spawned from a terminal inherits the
/// terminal's TCC identity instead):
///
///     open -n -g /Applications/Floe.app --args --diag spaces --out /tmp/floe-diag.txt
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum Diagnostics {

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let diagIndex = args.firstIndex(of: "--diag") else { return }

        var command = Array(args[(diagIndex + 1)...])
        var outPath = NSTemporaryDirectory() + "floe-diag.txt"
        if let outIndex = command.firstIndex(of: "--out"), outIndex + 1 < command.count {
            outPath = command[outIndex + 1]
            command.removeSubrange(outIndex...(outIndex + 1))
        }

        var output = "trusted=\(AXIsProcessTrusted())\n"
        output += run(command)
        try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func run(_ command: [String]) -> String {
        switch command.first {
        case "spaces":
            return spaces()
        case "windows":
            return windows(appName: command.dropFirst().joined(separator: " "))
        case "ax-tree":
            let depth = command.count > 2 ? Int(command[2]) ?? 6 : 6
            return axTree(appName: command.count > 1 ? command[1] : "Dock", depth: depth)
        case "mission-control":
            let depth = command.count > 1 ? Int(command[1]) ?? 8 : 8
            return missionControlTree(depth: depth)
        case "monitors":
            return Monitors.ordered().enumerated().map { i, m in
                "monitor \(i + 1): \(m.name) uuid=\(m.uuid) bounds=\(m.bounds) main=\(m.isMain)"
            }.joined(separator: "\n") + "\n"
        case "mc-add":
            // mc-add <monitor number>
            guard command.count > 1, let monitor = monitor(command[1]) else { return "usage: mc-add <monitor>\n" }
            var ok = false
            MissionControl.perform { ok = $0.addDesktop(onDisplayContaining: monitor.center) }
            return "add=\(ok)\n" + spaces()
        case "mc-remove":
            // mc-remove <monitor number> <mission control index>
            guard command.count > 2, let monitor = monitor(command[1]), let index = Int(command[2]) else {
                return "usage: mc-remove <monitor> <index>\n"
            }
            var ok = false
            MissionControl.perform { ok = $0.removeDesktop(onDisplayContaining: monitor.center, at: index) }
            return "remove=\(ok)\n" + spaces()
        case "focus-app", "pull-app":
            guard command.count > 1 else { return "usage: \(command[0]) <bundle id>\n" }
            let service = MainActor.assumeIsolated { SpacesService(accessibilityService: AccessibilityService()) }
            let done = DispatchSemaphore(value: 0)
            if command[0] == "focus-app" {
                service.focusApp(bundleID: command[1]) { done.signal() }
            } else {
                service.pullApp(bundleID: command[1]) { done.signal() }
            }
            done.wait()
            Thread.sleep(forTimeInterval: 0.3)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            return "frontmost=\(front) active=\(CGSSpaceService.currentSpaceID())\n" + spaces()
        case "move-window":
            // move-window <window id> <space id>
            guard command.count > 2, let wid = CGWindowID(command[1]), let sid = CGSSpaceID(command[2]) else {
                return "usage: move-window <wid> <sid>\n"
            }
            return "moved=\(CGSSpaceService.moveWindow(wid, toSpace: sid))\n"
        case "focus-desktop":
            guard command.count > 1, let n = Int(command[1]) else { return "usage: focus-desktop <n>\n" }
            let service = MainActor.assumeIsolated { SpacesService(accessibilityService: AccessibilityService()) }
            service.focusSpace(at: n)
            Thread.sleep(forTimeInterval: 0.8)
            let cursor = CGEvent(source: nil)?.location ?? .zero
            return "active=\(CGSSpaceService.currentSpaceID()) cursor=\(cursor) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n" + spaces()
        case "mouse-drag":
            // mouse-drag x1 y1 x2 y2 [ctrl] — press, drag in steps, release
            guard command.count > 4, let x1 = Double(command[1]), let y1 = Double(command[2]),
                  let x2 = Double(command[3]), let y2 = Double(command[4]) else {
                return "usage: mouse-drag x1 y1 x2 y2 [ctrl]\n"
            }
            let flags: CGEventFlags = command.count > 5 && command[5] == "ctrl" ? .maskControl : []
            postDrag(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2), flags: flags)
            return "dragged\n"
        case "move-focused":
            // move-focused <desktop> [follow]
            guard command.count > 1, let n = Int(command[1]) else { return "usage: move-focused <n> [follow]\n" }
            let service = MainActor.assumeIsolated { SpacesService(accessibilityService: AccessibilityService()) }
            let done = DispatchSemaphore(value: 0)
            if command.count > 2 && command[2] == "follow" {
                service.moveWindowToSpace(at: n) { done.signal() }
            } else {
                service.moveWindowToSpaceAndReturn(at: n) { done.signal() }
            }
            done.wait()
            Thread.sleep(forTimeInterval: 0.5)
            return "active=\(CGSSpaceService.currentSpaceID()) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")\n"
        case "set-frame":
            // set-frame <app name> x y w h — sets the app's first window frame
            guard command.count > 5, let x = Double(command[2]), let y = Double(command[3]),
                  let w = Double(command[4]), let h = Double(command[5]),
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == command[1] }) else {
                return "usage: set-frame <app> x y w h\n"
            }
            guard let window = children(of: AXUIElementCreateApplication(app.processIdentifier), attribute: kAXWindowsAttribute).first else {
                return "no window\n"
            }
            let service = MainActor.assumeIsolated { AccessibilityService() }
            service.setWindowFrame(element: window, frame: CGRect(x: x, y: y, width: w, height: h))
            var out = ""
            for i in 0..<12 {
                if let f = service.windowFrame(of: window) { out += "t+\(i * 100)ms \(f)\n" }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return out
        case "untile":
            guard command.count > 1,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == command[1] }),
                  let window = children(of: AXUIElementCreateApplication(app.processIdentifier), attribute: kAXWindowsAttribute)
                    .first(where: { stringAttribute($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }) else { return "no window\n" }
            let service = MainActor.assumeIsolated { AccessibilityService() }
            let before = service.windowFrame(of: window)
            let ok = service.untileWindow(window, pid: app.processIdentifier)
            Thread.sleep(forTimeInterval: 0.5)
            return "untile=\(ok) before=\(before.map { "\($0)" } ?? "?") after=\(service.windowFrame(of: window).map { "\($0)" } ?? "?")\n"
        case "unfullscreen", "zoom-window":
            // unfullscreen <app> — leave fullscreen; zoom-window <app> — AXZoomWindow
            guard command.count > 1,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == command[1] }),
                  let window = children(of: AXUIElementCreateApplication(app.processIdentifier), attribute: kAXWindowsAttribute)
                    .first(where: { stringAttribute($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }) else { return "no window\n" }
            let service = MainActor.assumeIsolated { AccessibilityService() }
            var result: AXError
            if command[0] == "unfullscreen" {
                result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            } else if let zoom = elementAttribute(window, kAXZoomButtonAttribute) {
                result = AXUIElementPerformAction(zoom, "AXZoomWindow" as CFString)
            } else { return "no zoom button\n" }
            var out = "result=\(result.rawValue)\n"
            for i in 0..<15 {
                out += "t+\(i * 100)ms \(service.windowFrame(of: window).map { "\($0)" } ?? "?") fullscreen=\(service.isFullScreen(window))\n"
                Thread.sleep(forTimeInterval: 0.1)
            }
            return out
        case "zoom":
            // zoom <app name> — presses the first window's zoom button
            guard command.count > 1,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == command[1] }),
                  let window = children(of: AXUIElementCreateApplication(app.processIdentifier), attribute: kAXWindowsAttribute).first,
                  let zoom = elementAttribute(window, kAXZoomButtonAttribute) else { return "no zoom button\n" }
            var actionsRef: CFArray?
            AXUIElementCopyActionNames(zoom, &actionsRef)
            let result = AXUIElementPerformAction(zoom, kAXPressAction as CFString)
            let service = MainActor.assumeIsolated { AccessibilityService() }
            var out = "actions=\(actionsRef as? [String] ?? []) press=\(result.rawValue)\n"
            for i in 0..<10 {
                out += "t+\(i * 100)ms \(service.windowFrame(of: window).map { "\($0)" } ?? "?") fullscreen=\(service.isFullScreen(window))\n"
                Thread.sleep(forTimeInterval: 0.1)
            }
            return out
        default:
            return "unknown command \(command)\n"
        }
    }

    // MARK: - Commands

    private static func monitor(_ number: String) -> (center: CGPoint, name: String)? {
        let monitors = Monitors.ordered()
        guard let n = Int(number), monitors.indices.contains(n - 1) else { return nil }
        let m = monitors[n - 1]
        return (CGPoint(x: m.bounds.midX, y: m.bounds.midY), m.name)
    }

    private static func spaces() -> String {
        CGSSpaceService.displays().map { display in
            let ids = display.spaces.map { "\($0.id)\($0.isUser ? "" : "(fs)")" }.joined(separator: ",")
            return "\(display.identifier) current=\(display.currentSpace) [\(ids)]"
        }.joined(separator: "\n") + "\n"
    }

    private static func windows(appName: String) -> String {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return "no running app named \(appName)\n"
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var out = ""
        for window in children(of: ax, attribute: kAXWindowsAttribute) {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
            let zoom = elementAttribute(window, kAXZoomButtonAttribute)
            let zoomEnabled = zoom.flatMap { stringAttribute($0, kAXEnabledAttribute) } ?? "none"
            var wid: CGWindowID = 0
            let widResult = _AXUIElementGetWindow(window, &wid)
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var origin = CGPoint.zero
            var size = CGSize.zero
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success, let posRef {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
            }
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success, let sizeRef {
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            }
            out += "window wid=\(wid)(\(widResult.rawValue)) frame=(\(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))) title=\(stringAttribute(window, kAXTitleAttribute) ?? "") "
                + "subrole=\(stringAttribute(window, kAXSubroleAttribute) ?? "") "
                + "sizeSettable=\(settable.boolValue) zoomEnabled=\(zoomEnabled)\n"
        }
        return out
    }

    private static func axTree(appName: String, depth: Int) -> String {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return "no running app named \(appName)\n"
        }
        var out = ""
        dump(AXUIElementCreateApplication(app.processIdentifier), depth: depth, indent: 0, into: &out)
        return out
    }

    /// Opens Mission Control, dumps the Dock's accessibility tree, closes it again.
    private static func missionControlTree(depth: Int) -> String {
        let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.open(missionControl)
        Thread.sleep(forTimeInterval: 1.0)
        let tree = axTree(appName: "Dock", depth: depth)
        NSWorkspace.shared.open(missionControl)
        Thread.sleep(forTimeInterval: 0.5)
        return tree
    }

    private static func postDrag(from start: CGPoint, to end: CGPoint, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        post(.leftMouseDown, start)
        usleep(80_000)
        let steps = 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            usleep(25_000)
        }
        usleep(150_000)
        post(.leftMouseUp, end)
        usleep(500_000)
    }

    // MARK: - AX Helpers

    private static func dump(_ element: AXUIElement, depth: Int, indent: Int, into out: inout String) {
        var actionsRef: CFArray?
        AXUIElementCopyActionNames(element, &actionsRef)
        let actions = (actionsRef as? [String])?.joined(separator: ",") ?? ""

        let fields = [
            ("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute),
            ("desc", kAXDescriptionAttribute), ("id", kAXIdentifierAttribute), ("value", kAXValueAttribute),
            ("enabled", kAXEnabledAttribute),
        ].compactMap { name, attr in stringAttribute(element, attr).map { "\(name)=\($0)" } }

        out += String(repeating: "  ", count: indent) + fields.joined(separator: " ")
            + (actions.isEmpty ? "" : " actions=[\(actions)]") + "\n"

        guard depth > 0 else { return }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            dump(child, depth: depth - 1, indent: indent + 1, into: &out)
        }
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }
}
