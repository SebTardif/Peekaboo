import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DockAddPathValidationTests {
    @Test
    func `rejects empty and relative paths`() {
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("")
        }
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("Applications/Calculator.app")
        }
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("  ")
        }
    }

    @Test
    func `rejects control characters`() {
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("/tmp/evil\n.app")
        }
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("/tmp/evil\u{0000}.app")
        }
    }

    @Test
    func `accepts absolute paths and XML-escapes special characters`() throws {
        let path = try DockService.validatedDockItemPath("/Applications/Foo & Bar <Test>.app")
        #expect(path == "/Applications/Foo & Bar <Test>.app")

        let fragment = DockService.dockTilePlistFragment(forPath: path)
        #expect(fragment.contains("<string>/Applications/Foo &amp; Bar &lt;Test&gt;.app</string>"))
        #expect(!fragment.contains("<string>/Applications/Foo & Bar <Test>.app</string>"))
    }

    @Test
    func `shell metacharacter path stays a single non-shell argument payload`() throws {
        let payload = #"/tmp/x'; touch /tmp/pwned; echo '"#
        let path = try DockService.validatedDockItemPath(payload)
        let fragment = DockService.dockTilePlistFragment(forPath: path)
        #expect(fragment.contains(DockService.xmlEscape(path)))
        #expect(!fragment.contains("bash"))
    }
}
