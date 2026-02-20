import CoreGraphics
import Foundation

// MARK: - CGS Private API Types

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

private let kCGSSpaceAll: Int = 0x7

// MARK: - CGS Function Loading

/// Loads CGS private API function pointers once at process start.
/// All pointers are immutable after initialisation, so they are safe to
/// share across threads.
private struct CGSFunctions: Sendable {
    static let shared = CGSFunctions()

    let connectionID: CGSConnectionID
    let isLoaded: Bool

    private let _addWindowsToSpaces: @Sendable (CGSConnectionID, CFArray, CFArray) -> Void
    private let _removeWindowsFromSpaces: @Sendable (CGSConnectionID, CFArray, CFArray) -> Void
    private let _copySpacesForWindows: @Sendable (CGSConnectionID, Int, CFArray) -> CFArray?
    private let _getActiveSpace: @Sendable (CGSConnectionID, CFString) -> CGSSpaceID

    private init() {
        typealias DefaultConnFunc = @convention(c) () -> CGSConnectionID
        typealias AddFunc = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
        typealias RemoveFunc = @convention(c) (CGSConnectionID, CFArray, CFArray) -> Void
        typealias CopyFunc = @convention(c) (CGSConnectionID, Int, CFArray) -> CFArray?
        typealias ActiveFunc = @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID

        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ) else {
            isLoaded = false
            connectionID = 0
            _addWindowsToSpaces = { _, _, _ in }
            _removeWindowsFromSpaces = { _, _, _ in }
            _copySpacesForWindows = { _, _, _ in nil }
            _getActiveSpace = { _, _ in 0 }
            return
        }

        guard let pDefault = dlsym(handle, "CGSDefaultConnectionForThread"),
              let pAdd = dlsym(handle, "CGSAddWindowsToSpaces"),
              let pRemove = dlsym(handle, "CGSRemoveWindowsFromSpaces"),
              let pCopy = dlsym(handle, "CGSCopySpacesForWindows"),
              let pActive = dlsym(handle, "CGSManagedDisplayGetCurrentSpace")
        else {
            isLoaded = false
            connectionID = 0
            _addWindowsToSpaces = { _, _, _ in }
            _removeWindowsFromSpaces = { _, _, _ in }
            _copySpacesForWindows = { _, _, _ in nil }
            _getActiveSpace = { _, _ in 0 }
            return
        }

        let defaultConn = unsafeBitCast(pDefault, to: DefaultConnFunc.self)
        connectionID = defaultConn()

        let addFn = unsafeBitCast(pAdd, to: AddFunc.self)
        _addWindowsToSpaces = { addFn($0, $1, $2) }

        let removeFn = unsafeBitCast(pRemove, to: RemoveFunc.self)
        _removeWindowsFromSpaces = { removeFn($0, $1, $2) }

        let copyFn = unsafeBitCast(pCopy, to: CopyFunc.self)
        _copySpacesForWindows = { copyFn($0, $1, $2) }

        let activeFn = unsafeBitCast(pActive, to: ActiveFunc.self)
        _getActiveSpace = { activeFn($0, $1) }

        isLoaded = connectionID != 0
    }

    func addWindowsToSpaces(_ windows: CFArray, _ spaces: CFArray) {
        _addWindowsToSpaces(connectionID, windows, spaces)
    }

    func removeWindowsFromSpaces(_ windows: CFArray, _ spaces: CFArray) {
        _removeWindowsFromSpaces(connectionID, windows, spaces)
    }

    func copySpacesForWindows(_ mask: Int, _ windows: CFArray) -> CFArray? {
        _copySpacesForWindows(connectionID, mask, windows)
    }

    func getActiveSpace() -> CGSSpaceID {
        _getActiveSpace(connectionID, "Main" as CFString)
    }
}

// MARK: - CGSSpaceService

/// Provides window-to-space movement via CGS private APIs.
///
/// These APIs only work reliably with SIP disabled on macOS 15+.
/// The service attempts to load the required symbols at init time and
/// reports availability via ``isAvailable``.
enum CGSSpaceService {

    static var isAvailable: Bool { CGSFunctions.shared.isLoaded }

    /// Moves a window (by CGWindowID) from its current space(s) to `targetSpaceID`.
    /// Returns `true` if the operation appeared to succeed.
    static func moveWindow(_ windowID: CGWindowID, toSpace targetSpaceID: CGSSpaceID) -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return false }

        let windowArray = [windowID] as CFArray
        let targetArray = [targetSpaceID] as CFArray

        // Add first, then remove — ordering matters (Amethyst #1174).
        fns.addWindowsToSpaces(windowArray, targetArray)

        if let currentSpaces = fns.copySpacesForWindows(kCGSSpaceAll, windowArray) as? [CGSSpaceID] {
            let toRemove = currentSpaces.filter { $0 != targetSpaceID }
            if !toRemove.isEmpty {
                fns.removeWindowsFromSpaces(windowArray, toRemove as CFArray)
            }
        }

        return true
    }

    /// Returns the space ID the user is currently viewing.
    static func currentSpaceID() -> CGSSpaceID {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return 0 }
        return fns.getActiveSpace()
    }

    /// Quick smoke test: attempt a no-op move to verify the APIs are
    /// actually functional (not silently neutered).  Returns `true` if
    /// the APIs appear to work.
    static func smokeTest(windowID: CGWindowID) -> Bool {
        let fns = CGSFunctions.shared
        guard fns.isLoaded else { return false }

        let windowArray = [windowID] as CFArray
        guard let spaces = fns.copySpacesForWindows(kCGSSpaceAll, windowArray) as? [CGSSpaceID],
              let currentSpace = spaces.first else {
            return false
        }

        let spaceArray = [currentSpace] as CFArray
        fns.addWindowsToSpaces(windowArray, spaceArray)

        guard let after = fns.copySpacesForWindows(kCGSSpaceAll, windowArray) as? [CGSSpaceID] else {
            return false
        }

        return after.contains(currentSpace)
    }
}
