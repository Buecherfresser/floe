import AppKit

/// Floe leans on private parts of macOS (SkyLight calls, the Dock's swipe
/// gesture, Mission Control's layout) that Apple can change in any update.
/// This checks the parts it can without moving anything and counts features
/// that keep failing while Floe runs, so a macOS update that breaks one shows
/// up as a check instead of Floe quietly misbehaving.
enum Compatibility {
    /// The macOS version Floe was made and tested on.
    static let testedMajorVersion = 26

    struct Probe: Equatable {
        let name: String
        let ok: Bool
    }

    enum Feature: String, CaseIterable, Sendable {
        case desktopSwitch = "Switching desktops"
        case windowMove = "Moving windows to other desktops"
        case missionControl = "Adding and removing desktops"
    }

    /// Failures in a row before a feature counts as broken. One miss can be
    /// a busy Mac; three in a row is more likely macOS.
    private static let failureThreshold = 3
    private static let failures = Locked([Feature: Int]())

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "") (\(systemBuild))"
    }

    private static var systemBuild: String { sysctlString("kern.osversion") }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }

    private static var isNewerThanTested: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion > testedMajorVersion
    }

    // MARK: - Runtime failures

    static func record(_ feature: Feature, ok: Bool) {
        let (before, after) = failures.withLock { counts -> (Int, Int) in
            let before = counts[feature, default: 0]
            counts[feature] = ok ? 0 : before + 1
            return (before, counts[feature, default: 0])
        }
        if after == failureThreshold {
            Log.error("Compatibility: \(feature.rawValue) failed \(after) times in a row on macOS \(macOSVersion)")
        } else if ok && before >= failureThreshold {
            Log.info("Compatibility: \(feature.rawValue) works again")
        }
    }

    static func isFailing(_ feature: Feature) -> Bool {
        failures.withLock { $0[feature, default: 0] >= failureThreshold }
    }

    // MARK: - Checks

    /// Checks the private pieces Floe uses, without changing anything.
    static func probes() -> [Probe] {
        CGSSpaceService.probes() + [Probe(name: "Front app control", ok: FrontProcess.isAvailable)]
    }

    /// Problems for Settings, the menu bar and the welcome.
    static func issues() -> [SystemIssue] {
        var broken = probes().filter { !$0.ok }.map(\.name)
        broken += Feature.allCases.filter(isFailing).map(\.rawValue)
        guard !broken.isEmpty else { return [] }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let newer = isNewerThanTested
            ? " Floe \(AppVersion.current) was made for macOS \(testedMajorVersion), so an update may fix this."
            : ""
        return [SystemIssue(
            id: "compatibility",
            title: "Parts of Floe don't work on macOS \(version.majorVersion).\(version.minorVersion)",
            detail: "Not working: \(broken.joined(separator: ", ")).\(newer) Use Copy Diagnostics in Settings › General and report it on GitHub.",
            settingsURL: nil
        )]
    }

    /// Logs the checks at launch, and says so when macOS changed since the
    /// last launch.
    static func checkAtLaunch() {
        let key = "lastSystemBuild"
        let build = systemBuild
        let previous = UserDefaults.standard.string(forKey: key)
        if let previous, previous != build {
            Log.info("Compatibility: macOS changed from \(previous) to \(build)")
        }
        UserDefaults.standard.set(build, forKey: key)

        let results = probes()
        let summary = results.map { "\($0.name)=\($0.ok ? "ok" : "FAILED")" }.joined(separator: " ")
        if results.allSatisfy(\.ok) {
            Log.info("Compatibility: macOS \(macOSVersion): \(summary)")
        } else {
            Log.error("Compatibility: macOS \(macOSVersion): \(summary)")
        }
    }
}
