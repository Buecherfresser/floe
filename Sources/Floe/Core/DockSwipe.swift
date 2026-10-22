import CoreGraphics
import Foundation

/// The synthetic Dock swipe Floe switches desktops with, in the form macOS 27
/// accepts.
///
/// From macOS 27 on, WindowServer drops a synthetic Dock swipe unless it
/// carries the IOHIDEvent a real trackpad swipe has attached. CGEvent has no
/// API to attach one, so we append it to the event's serialized form and
/// rebuild the event from that.
///
/// Attribution: ported from InstantSpaceSwitcher's macOS 27 support
/// (https://github.com/jurplel/InstantSpaceSwitcher, MIT License).
enum DockSwipe {
    static let needsHIDEvent = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    // Gesture fields a real trackpad swipe carries on macOS 27.
    private static let typeField = CGEventField(rawValue: 55)!
    private static let hidTypeField = CGEventField(rawValue: 110)!
    private static let swipeMaskField = CGEventField(rawValue: 115)!
    private static let motionField = CGEventField(rawValue: 123)!
    private static let progressField = CGEventField(rawValue: 124)!
    private static let positionXField = CGEventField(rawValue: 125)!
    private static let positionYField = CGEventField(rawValue: 126)!
    private static let velocityXField = CGEventField(rawValue: 129)!
    private static let velocityYField = CGEventField(rawValue: 130)!
    private static let phaseField = CGEventField(rawValue: 132)!
    private static let phaseAliasField = CGEventField(rawValue: 134)!
    private static let zoomDeltaYField = CGEventField(rawValue: 138)!
    private static let timeField = CGEventField(rawValue: 169)!

    private static let gestureEventType: Int64 = 29
    private static let dockControlEventType: Int64 = 30
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1

    static let phaseBegan: Int64 = 1
    static let phaseChanged: Int64 = 2
    static let phaseEnded: Int64 = 4

    /// The 16.16 velocity field tops out around 32767.
    private static let flingVelocity = 9999.0
    /// The smallest non-zero 16.16 value: direction without visible travel.
    private static let progress = 0.000016

    /// Swipes one desktop forward (right) or back with a Began, Changed and
    /// Ended event, which is what commits the switch.
    static func post(forward: Bool) {
        let sign = sign(forward: forward)
        for phase in [phaseBegan, phaseChanged, phaseEnded] {
            guard let event = CGEvent(source: nil) else { return }
            event.setIntegerValueField(typeField, value: dockControlEventType)
            event.setIntegerValueField(hidTypeField, value: dockSwipeHIDType)
            event.setIntegerValueField(phaseField, value: phase)
            event.setIntegerValueField(phaseAliasField, value: phase)
            event.setIntegerValueField(motionField, value: horizontalMotion)
            event.setDoubleValueField(progressField, value: sign * progress)
            event.setDoubleValueField(zoomDeltaYField, value: 3.0)
            event.setDoubleValueField(timeField, value: Double(mach_absolute_time()))
            event.setDoubleValueField(positionXField, value: 0.1)
            // Only the Ended event carries the fling, as on a trackpad.
            if phase == phaseEnded {
                event.setDoubleValueField(velocityXField, value: sign * flingVelocity)
            }

            guard let swipe = withHIDEvent(event), let companion = CGEvent(source: nil) else {
                Log.error("DockSwipe: couldn't build the swipe event")
                return
            }
            // The Dock ignores a Dock control event without a gesture event next to it.
            companion.setIntegerValueField(typeField, value: gestureEventType)
            swipe.post(tap: .cgSessionEventTap)
            companion.post(tap: .cgSessionEventTap)
        }
    }

    /// On macOS 27 the Dock reads the sign through the natural scrolling
    /// setting: with it on, forward is negative.
    private static func sign(forward: Bool) -> Double {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let natural = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString,
                                                      kCFPreferencesAnyApplication, &valid)
        let sign = forward ? -1.0 : 1.0
        return !valid.boolValue || natural ? sign : -sign
    }

    // MARK: - IOHIDEvent payload

    /// Rebuilds `event` with an IOHIDEvent describing the same swipe appended
    /// to its serialized data under field 4205.
    private static func withHIDEvent(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data?, data.count >= 4,
              data.prefix(4) == Data([0, 0, 0, 2]) else { return nil }  // format version 2

        let payload = hidPayload(for: event)
        var augmented = data
        augmented.append(contentsOf: [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)])
        augmented.append(contentsOf: [UInt8(4205 >> 8), UInt8(4205 & 0xFF)])
        augmented.append(payload)
        return CGEvent(withDataAllocator: nil, data: augmented as CFData)
    }

    /// An IOHID system queue element: a header, a fluid touch gesture event
    /// and, for the fling, a velocity event as its child.
    private static func hidPayload(for event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(phaseField)
        let velocityX = event.getDoubleValueField(velocityXField)
        let velocityY = event.getDoubleValueField(velocityYField)
        let includesVelocity = velocityX != 0 || velocityY != 0 || phase == phaseEnded

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendEventBase(size: UInt32, type: UInt32, options: UInt32, depth: UInt8) {
            append(size)
            append(type)
            append(options)
            append(depth)
            data.append(contentsOf: [0, 0, 0])
        }

        // Header (28 bytes)
        let timestamp = event.timestamp != 0 ? event.timestamp : mach_absolute_time()
        append(UInt64(timestamp))
        append(UInt64(0))                          // sender ID
        append(UInt32(0))                          // options
        append(UInt32(0))                          // attribute length
        append(UInt32(includesVelocity ? 2 : 1))   // event count

        // Fluid touch gesture, flavor "Dock primary" (40 bytes)
        appendEventBase(size: 40, type: 23, options: UInt32(truncatingIfNeeded: (phase & 0xFF) << 24), depth: 0)
        append(fixed1616(event.getDoubleValueField(positionXField)))
        append(fixed1616(event.getDoubleValueField(positionYField)))
        append(Int32(0))
        append(UInt32(truncatingIfNeeded: event.getIntegerValueField(swipeMaskField)))
        append(UInt16(truncatingIfNeeded: event.getIntegerValueField(motionField)))
        append(UInt16(3))
        append(fixed1616(event.getDoubleValueField(progressField)))

        // Velocity (28 bytes)
        if includesVelocity {
            appendEventBase(size: 28, type: 9, options: 0, depth: 1)
            append(fixed1616(velocityX))
            append(fixed1616(velocityY))
            append(Int32(0))
        }
        return data
    }

    /// 16.16 fixed point that keeps tiny non-zero values non-zero.
    private static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(clamping: Int64(value * 65536))
        if fixed == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }
}
