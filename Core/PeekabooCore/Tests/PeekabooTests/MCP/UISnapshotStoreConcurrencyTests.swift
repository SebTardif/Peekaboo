import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct UISnapshotStoreConcurrencyTests {
    @Test
    func `target cache supports concurrent production reads and writes`() async {
        let contexts = [
            WindowContext(
                applicationName: "First application name long enough to use heap storage",
                applicationProcessId: 101,
                windowTitle: "First window title long enough to use heap storage"),
            WindowContext(
                applicationName: "Second application name long enough to use heap storage",
                applicationProcessId: 202,
                windowTitle: "Second window title long enough to use heap storage"),
        ]
        let allowedNames = Set(contexts.compactMap(\.applicationName))
        let allowedTitles = Set(contexts.compactMap(\.windowTitle))
        let allowedProcessIdentifiers = Set(contexts.compactMap(\.applicationProcessId))
        let snapshot = UISnapshot()
        await snapshot.setTargetMetadata(from: contexts[0])

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<2000 {
                    await snapshot.setTargetMetadata(from: contexts[index % contexts.count])
                }
            }

            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<5000 {
                        #expect(snapshot.applicationName.map(allowedNames.contains) == true)
                        #expect(snapshot.windowTitle.map(allowedTitles.contains) == true)
                        #expect(snapshot.applicationProcessId.map(allowedProcessIdentifiers.contains) == true)
                    }
                }
            }
        }
    }
}
