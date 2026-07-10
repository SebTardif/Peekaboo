import PeekabooBridge
import Testing

struct PeekabooBridgeConstantsTests {
    @Test
    func `Peekaboo host sockets have distinct roles`() {
        #expect(PeekabooBridgeConstants.peekabooSocketPath.hasSuffix("/Peekaboo/bridge.sock"))
        #expect(PeekabooBridgeConstants.daemonSocketPath.hasSuffix("/Peekaboo/daemon.sock"))
    }

    @Test
    func `Claude socket path uses Application Support/Claude`() {
        #expect(PeekabooBridgeConstants.claudeSocketPath.hasSuffix("/Claude/bridge.sock"))
    }

    @Test
    func `Release bridge accepts legacy and Foundation signing teams`() {
        #expect(PeekabooBridgeConstants.trustedReleaseTeamIDs == ["Y5PE65HELJ", "FWJYW4S8P8"])
    }
}
