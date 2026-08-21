import Testing
@testable import PeekabooCLI

struct ConfigEditorLaunchTests {
    @Test
    func `EditCommand terminates env options before an option-like editor`() {
        let arguments = ConfigCommand.EditCommand.editorProcessArguments(
            editor: "-S/usr/bin/touch /tmp/pwned",
            configPath: "/tmp/config.json"
        )

        #expect(arguments == ["--", "-S/usr/bin/touch /tmp/pwned", "/tmp/config.json"])
    }

    @Test
    func `EditCommand preserves a normal editor after the env option terminator`() {
        let arguments = ConfigCommand.EditCommand.editorProcessArguments(
            editor: "/usr/bin/nano",
            configPath: "/tmp/config.json"
        )

        #expect(arguments == ["--", "/usr/bin/nano", "/tmp/config.json"])
    }
}
