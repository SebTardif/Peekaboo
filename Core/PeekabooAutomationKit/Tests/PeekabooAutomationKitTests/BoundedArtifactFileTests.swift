import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct BoundedArtifactFileTests {
    @Test
    func `inclusive limits and ordinary symlinks remain readable`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        let file = try BoundedArtifactFile(path: link.path, maximumBytes: fixture.data.count)
        #expect(file.byteCount == fixture.data.count)
        #expect(try file.read() == fixture.data)
    }

    @Test
    func `empty file works with a zero byte limit`() throws {
        let fixture = try Fixture(data: Data())
        defer { fixture.cleanup() }
        #expect(try BoundedArtifactFile(path: fixture.url.path, maximumBytes: 0).read().isEmpty)
    }

    @Test
    func `growth after open cannot bypass the read budget`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try BoundedArtifactFile(path: fixture.url.path, maximumBytes: 16)
        let writer = try FileHandle(forWritingTo: fixture.url)
        try writer.truncate(atOffset: 1_000_000)
        try writer.close()
        #expect(throws: BoundedArtifactFileError.tooLarge) { try file.read() }
    }

    @Test
    func `replacement after open cannot publish the old inode under the new path`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try BoundedArtifactFile(path: fixture.url.path, maximumBytes: 16)
        try Data(repeating: 0x42, count: fixture.data.count).write(to: fixture.url, options: .atomic)
        #expect(throws: BoundedArtifactFileError.changedDuringRead) { try file.read() }
    }

    @Test
    func `truncation and in-budget growth after open are refused`() throws {
        for size in [0, 12] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let file = try BoundedArtifactFile(path: fixture.url.path, maximumBytes: 16)
            let writer = try FileHandle(forWritingTo: fixture.url)
            try writer.truncate(atOffset: UInt64(size))
            try writer.close()
            #expect(throws: BoundedArtifactFileError.changedDuringRead) { try file.read() }
        }
    }

    @Test
    func `special files never wait for a writer`() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fifo = fixture.root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: BoundedArtifactFileError.unreadable) {
            try BoundedArtifactFile(path: fifo.path, maximumBytes: 16)
        }
    }

    private struct Fixture {
        let root: URL
        let url: URL
        let data: Data

        init(data: Data = Data("original".utf8)) throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.url = self.root.appendingPathComponent("artifact")
            self.data = data
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: false)
            try data.write(to: self.url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
