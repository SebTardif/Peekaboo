import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuBarHelperProcessWaitTests {
    @Test
    func `wedged menubar helper does not block menu listing`() throws {
        let helper = try Self.writeExecutableHelper(
            contents: "#!/bin/sh\nexec /bin/sleep 3\n")
        let service = MenuService()
        let startedAt = Date()

        let items = service.getMenuBarItemsViaHelper(
            displayBounds: [],
            helperPath: helper.path,
            timeoutSeconds: 0.05)

        #expect(items == nil)
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }

    @Test
    func `successful menubar helper still returns parsed extras`() throws {
        let helper = try Self.writeExecutableHelper(
            contents: "#!/bin/sh\nprintf '%s\\n' '{\"window_ids\":[]}'\n")
        let service = MenuService()

        let items = service.getMenuBarItemsViaHelper(
            displayBounds: [],
            helperPath: helper.path,
            timeoutSeconds: 2)

        #expect(items?.isEmpty == true)
    }

    private static func writeExecutableHelper(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-menubar-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("menubar-helper")
        try contents.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path)
        return helper
    }
}
