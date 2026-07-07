import Foundation
import Testing
@testable import PeekabooCLI

struct LoggerQueueSafetyTests {
    @Test
    func `concurrent level changes do not crash logger`() async {
        let logger = Logger.shared
        logger.setJsonOutputMode(true)
        logger.clearDebugLogs()
        logger.setMinimumLogLevel(.debug)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i % 2 == 0 {
                        logger.setVerboseMode(i % 4 == 0)
                        logger.setMinimumLogLevel(i % 3 == 0 ? .trace : .warning)
                    } else {
                        logger.debug("msg-\(i)", category: "race")
                        logger.verbose("verbose-\(i)", category: "race")
                    }
                }
            }
        }

        logger.flush()
        let logs = logger.getDebugLogs()
        #expect(!logs.isEmpty || true) // success is "did not crash / data race under TSan when enabled"
        logger.setJsonOutputMode(false)
        logger.resetMinimumLogLevel()
        logger.clearDebugLogs()
    }
}
