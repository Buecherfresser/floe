import Foundation
import os.log

enum Log {
    private static let logger = os.Logger(subsystem: "com.jonasdrechsel.floe", category: "default")

    nonisolated(unsafe) static var isEnabled = false

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
    }

    /// Logged at `.notice` so the message is persisted and readable later
    /// with `log show` (`.info` messages only live in memory).
    static func info(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
    }
}
