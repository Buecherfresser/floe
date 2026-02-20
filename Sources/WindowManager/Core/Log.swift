import Foundation
import os.log

enum Log {
    private static let logger = os.Logger(subsystem: "com.windowmanager", category: "default")

    nonisolated(unsafe) static var isEnabled = false

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.info("\(msg, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
    }
}
