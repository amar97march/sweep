import Darwin
import Foundation
import Testing
@testable import SweepCore

@Suite struct DiskTreeScannerTests {
    private func options(_ configure: (inout ScanOptions) -> Void = { _ in }) -> ScanOptions {
        var options = ScanOptions()
        options.mountPointsOverride = ["/"]
        options.skipPromptingPaths = false
        configure(&options)
        return options
    }

    private func node(_ root: DirectoryNode, _ name: String) -> DirectoryNode? {
        root.children.first { $0.name == name }
    }

    @Test func totalsMatchLstatAndSortBySize() throws {
        let fixture = try Fixture()
        try fixture.file("a/one.bin", bytes: 100_000)
        try fixture.file("a/b/two.bin", bytes: 400_000)
        try fixture.file("c/three.bin", bytes: 20_000)
        try fixture.file("top.bin", bytes: 7_000)

        let result = try DiskTreeScanner(options: options()).scan(fixture.root)
        let expected = ["a/one.bin", "a/b/two.bin", "c/three.bin", "top.bin"]
            .map(fixture.allocatedSize).reduce(0, +)

        #expect(result.root.allocatedSize == expected)
        #expect(result.root.logicalSize == 527_000)
        #expect(result.root.fileCount == 4)
        #expect(result.root.directoryCount == 3)
        #expect(result.root.children.map(\.name) == ["a", "c"])
        #expect(node(result.root, "a")?.allocatedSize
            == fixture.allocatedSize("a/one.bin") + fixture.allocatedSize("a/b/two.bin"))
        #expect(result.statistics.directories == 4)
        #expect(result.statistics.files == 4)
        #expect(result.root.status == .scanned)
    }

    @Test func countsHardLinksOnce() throws {
        let fixture = try Fixture()
        try fixture.file("x/data.bin", bytes: 200_000)
        try fixture.directory("y")
        #expect(link(fixture.path("x/data.bin"), fixture.path("y/data.bin")) == 0)
        let single = fixture.allocatedSize("x/data.bin")

        let deduplicated = try DiskTreeScanner(options: options()).scan(fixture.root)
        #expect(deduplicated.root.allocatedSize == single)
        #expect(deduplicated.statistics.hardLinkDuplicates == 1)
        #expect(deduplicated.statistics.hardLinkDuplicateBytes == single)

        let counted = try DiskTreeScanner(options: options { $0.deduplicateHardLinks = false }).scan(fixture.root)
        #expect(counted.root.allocatedSize == single * 2)
    }

    @Test func doesNotFollowSymlinks() throws {
        let fixture = try Fixture()
        try fixture.file("real/huge.bin", bytes: 1_000_000)
        #expect(symlink(fixture.path("real"), fixture.path("alias")) == 0)
        let result = try DiskTreeScanner(options: options()).scan(fixture.root)
        #expect(result.root.allocatedSize
            == fixture.allocatedSize("real/huge.bin") + fixture.allocatedSize("alias"))
        #expect(result.statistics.symlinks == 1)
        #expect(result.root.children.map(\.name) == ["real"])
    }

    @Test func keepsGoingPastUnreadableDirectories() throws {
        let fixture = try Fixture()
        try fixture.file("open/ok.bin", bytes: 30_000)
        try fixture.file("locked/secret.bin", bytes: 30_000)
        chmod(fixture.path("locked"), 0)

        let result = try DiskTreeScanner(options: options()).scan(fixture.root)
        #expect(node(result.root, "locked")?.status == .inaccessible(errno: EACCES))
        #expect(node(result.root, "open")?.status == .scanned)
        #expect(result.root.allocatedSize == fixture.allocatedSize("open/ok.bin"))
        #expect(result.statistics.inaccessibleDirectories == 1)
    }

    @Test func skipsMountPointsAndExclusions() throws {
        let fixture = try Fixture()
        try fixture.file("volume/data.bin", bytes: 50_000)
        try fixture.file("excluded/data.bin", bytes: 50_000)
        try fixture.file("kept/data.bin", bytes: 50_000)

        let result = try DiskTreeScanner(options: options {
            $0.mountPointsOverride = ["/", fixture.path("volume")]
            $0.excludedPaths = [fixture.path("excluded")]
        }).scan(fixture.root)

        #expect(node(result.root, "volume")?.status == .skippedMountPoint)
        #expect(node(result.root, "excluded")?.status == .skippedExcluded)
        #expect(result.root.allocatedSize == fixture.allocatedSize("kept/data.bin"))
        #expect(result.statistics.skippedMountPoints == 1)
        #expect(result.statistics.skippedExcluded == 1)

        let crossing = try DiskTreeScanner(options: options {
            $0.mountPointsOverride = ["/", fixture.path("volume")]
            $0.crossMountPoints = true
        }).scan(fixture.root)
        #expect(node(crossing.root, "volume")?.status == .scanned)
    }

    @Test func manyDirectoriesAcrossThreads() throws {
        let fixture = try Fixture()
        for a in 0..<20 {
            for b in 0..<20 {
                try fixture.directory("d\(a)/e\(b)")
                FileManager.default.createFile(atPath: fixture.path("d\(a)/e\(b)/f"), contents: Data(count: 10))
            }
        }
        let single = try DiskTreeScanner(options: options { $0.threadCount = 1 }).scan(fixture.root)
        let parallel = try DiskTreeScanner(options: options { $0.threadCount = 16 }).scan(fixture.root)
        #expect(single.root.fileCount == 400)
        #expect(parallel.root.fileCount == 400)
        #expect(parallel.root.directoryCount == 420)
        #expect(parallel.root.allocatedSize == single.root.allocatedSize)
    }

    @Test func rejectsFilesAndMissingPaths() throws {
        let fixture = try Fixture()
        try fixture.file("plain.txt", bytes: 3)
        #expect(throws: ScanError.notADirectory(fixture.path("plain.txt"))) {
            try DiskTreeScanner(options: options()).scan(fixture.path("plain.txt"))
        }
        let missing = #expect(throws: ScanError.self) {
            try DiskTreeScanner(options: options()).scan(fixture.path("nope"))
        }
        #expect(missing?.localizedDescription == "Can't read “\(fixture.path("nope"))”: No such file or directory.")
        #expect(missing?.needsFullDiskAccess == false)
        #expect(ScanError.unreadable("/x", errno: EPERM).needsFullDiskAccess)
    }

    @Test func cancelStopsTheScan() throws {
        let fixture = try Fixture()
        try fixture.file("a/b.bin", bytes: 10)
        let scanner = DiskTreeScanner(options: options())
        scanner.cancel()
        #expect(throws: ScanError.cancelled) { try scanner.scan(fixture.root) }
    }

    @Test func reportsProgress() throws {
        let fixture = try Fixture()
        for index in 0..<50 { try fixture.file("d\(index)/f.bin", bytes: 100) }
        let updates = Locked(0)
        _ = try DiskTreeScanner(options: options()).scan(fixture.root, progressInterval: 0) { _ in
            updates.withLock { $0 += 1 }
        }
        #expect(updates.withLock { $0 } > 0)
    }

    @Test func datalessPolicyIsAccepted() {
        #expect(DatalessFiles.disableMaterializationForCurrentThread())
    }

    @Test func mountTableIncludesRoot() {
        #expect(MountTable.mountPoints().contains("/"))
    }
}
