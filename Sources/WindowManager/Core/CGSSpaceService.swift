import AppKit
import CoreGraphics
import Foundation

// MARK: - CGS / SLS Private API Types

/// Connection ID type — `int` in C (yabai extern.h).
typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let kCGSSpaceAll: Int32 = 7
private let kCGSSpaceCurrent: Int32 = 5

// MARK: - SIP Detection

enum SIPStatus: Sendable {
    case enabled
    case disabled
    case unknown
}

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

private struct CGSFunctions: Sendable {
    static let shared = CGSFunctions()

    let slsConnectionID: CGSConnectionID
    let cgsConnectionID: CGSConnectionID
    let isLoaded: Bool

    // Space enumeration & query
    private let _copyManagedDisplaySpaces: @Sendable (CGSConnectionID) -> CFArray?
    private let _getActiveSpace: @Sendable (CGSConnectionID, CFString) -> CGSSpaceID
    private let _copySpacesForWindows: @Sendable (CGSConnectionID, Int32, CFArray) -> CFArray?

    // Window movement
    private let _moveWindowsToManagedSpace: @Sendable (CGSConnectionID, CFArray, CGSSpaceID) -> Void
    let hasMoveWindows: Bool
    private let _addWindowsToSpaces: @Sendable (CGSConnectionID, CFArray, CFArray) -> Void
    private let _removeWindowsFromSpaces: @Sendable (CGSConnectionID, CFArray, CFArray) -> Void

    // compat-ID workaround
    private let _spaceSetCompatID: @Sendable (CGSConnectionID, CGSSpaceID, Int32) -> Int32
    private let _setWindowListWorkspace: @Sendable (CGSConnectionID, UnsafePointer<UInt32>, Int32, Int32) -> Int32
    let hasCompatIDPath: Bool

    private init() {
        typealias ConnFunc = @convention(c) () -> Int32
        typealias CopyDisplaySpacesFunc = @convention(c) (Int32) -> CFArray?
        typealias ActiveFunc = @convention(c) (Int32, CFString) -> UInt64
        typealias CopySpacesFunc = @convention(c) (Int32, Int32, CFArray) -> CFArray?
        typealias MoveWindowsFunc = @convention(c) (Int32, CFArray, UInt64) -> Void
        typealias AddFunc = @convention(c) (Int32, CFArray, CFArray) -> Void
        typealias RemoveFunc = @convention(c) (Int32, CFArray, CFArray) -> Void
        typealias CompatIDFunc = @convention(c) (Int32, UInt64, Int32) -> Int32
        typealias SetWorkspaceFunc = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32

        let cgHandle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        )
        let slHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )

        let resolvedSymbols = CGSFunctions.resolveSymbols(
            cgHandle: cgHandle, slHandle: slHandle
        )

        guard let syms = resolvedSymbols else {
            isLoaded = false; slsConnectionID = 0; cgsConnectionID = 0
            hasMoveWindows = false; hasCompatIDPath = false
            _copyManagedDisplaySpaces = { _ in nil }
            _getActiveSpace = { _, _ in 0 }
            _copySpacesForWindows = { _, _, _ in nil }
            _moveWindowsToManagedSpace = { _, _, _ in }
            _addWindowsToSpaces = { _, _, _ in }
            _removeWindowsFromSpaces = { _, _, _ in }
            _spaceSetCompatID = { _, _, _ in -1 }
            _setWindowListWorkspace = { _, _, _, _ in -1 }
            return
        }

        let slsConnFn = unsafeBitCast(syms.pSLSConnection, to: ConnFunc.self)
        slsConnectionID = slsConnFn()

        if let pCGS = syms.pCGSConnection {
            let cgsConnFn = unsafeBitCast(pCGS, to: ConnFunc.self)
            cgsConnectionID = cgsConnFn()
        } else {
            cgsConnectionID = slsConnectionID
        }

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
            _spaceSetCompatID = { _, _, _ in -1 }
            _setWindowListWorkspace = { _, _, _, _ in -1 }
            hasCompatIDPath = false
        }

        isLoaded = slsConnectionID != 0
    }

    private struct ResolvedSymbols {
        let pSLSConnection: UnsafeMutableRawPointer
        let pCGSConnection: UnsafeMutableRawPointer?
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

        guard let pSLSConn = sym("SLSMainConnectionID"),
              let pDisplaySpaces = sym("SLSCopyManagedDisplaySpaces") ?? sym("CGSCopyManagedDisplaySpaces"),
              let pActive = sym("SLSManagedDisplayGetCurrentSpace") ?? sym("CGSManagedDisplayGetCurrentSpace"),
              let pCopySpaces = sym("SLSCopySpacesForWindows") ?? sym("CGSCopySpacesForWindows"),
              let pAdd = sym("CGSAddWindowsToSpaces"),
              let pRemove = sym("CGSRemoveWindowsFromSpaces")
        else { return nil }

        return ResolvedSymbols(
            pSLSConnection: pSLSConn,
            pCGSConnection: sym("CGSDefaultConnectionForThread"),
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

    // MARK: Queries

    func copyManagedDisplaySpaces(_ cid: CGSConnectionID? = nil) -> CFArray? {
        _copyManagedDisplaySpaces(cid ?? slsConnectionID)
    }

    func getActiveSpace(_ cid: CGSConnectionID? = nil) -> CGSSpaceID {
        _getActiveSpace(cid ?? slsConnectionID, "Main" as CFString)
    }

    func copySpacesForWindows(_ mask: Int32, _ windows: CFArray, cid: CGSConnectionID? = nil) -> CFArray? {
        _copySpacesForWindows(cid ?? slsConnectionID, mask, windows)
    }

    // MARK: Window movement

    func moveWindowsToManagedSpace(_ windows: CFArray, _ spaceID: CGSSpaceID, cid: CGSConnectionID? = nil) {
        _moveWindowsToManagedSpace(cid ?? slsConnectionID, windows, spaceID)
    }

    func addWindowsToSpaces(_ windows: CFArray, _ spaces: CFArray, cid: CGSConnectionID? = nil) {
        _addWindowsToSpaces(cid ?? slsConnectionID, windows, spaces)
    }

    func removeWindowsFromSpaces(_ windows: CFArray, _ spaces: CFArray, cid: CGSConnectionID? = nil) {
        _removeWindowsFromSpaces(cid ?? slsConnectionID, windows, spaces)
    }

    @discardableResult
    func moveWindowViaCompatID(_ windowID: UInt32, toSpace spaceID: CGSSpaceID, cid: CGSConnectionID? = nil) -> Bool {
        let c = cid ?? slsConnectionID
        let tag: Int32 = 0x79616265
        let err1 = _spaceSetCompatID(c, spaceID, tag)
        var wid = windowID
        let err2 = _setWindowListWorkspace(c, &wid, 1, tag)
        let err3 = _spaceSetCompatID(c, spaceID, 0)
        Log.info("CGS: compatID(cid=\(c)) errors: set=\(err1) ws=\(err2) clear=\(err3)")
        return err2 == 0
    }

    /// Query which spaces a window belongs to.
    func windowSpaces(_ windowID: CGWindowID) -> [CGSSpaceID] {
        let arr = [NSNumber(value: windowID)] as CFArray
        guard let spaces = copySpacesForWindows(kCGSSpaceAll, arr) as? [UInt64] else {
            return []
        }
        return spaces
    }
}

// MARK: - CGSSpaceService

enum CGSSpaceService {

    static var isAvailable: Bool { CGSFunctions.shared.isLoaded }

    // MARK: - Space Enumeration

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

    static func spaceID(forIndex index: Int) -> CGSSpaceID? {
        let spaces = userSpaceIDs()
        guard index >= 1, index <= spaces.count else { return nil }
        return spaces[index - 1]
    }

    // MARK: - Window Movement

    static var canMoveWindows: Bool {
        CGSFunctions.shared.isLoaded
    }

    /// Moves a window to the target space.
    ///
    /// Tries every available strategy with diagnostic logging.
    /// Checks `CGSCopySpacesForWindows` after each attempt to verify
    /// whether the window actually moved.
    static func moveWindow(_ windowID: CGWindowID, toSpace targetSpaceID: CGSSpaceID) -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return false }

        let slsCid = fns.slsConnectionID
        let cgsCid = fns.cgsConnectionID

        Log.info("CGS: moveWindow(\(windowID) → space \(targetSpaceID)) slsCid=\(slsCid) cgsCid=\(cgsCid)")

        let beforeSpaces = fns.windowSpaces(windowID)
        Log.info("CGS: window \(windowID) currently on spaces: \(beforeSpaces)")

        if beforeSpaces.contains(targetSpaceID) {
            Log.info("CGS: window already on target space")
            return true
        }

        let windowArr = [NSNumber(value: windowID)] as CFArray

        // Strategy 1: SLSMoveWindowsToManagedSpace (with SLS connection)
        if fns.hasMoveWindows {
            Log.info("CGS: [1] SLSMoveWindowsToManagedSpace(slsCid=\(slsCid))")
            fns.moveWindowsToManagedSpace(windowArr, targetSpaceID, cid: slsCid)
            let after = fns.windowSpaces(windowID)
            if after.contains(targetSpaceID) {
                Log.info("CGS: [1] SUCCESS — window now on spaces: \(after)")
                return true
            }
            Log.info("CGS: [1] no effect — window still on: \(after)")
        }

        // Strategy 1b: SLSMoveWindowsToManagedSpace (with CGS connection)
        if fns.hasMoveWindows && cgsCid != slsCid {
            Log.info("CGS: [1b] SLSMoveWindowsToManagedSpace(cgsCid=\(cgsCid))")
            fns.moveWindowsToManagedSpace(windowArr, targetSpaceID, cid: cgsCid)
            let after = fns.windowSpaces(windowID)
            if after.contains(targetSpaceID) {
                Log.info("CGS: [1b] SUCCESS — window now on spaces: \(after)")
                return true
            }
            Log.info("CGS: [1b] no effect — window still on: \(after)")
        }

        // Strategy 2: add target, remove old
        do {
            Log.info("CGS: [2] CGSAddWindowsToSpaces + CGSRemoveWindowsFromSpaces (slsCid=\(slsCid))")
            let spaceArr = [NSNumber(value: targetSpaceID)] as CFArray
            fns.addWindowsToSpaces(windowArr, spaceArr, cid: slsCid)
            let afterAdd = fns.windowSpaces(windowID)
            Log.info("CGS: [2] after add: \(afterAdd)")
            let toRemove = afterAdd.filter { $0 != targetSpaceID }
            if !toRemove.isEmpty {
                let removeArr = toRemove.map { NSNumber(value: $0) } as CFArray
                fns.removeWindowsFromSpaces(windowArr, removeArr, cid: slsCid)
            }
            let afterRemove = fns.windowSpaces(windowID)
            if afterRemove.contains(targetSpaceID) && !afterRemove.contains(where: { beforeSpaces.contains($0) && $0 != targetSpaceID }) {
                Log.info("CGS: [2] SUCCESS — window now on spaces: \(afterRemove)")
                return true
            }
            Log.info("CGS: [2] no effect — window still on: \(afterRemove)")
        }

        // Strategy 2b: same with CGS connection
        if cgsCid != slsCid {
            Log.info("CGS: [2b] CGSAddWindowsToSpaces + CGSRemoveWindowsFromSpaces (cgsCid=\(cgsCid))")
            let spaceArr = [NSNumber(value: targetSpaceID)] as CFArray
            fns.addWindowsToSpaces(windowArr, spaceArr, cid: cgsCid)
            let afterAdd = fns.windowSpaces(windowID)
            Log.info("CGS: [2b] after add: \(afterAdd)")
            let toRemove = afterAdd.filter { $0 != targetSpaceID }
            if !toRemove.isEmpty {
                let removeArr = toRemove.map { NSNumber(value: $0) } as CFArray
                fns.removeWindowsFromSpaces(windowArr, removeArr, cid: cgsCid)
            }
            let afterRemove = fns.windowSpaces(windowID)
            if afterRemove.contains(targetSpaceID) {
                Log.info("CGS: [2b] SUCCESS — window now on spaces: \(afterRemove)")
                return true
            }
            Log.info("CGS: [2b] no effect — window still on: \(afterRemove)")
        }

        // Strategy 3: compat-ID workaround
        if fns.hasCompatIDPath {
            Log.info("CGS: [3] compat-ID workaround (slsCid=\(slsCid))")
            fns.moveWindowViaCompatID(windowID, toSpace: targetSpaceID, cid: slsCid)
            let after = fns.windowSpaces(windowID)
            if after.contains(targetSpaceID) {
                Log.info("CGS: [3] SUCCESS — window now on spaces: \(after)")
                return true
            }
            Log.info("CGS: [3] no effect — window still on: \(after)")
        }

        Log.info("CGS: all strategies exhausted — window move failed")
        return false
    }

    @discardableResult
    static func moveWindow(_ windowID: CGWindowID, toSpaceAt index: Int) -> Bool {
        guard let sid = spaceID(forIndex: index) else {
            Log.info("CGS: no space ID found for index \(index)")
            return false
        }
        return moveWindow(windowID, toSpace: sid)
    }

    // MARK: - Query

    static func currentSpaceID() -> CGSSpaceID {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return 0 }
        return fns.getActiveSpace()
    }

    static func currentSpaceIndex() -> Int? {
        let current = currentSpaceID()
        guard current != 0 else { return nil }
        if let idx = userSpaceIDs().firstIndex(of: current) {
            return idx + 1
        }
        return nil
    }

    // MARK: - Verification

    static func verifyFunctional() -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else {
            Log.info("CGS: symbols not loaded")
            return false
        }
        Log.info("CGS: slsConnectionID=\(fns.slsConnectionID), cgsConnectionID=\(fns.cgsConnectionID)")

        let spaces = userSpaceIDs()
        guard !spaces.isEmpty else {
            Log.info("CGS: space enumeration returned empty list")
            return false
        }
        Log.info("CGS: enumerated \(spaces.count) user space(s): \(spaces)")
        Log.info("CGS: current space ID = \(currentSpaceID()), index = \(currentSpaceIndex() ?? -1)")

        Log.info("CGS: APIs — hasMoveWindows=\(fns.hasMoveWindows), hasCompatID=\(fns.hasCompatIDPath)")

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
           let windowInfo = windowList.first(where: {
               ($0[kCGWindowLayer as String] as? Int) == 0
           }),
           let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID {
            let memberSpaces = fns.windowSpaces(windowID)
            Log.info("CGS: test window \(windowID) on spaces: \(memberSpaces)")
            if memberSpaces.isEmpty {
                Log.info("CGS: copySpacesForWindows returned empty — APIs may be neutered")
            }
        }

        Log.info("CGS: verification passed")
        return true
    }
}
