import Darwin
import Foundation
import Testing
@testable import SweepCore

@Suite struct BulkDirectoryReaderTests {
    @Test func reportsKindsAndExactSizes() throws {
        let fixture = try Fixture()
        try fixture.file("small.bin", bytes: 1_000)
        try fixture.file("big.bin", bytes: 300_000)
        try fixture.file("nested/inner.txt", bytes: 10)
        #expect(symlink("big.bin", fixture.path("link")) == 0)
        #expect(mkfifo(fixture.path("pipe"), 0o644) == 0)
        try fixture.file("名前 with spaces.txt", bytes: 5)

        var entries: [String: DirectoryEntry] = [:]
        let error = BulkDirectoryReader().read(fixture.root) { entries[$0.name] = $0 }

        #expect(error == nil)
        #expect(Set(entries.keys) == ["small.bin", "big.bin", "nested", "link", "pipe", "名前 with spaces.txt"])
        #expect(entries["small.bin"]?.kind == .file)
        #expect(entries["small.bin"]?.logicalSize == 1_000)
        #expect(entries["big.bin"]?.logicalSize == 300_000)
        #expect(entries["big.bin"]?.allocatedSize == fixture.allocatedSize("big.bin"))
        #expect(entries["nested"]?.kind == .directory)
        #expect(entries["link"]?.kind == .symlink)
        #expect(entries["link"]?.logicalSize == UInt64("big.bin".utf8.count))
        #expect(entries["pipe"]?.kind == .other)
        #expect(entries["名前 with spaces.txt"]?.logicalSize == 5)
    }

    @Test func handlesDirectoriesLargerThanOneBuffer() throws {
        let fixture = try Fixture()
        for index in 0..<2_500 {
            FileManager.default.createFile(atPath: fixture.path("f\(index)"), contents: Data([1]))
        }
        var names = Set<String>()
        // The minimum buffer forces many getattrlistbulk calls.
        let error = BulkDirectoryReader(bufferSize: 1024).read(fixture.root) { names.insert($0.name) }
        #expect(error == nil)
        #expect(names.count == 2_500)
    }

    @Test func reportsOpenErrors() throws {
        let fixture = try Fixture()
        try fixture.directory("locked")
        chmod(fixture.path("locked"), 0)
        let error = BulkDirectoryReader().read(fixture.path("locked")) { _ in }
        #expect(error == .open(errno: EACCES))
        #expect(BulkDirectoryReader().read(fixture.path("missing")) { _ in } == .open(errno: ENOENT))
    }

    @Test func refusesToFollowSymlinkedDirectories() throws {
        let fixture = try Fixture()
        try fixture.directory("real")
        #expect(symlink("real", fixture.path("alias")) == 0)
        // O_DIRECTORY | O_NOFOLLOW on a symlink fails with ENOTDIR on macOS.
        #expect(BulkDirectoryReader().read(fixture.path("alias")) { _ in } == .open(errno: ENOTDIR))
    }

    @Test func detectsHardLinks() throws {
        let fixture = try Fixture()
        try fixture.file("original", bytes: 50_000)
        #expect(link(fixture.path("original"), fixture.path("second")) == 0)
        var entries: [String: DirectoryEntry] = [:]
        BulkDirectoryReader().read(fixture.root) { entries[$0.name] = $0 }
        #expect(entries["original"]?.linkCount == 2)
        #expect(entries["original"]?.fileID == entries["second"]?.fileID)
    }

    @Test func privateSizeSeesAPFSClones() throws {
        let fixture = try Fixture()
        try fixture.file("original", bytes: 2_000_000)
        let reader = BulkDirectoryReader(measurePrivateSize: true)

        var before: DirectoryEntry?
        reader.read(fixture.root) { before = $0 }
        #expect(before?.privateSize == before?.allocatedSize)

        // A clone shares all its blocks with the original, so neither frees anything on its own.
        try #require(clonefile(fixture.path("original"), fixture.path("clone"), 0) == 0)
        var after: [String: DirectoryEntry] = [:]
        reader.read(fixture.root) { after[$0.name] = $0 }
        #expect(after["original"]?.privateSize == 0)
        #expect(after["clone"]?.privateSize == 0)
        #expect(after["clone"]?.allocatedSize == before?.allocatedSize)
    }
}
