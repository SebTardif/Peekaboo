import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuBarHelperProcessWaitTests {
    @Test
    func `wedged menubar helper does not block menu listing`() throws {
        let helper = try Self.writeExecutableHelper(
            contents: "#!/bin/sh\nexec /bin/sleep 3\n")
        defer { helper.remove() }
        let service = MenuService()
        let startedAt = Date()

        let items = service.getMenuBarItemsViaHelper(
            displayBounds: [],
            helperPath: helper.executableURL.path,
            timeoutSeconds: 0.05)

        #expect(items == nil)
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }

    @Test
    func `successful menubar helper still returns parsed extras`() throws {
        let helper = try Self.writeExecutableHelper(
            contents: "#!/bin/sh\nprintf '%s\\n' '{\"window_ids\":[]}'\n")
        defer { helper.remove() }
        let service = MenuService()

        let items = service.getMenuBarItemsViaHelper(
            displayBounds: [],
            helperPath: helper.executableURL.path,
            timeoutSeconds: 2)

        #expect(items?.isEmpty == true)
    }

    private static func writeExecutableHelper(contents: String) throws -> TemporaryHelper {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-menubar-helper-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executableURL = directory.appendingPathComponent("menubar-helper")
            try contents.write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path)
            return TemporaryHelper(directoryURL: directory, executableURL: executableURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private struct TemporaryHelper {
        let directoryURL: URL
        let executableURL: URL

        func remove() {
            try? FileManager.default.removeItem(at: self.directoryURL)
        }
    }
}
