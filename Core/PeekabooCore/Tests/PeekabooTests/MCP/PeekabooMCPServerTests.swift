import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

struct PeekabooMCPServerTests {
    @Test
    func `server initializes with native MCP tool catalog`() async throws {
        let server = try await makeServer()
        let names = await server.registeredToolNamesForTesting()

        #expect(names.count == 27)
        #expect(names == names.sorted())
        #expect(names.contains("capture"))
        #expect(names.contains("image"))
        #expect(names.contains("inspect_ui"))
        #expect(names.contains("click"))
        #expect(names.contains("clipboard"))
        #expect(names.contains("paste"))
        #expect(names.contains("set_value"))
        #expect(names.contains("perform_action"))
    }

    @Test
    @MainActor
    func `server filters action-only tools with runtime input policy`() async throws {
        let services = PeekabooServices(inputPolicy: UIInputPolicy(
            defaultStrategy: .synthOnly,
            setValue: .synthOnly,
            performAction: .synthOnly))

        let server = try await PeekabooMCPServer(toolContext: MCPToolContext(services: services))
        let names = await server.registeredToolNamesForTesting()

        #expect(!names.contains("set_value"))
        #expect(!names.contains("perform_action"))
    }

    @Test
    @MainActor
    func `default server context inherits the installed agent execution gate`() async throws {
        let services = PeekabooServices()
        services.agent = nil
        services.installAgentRuntimeDefaults()
        let firstFallbackContext = MCPToolContext.makeDefault()
        let secondFallbackContext = MCPToolContext.makeDefault()
        let gate = MCPToolSnapshotExecutionGate()
        let agent = try PeekabooAgentService(
            services: services,
            snapshotExecutionGate: gate)
        services.agent = agent

        let defaultContext = MCPToolContext.makeDefault()
        let server = try await PeekabooMCPServer()

        #expect(firstFallbackContext.snapshotExecutionGate === secondFallbackContext.snapshotExecutionGate)
        #expect(firstFallbackContext.snapshotExecutionGate !== gate)
        #expect(defaultContext.snapshotExecutionGate === gate)
        #expect(await server.snapshotExecutionGateForTesting() === gate)
    }

    @Test
    @MainActor
    func `makeDefaultIfConfigured throws when factory is missing`() {
        MCPToolContext.resetDefaultContextFactoryForTesting()
        defer { restoreDefaultFactory() }
        do {
            _ = try MCPToolContext.makeDefaultIfConfigured()
            Issue.record("expected makeDefaultIfConfigured() to throw")
        } catch let error as PeekabooError {
            #expect(String(describing: error).contains("not configured"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    @MainActor
    func `makeDefaultIfConfigured returns context after installAgentRuntimeDefaults`() throws {
        MCPToolContext.resetDefaultContextFactoryForTesting()
        defer { restoreDefaultFactory() }
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()
        let context = try MCPToolContext.makeDefaultIfConfigured()
        #expect(context.automation !== nil)
    }

    @Test
    @MainActor
    func `server init throws when default factory is unconfigured`() async {
        MCPToolContext.resetDefaultContextFactoryForTesting()
        defer { restoreDefaultFactory() }
        do {
            _ = try await PeekabooMCPServer()
            Issue.record("expected PeekabooMCPServer() to throw when factory is unconfigured")
        } catch {
            // Recoverable startup path: throw instead of fatalError.
            #expect(String(describing: error).contains("not configured")
                || error is PeekabooError)
        }
    }

    @Test
    @MainActor
    func `server init succeeds after installAgentRuntimeDefaults`() async throws {
        MCPToolContext.resetDefaultContextFactoryForTesting()
        defer { restoreDefaultFactory() }
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()
        let server = try await PeekabooMCPServer()
        let names = await server.registeredToolNamesForTesting()
        #expect(!names.isEmpty)
    }


}

@MainActor
private func makeServer() async throws -> PeekabooMCPServer {
    let services = PeekabooServices()
    return try await PeekabooMCPServer(toolContext: MCPToolContext(services: services))
}
