import PeekabooCore
import PeekabooFoundation
import Testing

struct MCPToolContextTests {
    @Test
    @MainActor
    func `exposes peekaboo services by default`() {
        self.installDefaults()
        let context = MCPToolContext.shared
        #expect(context.automation !== nil)
        #expect(context.menu !== nil)
    }

    @Test
    @MainActor
    func `context uses injected services`() async {
        let injectedServices = await MainActor.run { PeekabooServices() }
        let context = await MainActor.run { MCPToolContext(services: injectedServices) }

        #expect(ObjectIdentifier(context.menu as AnyObject) ==
            ObjectIdentifier(injectedServices.menu as AnyObject))
        #expect(ObjectIdentifier(context.automation as AnyObject) ==
            ObjectIdentifier(injectedServices.automation as AnyObject))
    }

    @Test
    @MainActor
    func `task local override restores shared value`() async throws {
        self.installDefaults()
        let baselineContext = MCPToolContext.shared
        let overrideContext = MCPToolContext(services: PeekabooServices())

        try await MCPToolContext.withContext(overrideContext) {
            let inside = MCPToolContext.shared
            #expect(ObjectIdentifier(inside.automation as AnyObject) ==
                ObjectIdentifier(overrideContext.automation as AnyObject))
        }

        let after = MCPToolContext.shared
        #expect(ObjectIdentifier(after.automation as AnyObject) ==
            ObjectIdentifier(baselineContext.automation as AnyObject))
    }

    @Test
    func `sharedOnMainActor resolves from a background task`() async throws {
        await MainActor.run {
            let services = PeekabooServices()
            services.installAgentRuntimeDefaults()
        }
        // Off-main async hop: no DispatchQueue.main.sync.
        let context = await MCPToolContext.sharedOnMainActor()
        #expect(context.automation !== nil)
        #expect(context.menu !== nil)
    }

    @MainActor
    private func installDefaults() {
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()
    }
}
