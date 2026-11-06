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
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private static let kCPSNoWindows: UInt32 = 0x400
    private static let kCPSUserGenerated: UInt32 = 0x200

    private struct Functions: @unchecked Sendable {
        let setSpaceFrontPSN: SetSpaceFrontPSN?
        let setFrontProcess: SetFrontProcessWithOptions?
        let processForPID: GetProcessForPID?
        let postEventRecord: PostEventRecordTo?
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
            postEventRecord: sym(skyLight, "SLPSPostEventRecordTo", PostEventRecordTo.self),
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

    /// Makes one window the key window of its app and the app frontmost.
    ///
    /// Activating the whole app instead (`activate()`, `AXFrontmost`) lets
    /// the app bring forward whichever window it last had in front — and if
    /// that one is on another desktop, macOS follows it there. With Teams'
    /// main window and call window on different desktops that's a jump on
    /// every focus. Naming the window avoids it (same approach as yabai).
    /// Returns false if the private calls aren't available.
    @discardableResult
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard var psn = psn(for: pid),
              let setFrontProcess = functions.setFrontProcess,
              let postEventRecord = functions.postEventRecord,
              setFrontProcess(&psn, windowID, kCPSUserGenerated) == 0 else { return false }

        // Two synthetic "make key window" event records for that window.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        for phase: UInt8 in [0x01, 0x02] {
            bytes[0x08] = phase
            _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
        }
        return true
    }

    static var finderPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }
}
