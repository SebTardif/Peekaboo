import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationRunningStateTests {
    @Test
    func `A missing application is not running`() throws {
        let running = try ApplicationService.runningState(for: PeekabooError.appNotFound("Missing"))
        #expect(running == false)
    }

    @Test
    func `An ambiguous application is not reported as stopped`() {
        do {
            _ = try ApplicationService.runningState(
                for: PeekabooError.ambiguousAppIdentifier("Notes", suggestions: ["Notes", "Notes"]))
            Issue.record("Expected ambiguous application identifiers to propagate")
        } catch let error as PeekabooError {
            guard case let .ambiguousAppIdentifier(identifier, suggestions) = error else {
                Issue.record("Expected ambiguousAppIdentifier, got \(error)")
                return
            }
            #expect(identifier == "Notes")
            #expect(suggestions == ["Notes", "Notes"])
        } catch {
            Issue.record("Expected PeekabooError, got \(error)")
        }
    }
}
