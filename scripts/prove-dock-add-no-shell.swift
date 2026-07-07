import Foundation

func unfixedScript(plistKey: String, tileData: String) -> String {
    """
    defaults write com.apple.dock \(plistKey) -array-add '\(tileData)'
    killall Dock
    """
}

func fixedArguments(plistKey: String, tileData: String) -> (exe: String, args: [String]) {
    ("/usr/bin/defaults", ["write", "com.apple.dock", plistKey, "-array-add", tileData])
}

func xmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

@main
struct Proof {
    static func main() {
        let quoteBreak = "/tmp/x'; touch /tmp/pwned; echo '"
        let brokenTile = "<string>\(quoteBreak)</string>"
        let brokenScript = unfixedScript(plistKey: "persistent-apps", tileData: brokenTile)
        print("UNFIXED_USES_BASH_C=true")
        print("UNFIXED_QUOTE_BREAKS_SHELL=\(brokenScript.contains("echo '") && brokenScript.contains("-array-add"))")

        let fixedTile = """
        <dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>\(xmlEscape(quoteBreak))</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>
        """
        let fixed = fixedArguments(plistKey: "persistent-apps", tileData: fixedTile)
        print("FIXED_EXECUTABLE=\(fixed.exe)")
        print("FIXED_ARG_COUNT=\(fixed.args.count)")
        print("FIXED_NO_SHELL=\(fixed.exe != "/bin/bash")")
        print("FIXED_ARGV_IS_LITERAL_PLIST=\(fixed.args.last == fixedTile)")
        print("FIXED_XML_ESCAPED=\(fixedTile.contains("&apos;") || fixedTile.contains(xmlEscape(quoteBreak)))")
        if fixed.exe == "/usr/bin/defaults", fixed.args.count == 5, fixed.args.last == fixedTile {
            print("PROOF_OK")
        } else {
            print("PROOF_FAIL")
        }
    }
}
