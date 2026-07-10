import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPToolContextTests {
    @Test
    @MainActor
    func `shared resolves the configured services`() async {
        let services = PeekabooServices()

        await MCPToolContext.withDefaultContextFactoryForTesting {
            MainActor.preconditionIsolated()
            return MCPToolContext(services: services)
        } perform: {
            let context = MCPToolContext.shared

            #expect(ObjectIdentifier(context.automation as AnyObject) ==
                ObjectIdentifier(services.automation as AnyObject))
            #expect(ObjectIdentifier(context.menu as AnyObject) ==
                ObjectIdentifier(services.menu as AnyObject))
        }
    }

    @Test
    @MainActor
    func `context uses injected services`() {
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)

        #expect(ObjectIdentifier(context.menu as AnyObject) ==
            ObjectIdentifier(services.menu as AnyObject))
        #expect(ObjectIdentifier(context.automation as AnyObject) ==
            ObjectIdentifier(services.automation as AnyObject))
    }

    @Test
    @MainActor
    func `task local override restores shared value`() async {
        let services = PeekabooServices()

        await MCPToolContext.withDefaultContextFactoryForTesting {
            MCPToolContext(services: services)
        } perform: {
            let baselineContext = MCPToolContext.shared
            let overrideContext = MCPToolContext(services: PeekabooServices())

            await MCPToolContext.withContext(overrideContext) {
                let inside = MCPToolContext.shared
                #expect(ObjectIdentifier(inside.automation as AnyObject) ==
                    ObjectIdentifier(overrideContext.automation as AnyObject))
            }

            let after = MCPToolContext.shared
            #expect(ObjectIdentifier(after.automation as AnyObject) ==
                ObjectIdentifier(baselineContext.automation as AnyObject))
        }
    }

    @Test
    func `sharedOnMainActor resolves from a detached task`() async {
        await MCPToolContext.withDefaultContextFactoryForTesting(nil) {
            let services = PeekabooServices()
            MCPToolContext.configureDefaultContext {
                MainActor.preconditionIsolated()
                return MCPToolContext(services: services)
            }

            let context = await Task.detached {
                await MCPToolContext.sharedOnMainActor()
            }.value

            #expect(ObjectIdentifier(context.automation as AnyObject) ==
                ObjectIdentifier(services.automation as AnyObject))
            #expect(ObjectIdentifier(context.menu as AnyObject) ==
                ObjectIdentifier(services.menu as AnyObject))
        }
    }
}
