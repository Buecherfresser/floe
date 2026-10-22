import AppKit
import CoreGraphics

/// Controls which app WindowServer treats as frontmost, without the app
/// bringing its windows forward.
///
/// On a desktop switch WindowServer activates the target desktop's front app
/// (Finder for an empty desktop). Activated normally, that app orders its key
/// window front, and if that window lives on another desktop, the Dock jumps
/// there ("switch to a Space with open windows"). yabai avoids this the same
/// way: set the desktop's front app and activate it with `kCPSNoWindows`.
enum FrontProcess {
    private typealias SetSpaceFrontPSN = @convention(c) (Int32, UInt64, ProcessSerialNumber) -> Int32
    private typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias MainConnectionID = @convention(c) () -> Int32

    private static let kCPSNoWindows: UInt32 = 0x400

    private struct Functions: @unchecked Sendable {
        let setSpaceFrontPSN: SetSpaceFrontPSN?
        let setFrontProcess: SetFrontProcessWithOptions?
        let processForPID: GetProcessForPID?
        let connection: Int32
    }

    private static let functions: Functions = {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        return Functions(
            setSpaceFrontPSN: sym(skyLight, "SLSSpaceSetFrontPSN", SetSpaceFrontPSN.self),
            setFrontProcess: sym(skyLight, "_SLPSSetFrontProcessWithOptions", SetFrontProcessWithOptions.self),
            processForPID: sym(services, "GetProcessForPID", GetProcessForPID.self),
            connection: sym(skyLight, "SLSMainConnectionID", MainConnectionID.self)?() ?? 0
        )
    }()

    static var isAvailable: Bool {
        functions.setSpaceFrontPSN != nil && functions.setFrontProcess != nil
            && functions.processForPID != nil && functions.connection != 0
    }

    private static func psn(for pid: pid_t) -> ProcessSerialNumber? {
        var psn = ProcessSerialNumber()
        guard let lookup = functions.processForPID, lookup(pid, &psn) == noErr else { return nil }
        return psn
    }

    /// Makes `pid` the front app of `space` and activates it without
    /// ordering any of its windows front.
    static func prepare(space: CGSSpaceID, frontApp pid: pid_t) {
        guard var psn = psn(for: pid) else { return }
        _ = functions.setSpaceFrontPSN?(functions.connection, space, psn)
        _ = functions.setFrontProcess?(&psn, 0, kCPSNoWindows)
    }

    /// Records `pid` as the front app of `space` (what WindowServer activates
    /// when you switch there).
    static func setFrontApp(_ pid: pid_t, ofSpace space: CGSSpaceID) {
        guard let psn = psn(for: pid) else { return }
        _ = functions.setSpaceFrontPSN?(functions.connection, space, psn)
    }

    static var finderPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }
}
