import AppKit
import CoreGraphics
import Foundation
import MachO

// MARK: - CGS / SLS Private API Types

/// Connection ID type — `int` in C (yabai extern.h).
typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let kCGSSpaceAll: Int32 = 7

/// `type` value of a regular desktop in `SLSCopyManagedDisplaySpaces`.
/// Fullscreen app spaces use 4.
private let kCGSSpaceTypeUser = 0

private let kSkyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"

/// Non-exported (internal linkage) SkyLight function that hands a bridged
/// window-management operation to the Dock, which executes it with its own
/// privileges. Works with SIP enabled — no Dock injection required.
private let kPerformAsyncBridgedOpSymbol =
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

// MARK: - CGS / SLS Function Loading

private struct CGSFunctions: @unchecked Sendable {
    static let shared = CGSFunctions()

    typealias ConnFunc = @convention(c) () -> Int32
    typealias CopyDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias ActiveSpaceFunc = @convention(c) (Int32) -> UInt64
    typealias CopySpacesFunc = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias PerformBridgedOpFunc = @convention(c) (AnyObject) -> Int64

    let connectionID: CGSConnectionID
    let isLoaded: Bool

    private let copyManagedDisplaySpacesFn: CopyDisplaySpacesFunc?
    private let getActiveSpaceFn: ActiveSpaceFunc?
    private let copySpacesForWindowsFn: CopySpacesFunc?

    /// `nil` when SkyLight lacks the bridged-operation machinery (pre-Tahoe).
    let performBridgedOp: PerformBridgedOpFunc?

    private init() {
        let handle = dlopen(kSkyLightPath, RTLD_LAZY)

        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }

        copyManagedDisplaySpacesFn = sym("SLSCopyManagedDisplaySpaces", as: CopyDisplaySpacesFunc.self)
        getActiveSpaceFn = sym("SLSGetActiveSpace", as: ActiveSpaceFunc.self)
        copySpacesForWindowsFn = sym("SLSCopySpacesForWindows", as: CopySpacesFunc.self)

        if let conn = sym("SLSMainConnectionID", as: ConnFunc.self) {
            connectionID = conn()
        } else {
            connectionID = 0
        }

        performBridgedOp = findLocalSymbol(kPerformAsyncBridgedOpSymbol, inImage: kSkyLightPath)
            .map { unsafeBitCast($0, to: PerformBridgedOpFunc.self) }

        isLoaded = connectionID != 0
            && copyManagedDisplaySpacesFn != nil
            && getActiveSpaceFn != nil
            && copySpacesForWindowsFn != nil

        Log.info("CGS: loaded=\(isLoaded) cid=\(connectionID) bridgedOps=\(performBridgedOp != nil)")
    }

    func copyManagedDisplaySpaces() -> [[String: Any]] {
        guard let fn = copyManagedDisplaySpacesFn,
              let arr = fn(connectionID)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr
    }

    /// Space shown on the display that currently has keyboard focus.
    func activeSpace() -> CGSSpaceID {
        getActiveSpaceFn?(connectionID) ?? 0
    }

    func spaces(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        guard let fn = copySpacesForWindowsFn else { return [] }
        let arr = [NSNumber(value: windowID)] as CFArray
        return fn(connectionID, kCGSSpaceAll, arr)?.takeRetainedValue() as? [UInt64] ?? []
    }
}

// MARK: - Local Symbol Lookup

/// Resolves a symbol from an image's `LC_SYMTAB`, including non-exported
/// (local) symbols that `dlsym` cannot see.
private func findLocalSymbol(_ name: String, inImage imagePath: String) -> UnsafeRawPointer? {
    for i in 0..<_dyld_image_count() {
        guard let imageName = _dyld_get_image_name(i), String(cString: imageName) == imagePath,
              let rawHeader = _dyld_get_image_header(i) else { continue }

        let slide = _dyld_get_image_vmaddr_slide(i)
        let header = UnsafeRawPointer(rawHeader)
        let ncmds = rawHeader.pointee.ncmds

        var linkedit: segment_command_64?
        var symtab: symtab_command?
        var cmdPtr = header + MemoryLayout<mach_header_64>.size
        for _ in 0..<ncmds {
            let cmd = cmdPtr.load(as: load_command.self)
            if cmd.cmd == LC_SEGMENT_64 {
                let seg = cmdPtr.load(as: segment_command_64.self)
                let segName = withUnsafeBytes(of: seg.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if segName == SEG_LINKEDIT { linkedit = seg }
            } else if cmd.cmd == LC_SYMTAB {
                symtab = cmdPtr.load(as: symtab_command.self)
            }
            cmdPtr += Int(cmd.cmdsize)
        }

        guard let linkedit, let symtab,
              let base = UnsafeRawPointer(bitPattern: Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide) else {
            return nil
        }

        let symbols = (base + Int(symtab.symoff)).assumingMemoryBound(to: nlist_64.self)
        let strings = (base + Int(symtab.stroff)).assumingMemoryBound(to: CChar.self)
        for s in 0..<Int(symtab.nsyms) {
            let entry = symbols[s]
            if strcmp(strings + Int(entry.n_un.n_strx), name) == 0 {
                return UnsafeRawPointer(bitPattern: Int(entry.n_value) + slide)
            }
        }
        return nil
    }
    return nil
}

// MARK: - Space Model

/// One entry of `SLSCopyManagedDisplaySpaces`.
struct ManagedDisplay {
    /// Display UUID, or `"Main"` when "Displays have separate Spaces" is off.
    let identifier: String
    /// All spaces on this display in Mission Control order (desktops and fullscreen apps).
    let spaces: [(id: CGSSpaceID, isUser: Bool)]
    let currentSpace: CGSSpaceID

    var userSpaceIDs: [CGSSpaceID] { spaces.filter(\.isUser).map(\.id) }

    func missionControlIndex(of space: CGSSpaceID) -> Int? {
        spaces.firstIndex { $0.id == space }
    }
}

// MARK: - CGSSpaceService

enum CGSSpaceService {

    static var isAvailable: Bool { CGSFunctions.shared.isLoaded }

    /// Whether windows can be moved between spaces via bridged operations.
    static var canMoveWindows: Bool {
        CGSFunctions.shared.isLoaded && CGSFunctions.shared.performBridgedOp != nil
    }

    // MARK: - Space Enumeration

    /// Managed displays in Floe's monitor order (see `Monitors.ordered()`).
    static func displays() -> [ManagedDisplay] {
        let order = Monitors.ordered().map(\.uuid)
        func rank(_ display: ManagedDisplay) -> Int {
            order.firstIndex { $0.caseInsensitiveCompare(display.identifier) == .orderedSame } ?? order.count
        }
        return unorderedDisplays().enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func unorderedDisplays() -> [ManagedDisplay] {
        CGSFunctions.shared.copyManagedDisplaySpaces().compactMap { display in
            guard let identifier = display["Display Identifier"] as? String,
                  let rawSpaces = display["Spaces"] as? [[String: Any]] else { return nil }

            let spaces: [(id: CGSSpaceID, isUser: Bool)] = rawSpaces.compactMap { space in
                guard let id = spaceID(of: space) else { return nil }
                return (id, (space["type"] as? Int) == kCGSSpaceTypeUser)
            }
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID(of:)) ?? 0
            return ManagedDisplay(identifier: identifier, spaces: spaces, currentSpace: current)
        }
    }

    private static func spaceID(of space: [String: Any]) -> CGSSpaceID? {
        if let id64 = space["id64"] as? UInt64 { return id64 }
        if let id = space["ManagedSpaceID"] as? Int { return CGSSpaceID(id) }
        return nil
    }

    /// All desktops across displays, in Floe's desktop-number order.
    static func userSpaceIDs() -> [CGSSpaceID] {
        displays().flatMap(\.userSpaceIDs)
    }

    /// Space ID of "Desktop N" (1-based, counted across displays).
    static func spaceID(forIndex index: Int) -> CGSSpaceID? {
        let spaces = userSpaceIDs()
        guard index >= 1, index <= spaces.count else { return nil }
        return spaces[index - 1]
    }

    static func display(containing space: CGSSpaceID) -> ManagedDisplay? {
        displays().first { $0.spaces.contains { $0.id == space } }
    }

    /// The desktop adjacent to `space` on the same display, skipping fullscreen
    /// spaces. Returns `nil` at either end (no wrap-around, matching Ctrl+Arrow).
    static func adjacentUserSpace(to space: CGSSpaceID, offset: Int) -> CGSSpaceID? {
        guard let display = display(containing: space) else { return nil }
        let userSpaces = display.userSpaceIDs
        guard let idx = userSpaces.firstIndex(of: space) else { return nil }
        let target = idx + offset
        guard userSpaces.indices.contains(target) else { return nil }
        return userSpaces[target]
    }

    // MARK: - Query

    static func currentSpaceID() -> CGSSpaceID {
        CGSFunctions.shared.activeSpace()
    }

    static func currentSpaceIndex() -> Int? {
        let current = currentSpaceID()
        guard current != 0 else { return nil }
        return userSpaceIDs().firstIndex(of: current).map { $0 + 1 }
    }

    static func spaces(forWindow windowID: CGWindowID) -> [CGSSpaceID] {
        CGSFunctions.shared.spaces(forWindow: windowID)
    }

    // MARK: - Window Movement

    /// How long to wait for the Dock to apply an asynchronous bridged move.
    private static let kMoveConfirmTimeout: TimeInterval = 0.25
    private static let kMoveConfirmPollInterval: useconds_t = 5_000 // 5 ms

    /// Moves a window to the target space without switching spaces.
    ///
    /// Uses `SLSBridgedMoveWindowsToManagedSpaceOperation`, which SkyLight
    /// forwards to the Dock for execution — so it works with SIP enabled and
    /// needs no code injection. Blocks briefly until the move is observable.
    /// `countFailure: false` keeps an expected miss out of the compatibility check.
    @discardableResult
    static func moveWindow(_ windowID: CGWindowID, toSpace spaceID: CGSSpaceID, countFailure: Bool = true) -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded, let perform = fns.performBridgedOp else {
            Log.error("CGS: bridged window operations unavailable on this macOS version")
            return false
        }

        let source = fns.spaces(forWindow: windowID)
        if source.contains(spaceID) {
            Log.info("CGS: window \(windowID) already on space \(spaceID)")
            return true
        }
        // Fullscreen and sticky windows aren't on (just) one desktop; the Dock
        // ignores moves for them. That's not macOS breaking, so don't count it.
        let desktops = Set(userSpaceIDs())
        guard source.count == 1, desktops.contains(source[0]) else {
            Log.error("CGS: window \(windowID) is not on a single desktop (spaces \(source)), not moving it")
            return false
        }

        WindowTouches.note(windowID)
        guard let op = makeMoveOperation(windows: [windowID], spaceID: spaceID) else {
            Log.error("CGS: could not create SLSBridgedMoveWindowsToManagedSpaceOperation")
            return false
        }
        _ = perform(op)

        let deadline = Date().addingTimeInterval(kMoveConfirmTimeout)
        while Date() < deadline {
            if fns.spaces(forWindow: windowID).contains(spaceID) {
                Log.info("CGS: moved window \(windowID) to space \(spaceID)")
                Compatibility.record(.windowMove, ok: true)
                return true
            }
            usleep(kMoveConfirmPollInterval)
        }

        Log.error("CGS: window \(windowID) did not arrive on space \(spaceID) (now on \(fns.spaces(forWindow: windowID)))")
        if countFailure {
            Compatibility.record(.windowMove, ok: false)
        }
        return false
    }

    /// `[[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:spaceID:]`
    private static func makeMoveOperation(windows: [CGWindowID], spaceID: CGSSpaceID) -> AnyObject? {
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias InitFn = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?

        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return nil } // RTLD_DEFAULT

        let alloc = unsafeBitCast(msgSend, to: AllocFn.self)
        let initialize = unsafeBitCast(msgSend, to: InitFn.self)

        // alloc returns +1; init consumes it and returns a +1 instance.
        let allocated = alloc(cls, NSSelectorFromString("alloc")).takeUnretainedValue()
        let windowList = windows.map { NSNumber(value: $0) } as NSArray
        return initialize(allocated, NSSelectorFromString("initWithWindows:spaceID:"), windowList, spaceID)?
            .takeRetainedValue()
    }
}

// MARK: - Compatibility

extension CGSSpaceService {
    /// Checks the SkyLight pieces Floe uses without moving anything.
    static func probes() -> [Compatibility.Probe] {
        let fns = CGSFunctions.shared
        let spaces = userSpaceIDs()
        let current = currentSpaceID()

        // Any normal on-screen window should be on at least one desktop.
        var windowSpaces = true
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]],
           let window = info.first(where: { ($0[kCGWindowLayer] as? Int) == 0 })?[kCGWindowNumber] as? CGWindowID {
            windowSpaces = !fns.spaces(forWindow: window).isEmpty
        }

        let moveClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
        let canMove = fns.performBridgedOp != nil
            && moveClass?.instancesRespond(to: NSSelectorFromString("initWithWindows:spaceID:")) == true

        return [
            Compatibility.Probe(name: "SkyLight", ok: fns.isLoaded),
            Compatibility.Probe(name: "Desktop list", ok: !spaces.isEmpty),
            // Not `spaces.contains`: a fullscreen app's space isn't a desktop.
            Compatibility.Probe(name: "Current desktop", ok: current != 0),
            Compatibility.Probe(name: "Window desktops", ok: windowSpaces),
            Compatibility.Probe(name: "Window moves", ok: canMove),
        ]
    }
}
