// Standalone proof for fix/image-tool-zero-byte-png (PR #209).
// Demonstrates that buildCaptureResponse with empty capture data and
// a failed file-read fallback now returns an error instead of a
// zero-byte PNG reported as a successful capture.
//
// This reproduces the exact logic from ImageTool+Capture.swift:122-133
// without importing PeekabooCore or MCP types.
//
// Usage:
//   swiftc -parse-as-library -o /tmp/prove-image \
//     scripts/prove-image-tool-empty-capture.swift && /tmp/prove-image

import Foundation

// --- Minimal reproductions of the relevant types ---

struct ToolResponse: CustomStringConvertible {
    let contentType: String
    let dataByteCount: Int
    let isError: Bool
    let message: String?

    var description: String {
        if self.isError {
            return "ToolResponse.error(\"\(self.message ?? "")\")"
        }
        return "ToolResponse.image(bytes: \(self.dataByteCount), isError: \(self.isError))"
    }

    static func image(data: Data, mimeType: String) -> ToolResponse {
        ToolResponse(
            contentType: mimeType,
            dataByteCount: data.count,
            isError: false,
            message: nil)
    }

    static func error(_ message: String) -> ToolResponse {
        ToolResponse(
            contentType: "text/plain",
            dataByteCount: 0,
            isError: true,
            message: message)
    }
}

struct SavedFile {
    let path: String
}

// --- The two versions of the response builder ---

/// Unfixed: current main behavior. Empty data + failed file read = zero-byte PNG "success".
func buildCaptureResponse_unfixed(
    captureImageData: Data,
    savedFiles: [SavedFile]) -> ToolResponse
{
    let data = if captureImageData.isEmpty, let path = savedFiles.first?.path {
        (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? captureImageData
    } else {
        captureImageData
    }
    // Bug: returns a zero-byte image with isError == false
    return ToolResponse.image(data: data, mimeType: "image/png")
}

/// Fixed: PR #209 behavior. Empty data + failed file read = ToolResponse.error.
func buildCaptureResponse_fixed(
    captureImageData: Data,
    savedFiles: [SavedFile]) -> ToolResponse
{
    let data = if captureImageData.isEmpty, let path = savedFiles.first?.path {
        (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? captureImageData
    } else {
        captureImageData
    }
    if data.isEmpty {
        return ToolResponse.error(
            "Capture produced no image data and no saved file could be read")
    }
    return ToolResponse.image(data: data, mimeType: "image/png")
}

// --- Proof runner ---

@main
struct Proof {
    static func main() {
        print("=== ImageTool zero-byte PNG capture proof ===")
        print("Reproduces ImageTool+Capture.swift:122-133 logic")
        print()

        let emptyData = Data()
        let nonexistentPath = "/tmp/peekaboo-nonexistent-\(UUID().uuidString).png"
        let savedFiles = [SavedFile(path: nonexistentPath)]

        // --- Test 1: Successful capture (non-empty data) should work identically ---
        print("Test 1: Non-empty capture data (should succeed in both versions)")
        let validPNG = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        let unfixedOK = buildCaptureResponse_unfixed(captureImageData: validPNG, savedFiles: [])
        let fixedOK = buildCaptureResponse_fixed(captureImageData: validPNG, savedFiles: [])
        print("  Unfixed: \(unfixedOK)")
        print("  Fixed:   \(fixedOK)")
        let test1Pass = !unfixedOK.isError && !fixedOK.isError
            && unfixedOK.dataByteCount == 4 && fixedOK.dataByteCount == 4
        print("  \(test1Pass ? "PASS" : "FAIL"): Both return a 4-byte image with isError=false")
        print()

        // --- Test 2: Empty capture + unreadable file (the bug) ---
        print("Test 2: Empty capture data + unreadable saved file (the bug)")
        print("  captureImageData: \(emptyData.count) bytes (empty)")
        print("  savedFile path: \(nonexistentPath) (does not exist)")
        print()

        let unfixed = buildCaptureResponse_unfixed(
            captureImageData: emptyData, savedFiles: savedFiles)
        let fixed = buildCaptureResponse_fixed(
            captureImageData: emptyData, savedFiles: savedFiles)

        print("  Unfixed (main):  \(unfixed)")
        print("    isError: \(unfixed.isError), bytes: \(unfixed.dataByteCount)")
        print("  Fixed (PR #209): \(fixed)")
        print("    isError: \(fixed.isError)")
        print()

        // --- Test 3: Empty capture + readable file (fallback works) ---
        print("Test 3: Empty capture data + readable saved file (fallback succeeds)")
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-proof-\(UUID().uuidString).png").path
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // 8-byte PNG header
        FileManager.default.createFile(atPath: tempPath, contents: fakePNG)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let unfixedFallback = buildCaptureResponse_unfixed(
            captureImageData: emptyData, savedFiles: [SavedFile(path: tempPath)])
        let fixedFallback = buildCaptureResponse_fixed(
            captureImageData: emptyData, savedFiles: [SavedFile(path: tempPath)])
        print("  Unfixed: \(unfixedFallback)")
        print("  Fixed:   \(fixedFallback)")
        let test3Pass = !unfixedFallback.isError && !fixedFallback.isError
            && unfixedFallback.dataByteCount == 8 && fixedFallback.dataByteCount == 8
        print("  \(test3Pass ? "PASS" : "FAIL"): Both return 8-byte image (fallback read worked)")
        print()

        // --- Verdict ---
        let bugReproduced = !unfixed.isError && unfixed.dataByteCount == 0
        let bugFixed = fixed.isError
        if bugReproduced, bugFixed, test1Pass, test3Pass {
            print("PASS: Unfixed returns ToolResponse.image with 0 bytes, isError=false (the bug)")
            print("PASS: Fixed returns ToolResponse.error with isError=true (the fix)")
            print("PASS: Non-empty captures work identically in both versions")
            print("PASS: File-read fallback works identically in both versions")
            print()
            print("The empty-data guard prevents MCP clients from receiving a")
            print("zero-byte PNG that looks like a successful capture.")
        } else {
            print("FAIL: unexpected behavior")
            print("  bug reproduced: \(bugReproduced), bug fixed: \(bugFixed)")
            print("  test1 (non-empty): \(test1Pass), test3 (fallback): \(test3Pass)")
        }
    }
}
