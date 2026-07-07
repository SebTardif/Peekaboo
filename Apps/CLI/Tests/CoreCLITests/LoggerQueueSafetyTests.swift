import Foundation
import Testing
@testable import PeekabooCLI

struct LoggerQueueSafetyTests {
    /// Exercises the lock-backed flag snapshot path used by `log` / timers.
    /// Concurrent TaskGroup access is intentionally avoided: under the package's
    /// default MainActor isolation, Logger APIs are MainActor-bound, so stress
    /// concurrency would only restate isolation, not the queue race we fixed.
    @Test
    @MainActor
    func `logger flag snapshots under queue do not crash`() {
        let logger = Logger.shared
        logger.setJsonOutputMode(true)
        logger.clearDebugLogs()
        logger.setMinimumLogLevel(.debug)

        for i in 0..<50 {
            if i % 2 == 0 {
                logger.setVerboseMode(i % 4 == 0)
                logger.setMinimumLogLevel(i % 3 == 0 ? .trace : .warning)
            } else {
                logger.debug("msg-\(i)", category: "race")
                logger.verbose("verbose-\(i)", category: "race")
            }
        }

        logger.flush()
        _ = logger.getDebugLogs()
        logger.setJsonOutputMode(false)
        logger.resetMinimumLogLevel()
        logger.clearDebugLogs()
    }
}
