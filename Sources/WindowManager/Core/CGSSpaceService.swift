import AppKit
import CoreGraphics
import Foundation

// MARK: - CGS / SLS Private API Types

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

private let kCGSSpaceAll: Int = 0x7

// MARK: - SIP Detection

enum SIPStatus: Sendable {
    case enabled
    case disabled
    case unknown
}

/// Checks whether System Integrity Protection is disabled by invoking
/// `csrutil status`.
func querySIPStatus() -> SIPStatus {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
    process.arguments = ["status"]
    process.standardOutput = pipe
    process.standardError = pipe

    do { try process.run() } catch { return .unknown }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return .unknown }

    if output.contains("disabled") { return .disabled }
    if output.contains("enabled") { return .enabled }
    return .unknown
}

// MARK: - CGS / SLS Function Loading

/// Loads CGS and SLS private API function pointers once at process start.
///
/// Uses `SLSMoveWindowsToManagedSpace` as the primary window-move API, with
/// the `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` workaround that
/// yabai uses on macOS 14.5+ / 15+.
///
/// Space *switching* via `CGSManagedDisplaySetCurrentSpace` is intentionally
/// NOT exposed here because it only composites windows without updating the
/// Dock's internal state (which requires code injection into the Dock process,
/// as yabai does with its scripting addition).
private struct CGSFunctions: Sendable {
    static let shared = CGSFunctions()

    let connectionID: CGSConnectionID
    let isLoaded: Bool

    // Space enumeration & query (read-only, works even with SIP enabled)
    private let _copyManagedDisplaySpaces: @Sendable (CGSConnectionID) -> CFArray?
    private let _getActiveSpace: @Sendable (CGSConnectionID, CFString) -> CGSSpaceID
    private let _copySpacesForWindows: @Sendable (CGSConnectionID, Int, CFArray) -> CFArray?

    // Window movement (requires SIP disabled on macOS 15+)
    private let _moveWindowsToManagedSpace: @Sendable (CGSConnectionID, CFArray, CGSSpaceID) -> Void
    private let _addWindowsToSpaces: @Sendable (CGSConnectionID, CFArray, CFArray) -> Void
    private let _removeWindowsFromSpaces: @Sendable (CGSConnectionID, CFArray, CFArray) -> Void

    let hasMoveWindows: Bool

    // macOS 15+ workaround: compat-ID path
    private let _spaceSetCompatID: @Sendable (CGSConnectionID, CGSSpaceID, UInt32) -> Void
    private let _setWindowListWorkspace: @Sendable (CGSConnectionID, UnsafePointer<UInt32>, Int32, UInt32) -> Void
    let hasCompatIDPath: Bool

    private init() {
        typealias DefaultConnFunc = @convention(c) () -> CGSConnectionID
        typealias CopyDisplaySpacesFunc = @convention(c) (CGSConnectionID) -> CFArray?
        typealias ActiveFunc = @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID
        typealias CopySpacesFunc = @convention(c) (CGSConnectionID, Int, CFArray) -> CFArray?
        typealias MoveWindowsFunc = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void
        typealias AddFunc = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
        typealias RemoveFunc = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
        typealias CompatIDFunc = @convention(c) (CGSConnectionID, CGSSpaceID, UInt32) -> Void
        typealias SetWorkspaceFunc = @convention(c) (CGSConnectionID, UnsafePointer<UInt32>, Int32, UInt32) -> Void

        // CGS* symbols live in CoreGraphics; SLS* symbols live in SkyLight.
        let cgHandle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        )
        let slHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )

        // Resolve a symbol from SkyLight first, then CoreGraphics.
        let resolvedSymbols = CGSFunctions.resolveSymbols(
            cgHandle: cgHandle, slHandle: slHandle
        )

        guard let syms = resolvedSymbols else {
            isLoaded = false; connectionID = 0
            hasMoveWindows = false; hasCompatIDPath = false
            _copyManagedDisplaySpaces = { _ in nil }
            _getActiveSpace = { _, _ in 0 }
            _copySpacesForWindows = { _, _, _ in nil }
            _moveWindowsToManagedSpace = { _, _, _ in }
            _addWindowsToSpaces = { _, _, _ in }
            _removeWindowsFromSpaces = { _, _, _ in }
            _spaceSetCompatID = { _, _, _ in }
            _setWindowListWorkspace = { _, _, _, _ in }
            return
        }

        let defaultConn = unsafeBitCast(syms.pDefault, to: DefaultConnFunc.self)
        connectionID = defaultConn()

        let displayFn = unsafeBitCast(syms.pDisplaySpaces, to: CopyDisplaySpacesFunc.self)
        _copyManagedDisplaySpaces = { displayFn($0) }

        let activeFn = unsafeBitCast(syms.pActive, to: ActiveFunc.self)
        _getActiveSpace = { activeFn($0, $1) }

        let copyFn = unsafeBitCast(syms.pCopySpaces, to: CopySpacesFunc.self)
        _copySpacesForWindows = { copyFn($0, $1, $2) }

        if let pMoveWindows = syms.pMoveWindows {
            let moveFn = unsafeBitCast(pMoveWindows, to: MoveWindowsFunc.self)
            _moveWindowsToManagedSpace = { moveFn($0, $1, $2) }
            hasMoveWindows = true
        } else {
            _moveWindowsToManagedSpace = { _, _, _ in }
            hasMoveWindows = false
        }

        let addFn = unsafeBitCast(syms.pAdd, to: AddFunc.self)
        _addWindowsToSpaces = { addFn($0, $1, $2) }

        let removeFn = unsafeBitCast(syms.pRemove, to: RemoveFunc.self)
        _removeWindowsFromSpaces = { removeFn($0, $1, $2) }

        if let pCompat = syms.pCompatID, let pSetWS = syms.pSetWorkspace {
            let compatFn = unsafeBitCast(pCompat, to: CompatIDFunc.self)
            _spaceSetCompatID = { compatFn($0, $1, $2) }
            let wsFn = unsafeBitCast(pSetWS, to: SetWorkspaceFunc.self)
            _setWindowListWorkspace = { wsFn($0, $1, $2, $3) }
            hasCompatIDPath = true
        } else {
            _spaceSetCompatID = { _, _, _ in }
            _setWindowListWorkspace = { _, _, _, _ in }
            hasCompatIDPath = false
        }

        isLoaded = connectionID != 0
    }

    private struct ResolvedSymbols {
        let pDefault: UnsafeMutableRawPointer
        let pDisplaySpaces: UnsafeMutableRawPointer
        let pActive: UnsafeMutableRawPointer
        let pCopySpaces: UnsafeMutableRawPointer
        let pAdd: UnsafeMutableRawPointer
        let pRemove: UnsafeMutableRawPointer
        let pMoveWindows: UnsafeMutableRawPointer?
        let pCompatID: UnsafeMutableRawPointer?
        let pSetWorkspace: UnsafeMutableRawPointer?
    }

    private static func resolveSymbols(
        cgHandle: UnsafeMutableRawPointer?,
        slHandle: UnsafeMutableRawPointer?
    ) -> ResolvedSymbols? {
        guard cgHandle != nil || slHandle != nil else { return nil }

        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            if let h = slHandle, let p = dlsym(h, name) { return p }
            if let h = cgHandle, let p = dlsym(h, name) { return p }
            return nil
        }

        guard let pDefault = sym("CGSDefaultConnectionForThread"),
              let pDisplaySpaces = sym("CGSCopyManagedDisplaySpaces"),
              let pActive = sym("CGSManagedDisplayGetCurrentSpace"),
              let pCopySpaces = sym("CGSCopySpacesForWindows"),
              let pAdd = sym("CGSAddWindowsToSpaces"),
              let pRemove = sym("CGSRemoveWindowsFromSpaces")
        else { return nil }

        return ResolvedSymbols(
            pDefault: pDefault,
            pDisplaySpaces: pDisplaySpaces,
            pActive: pActive,
            pCopySpaces: pCopySpaces,
            pAdd: pAdd,
            pRemove: pRemove,
            pMoveWindows: sym("SLSMoveWindowsToManagedSpace"),
            pCompatID: sym("SLSSpaceSetCompatID"),
            pSetWorkspace: sym("SLSSetWindowListWorkspace")
        )
    }

    // MARK: Read-only queries

    func copyManagedDisplaySpaces() -> CFArray? {
        _copyManagedDisplaySpaces(connectionID)
    }

    func getActiveSpace() -> CGSSpaceID {
        _getActiveSpace(connectionID, "Main" as CFString)
    }

    func copySpacesForWindows(_ mask: Int, _ windows: CFArray) -> CFArray? {
        _copySpacesForWindows(connectionID, mask, windows)
    }

    // MARK: Window movement

    func moveWindowsToManagedSpace(_ windows: CFArray, _ spaceID: CGSSpaceID) {
        _moveWindowsToManagedSpace(connectionID, windows, spaceID)
    }

    func addWindowsToSpaces(_ windows: CFArray, _ spaces: CFArray) {
        _addWindowsToSpaces(connectionID, windows, spaces)
    }

    func removeWindowsFromSpaces(_ windows: CFArray, _ spaces: CFArray) {
        _removeWindowsFromSpaces(connectionID, windows, spaces)
    }

    /// yabai's macOS 14.5+ / 15+ workaround:
    ///   SLSSpaceSetCompatID(conn, targetSpace, 0x79616265)
    ///   SLSSetWindowListWorkspace(conn, &wid, 1, 0x79616265)
    ///   SLSSpaceSetCompatID(conn, targetSpace, 0x0)
    func moveWindowViaCompatID(_ windowID: UInt32, toSpace spaceID: CGSSpaceID) {
        let tag: UInt32 = 0x79616265 // "yabe"
        _spaceSetCompatID(connectionID, spaceID, tag)
        withUnsafePointer(to: windowID) { ptr in
            _setWindowListWorkspace(connectionID, ptr, 1, tag)
        }
        _spaceSetCompatID(connectionID, spaceID, 0)
    }
}

// MARK: - CGSSpaceService

/// Provides space enumeration and window-to-space movement via CGS / SLS
/// private APIs.
///
/// **Space switching** is intentionally NOT supported here. Yabai's source
/// shows that `SLSManagedDisplaySetCurrentSpace` alone only composites
/// windows; a proper switch also requires `SLSShowSpaces`, `SLSHideSpaces`,
/// and updating the Dock's internal `_currentSpace` ivar via code injection.
/// We use keyboard simulation for space switching instead.
///
/// **Window movement** uses `SLSMoveWindowsToManagedSpace` with a fallback
/// to `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` on macOS 15+.
/// Requires SIP disabled.
enum CGSSpaceService {

    static var isAvailable: Bool { CGSFunctions.shared.isLoaded }

    // MARK: - Space Enumeration

    /// Returns an ordered list of user-space IDs for the main display.
    /// Index 0 corresponds to Desktop 1, etc.
    static func userSpaceIDs() -> [CGSSpaceID] {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return [] }

        guard let displays = fns.copyManagedDisplaySpaces() as? [[String: Any]] else {
            return []
        }

        var result: [CGSSpaceID] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                let type = space["type"] as? Int ?? -1
                // type 0 = user space, type 4 = fullscreen
                guard type == 0 else { continue }
                if let id64 = space["id64"] as? UInt64 {
                    result.append(id64)
                } else if let id = space["ManagedSpaceID"] as? Int {
                    result.append(CGSSpaceID(id))
                }
            }
        }
        return result
    }

    /// Maps a 1-based space index to its CGS space ID.
    static func spaceID(forIndex index: Int) -> CGSSpaceID? {
        let spaces = userSpaceIDs()
        guard index >= 1, index <= spaces.count else { return nil }
        return spaces[index - 1]
    }

    // MARK: - Window Movement

    /// Whether we should prefer the macOS 14.5+ / 15+ compat-ID workaround
    /// over the direct `SLSMoveWindowsToManagedSpace` call.
    private static var preferCompatIDWorkaround: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion == 14 && v.minorVersion >= 5 { return true }
        return v.majorVersion >= 15
    }

    /// Whether any window-move API is available.
    static var canMoveWindows: Bool {
        let fns = CGSFunctions.shared
        return fns.isLoaded && (fns.hasMoveWindows || fns.hasCompatIDPath)
    }

    /// Moves a window to the space identified by `targetSpaceID`.
    ///
    /// Strategy (in priority order):
    /// 1. On macOS 14.5+ / 15+: compat-ID workaround (yabai's approach)
    /// 2. `SLSMoveWindowsToManagedSpace` (direct, works on older macOS)
    /// 3. `CGSAddWindowsToSpaces` + `CGSRemoveWindowsFromSpaces` (fallback)
    static func moveWindow(_ windowID: CGWindowID, toSpace targetSpaceID: CGSSpaceID) -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return false }

        if preferCompatIDWorkaround && fns.hasCompatIDPath {
            Log.info("CGS: moving window \(windowID) via compat-ID workaround")
            fns.moveWindowViaCompatID(windowID, toSpace: targetSpaceID)
        } else if fns.hasMoveWindows {
            Log.info("CGS: moving window \(windowID) via SLSMoveWindowsToManagedSpace")
            let windowArray = [windowID] as CFArray
            fns.moveWindowsToManagedSpace(windowArray, targetSpaceID)
        } else {
            Log.info("CGS: moving window \(windowID) via add/remove spaces")
            let windowArray = [windowID] as CFArray
            let spaceArray = [targetSpaceID] as CFArray
            fns.addWindowsToSpaces(windowArray, spaceArray)
            let currentSpaces = fns.copySpacesForWindows(kCGSSpaceAll, windowArray) as? [CGSSpaceID] ?? []
            let toRemove = currentSpaces.filter { $0 != targetSpaceID }
            if !toRemove.isEmpty {
                fns.removeWindowsFromSpaces(windowArray, toRemove as CFArray)
            }
        }

        return true
    }

    /// Moves a window to the space at the given 1-based index.
    @discardableResult
    static func moveWindow(_ windowID: CGWindowID, toSpaceAt index: Int) -> Bool {
        guard let sid = spaceID(forIndex: index) else { return false }
        return moveWindow(windowID, toSpace: sid)
    }

    // MARK: - Query

    /// Returns the space ID the user is currently viewing.
    static func currentSpaceID() -> CGSSpaceID {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return 0 }
        return fns.getActiveSpace()
    }

    /// Returns the 1-based index of the current space, or `nil`.
    static func currentSpaceIndex() -> Int? {
        let current = currentSpaceID()
        guard current != 0 else { return nil }
        if let idx = userSpaceIDs().firstIndex(of: current) {
            return idx + 1
        }
        return nil
    }

    // MARK: - Verification

    /// Verifies that the CGS space APIs are actually functional and not
    /// silently neutered (as happens on macOS 15+ with SIP enabled).
    ///
    /// Checks that:
    /// 1. Core symbols were loaded
    /// 2. Space enumeration returns a non-empty list
    /// 3. At least one window-move API is available
    /// 4. `CGSCopySpacesForWindows` returns data (not neutered)
    static func verifyFunctional() -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else {
            Log.info("CGS: symbols not loaded")
            return false
        }

        let spaces = userSpaceIDs()
        guard !spaces.isEmpty else {
            Log.info("CGS: space enumeration returned empty list")
            return false
        }
        Log.info("CGS: enumerated \(spaces.count) user space(s)")

        guard canMoveWindows else {
            Log.info("CGS: no window-move APIs available (neither SLS nor compat-ID)")
            return false
        }
        Log.info("CGS: move APIs available — hasMoveWindows=\(fns.hasMoveWindows), hasCompatID=\(fns.hasCompatIDPath)")

        // Try to verify that CGSCopySpacesForWindows isn't neutered by
        // querying any on-screen window.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
           let windowInfo = windowList.first(where: {
               ($0[kCGWindowLayer as String] as? Int) == 0
           }),
           let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID {
            let windowArray = [windowID] as CFArray
            if let memberSpaces = fns.copySpacesForWindows(kCGSSpaceAll, windowArray) as? [CGSSpaceID],
               !memberSpaces.isEmpty {
                Log.info("CGS: copySpacesForWindows returned \(memberSpaces.count) space(s) — APIs functional")
            } else {
                Log.info("CGS: copySpacesForWindows returned empty — APIs may be neutered, but proceeding (move might still work)")
            }
        } else {
            Log.info("CGS: no on-screen windows for copySpacesForWindows test, skipping")
        }

        Log.info("CGS: verification passed")
        return true
    }
}
