import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized) @MainActor
struct ElementDetectionRetryCancellationTests {
    @Test
    func `cancellation during retry delay prevents a second collection`() async {
        var collectionCount = 0
        let task = Task { @MainActor in
            collectionCount += 1
            guard await ElementDetectionWebFocusRetryDelay.wait(nanoseconds: 5_000_000_000) else {
                return
            }
            collectionCount += 1
        }

        while collectionCount == 0 {
            await Task.yield()
        }
        task.cancel()
        await task.value

        #expect(collectionCount == 1)
    }

    @Test
    func `uncancelled retry delay permits the next collection`() async {
        #expect(await ElementDetectionWebFocusRetryDelay.wait(nanoseconds: 1_000_000))
    }
}
