import Darwin
import Foundation
import Testing
@testable import SweepCore

@Suite struct RemovalPolicyTests {
    private let policy = RemovalPolicy.standard

    @Test(arguments: ["/", "/Applications", "/Users", "/System", "/usr/local", "/opt/homebrew", "/private/var"])
    func refusesRequiredFolders(path: String) {
        #expect(policy.refusal(for: path) != nil)
    }

    @Test func refusesTheHomeFolderAndItsStandardFolders() {
        let home = NSHomeDirectory()
        for path in [home, home + "/Library", home + "/Documents", home + "/Downloads"] {
            #expect(policy.refusal(for: path) == "Required folder; remove its contents instead")
        }
    }

    @Test func refusesSystemFiles() {
        #expect(policy.refusal(for: "/System/Library/CoreServices/Finder.app") == "Part of macOS")
        #expect(policy.refusal(for: "/usr/bin/true") == "Part of macOS")
    }

    @Test func refusesOddPaths() {
        #expect(policy.refusal(for: "relative/path") != nil)
        #expect(policy.refusal(for: "/tmp/../etc") != nil)
    }

    @Test func refusesMissingAndLockedFiles() throws {
        let fixture = try Fixture()
        #expect(policy.refusal(for: fixture.path("missing")) == "No longer exists")
        try fixture.file("locked.bin", bytes: 10)
        #expect(chflags(fixture.path("locked.bin"), UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(fixture.path("locked.bin"), 0) }
        #expect(policy.refusal(for: fixture.path("locked.bin"))?.hasPrefix("Locked") == true)
    }

    @Test func allowsOrdinaryFiles() throws {
        let fixture = try Fixture()
        try fixture.file("plain.bin", bytes: 10)
        #expect(policy.refusal(for: fixture.path("plain.bin")) == nil)
        #expect(policy.refusal(for: fixture.root) == nil)
    }
}

@Suite struct FileRemoverTests {
    @Test func deletesPermanentlyAndLogs() throws {
        let fixture = try Fixture()
        try fixture.file("folder/a.bin", bytes: 1_000)
        try fixture.file("b.bin", bytes: 2_000)
        let log = URL(fileURLWithPath: fixture.path("removals.jsonl"))
        let remover = FileRemover(policy: .confined(to: [fixture.root]), logURL: log)

        let records = remover.remove([
            RemovalRequest(path: fixture.path("folder"), bytes: 1_000),
            RemovalRequest(path: fixture.path("b.bin"), bytes: 2_000),
        ], mode: .deletePermanently)

        #expect(records.map(\.outcome) == [.deleted, .deleted])
        #expect(!FileManager.default.fileExists(atPath: fixture.path("folder")))
        #expect(!FileManager.default.fileExists(atPath: fixture.path("b.bin")))
        let logged = try RemovalLog.read(from: log)
        #expect(logged.map(\.path) == [fixture.path("folder"), fixture.path("b.bin")])
        #expect(logged.allSatisfy { $0.mode == .deletePermanently && $0.succeeded })
    }

    @Test func movesToTrash() throws {
        let fixture = try Fixture()
        try fixture.file("trash-me-\(UUID().uuidString).bin", bytes: 500)
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.root).first)
        let record = try #require(fixture.remover.remove([RemovalRequest(path: fixture.path(name), bytes: 500)],
                                                         mode: .moveToTrash).first)
        guard case .trashed(let location) = record.outcome else {
            Issue.record("expected the file in the Trash, got \(record.outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.path(name)))
        #expect(FileManager.default.fileExists(atPath: location))
        #expect(location.hasPrefix(fixture.root + "/.Trash/"))  // the sandbox Trash, not the user's
    }

    @Test func skipsRefusedItemsWithoutTouchingThem() throws {
        let fixture = try Fixture()
        try fixture.file("keep.bin", bytes: 10)
        chflags(fixture.path("keep.bin"), UInt32(UF_IMMUTABLE))
        defer { chflags(fixture.path("keep.bin"), 0) }

        let records = fixture.remover.remove([
            RemovalRequest(path: fixture.path("keep.bin"), bytes: 10),
            RemovalRequest(path: "/System", bytes: 0),
        ], mode: .deletePermanently)

        #expect(records.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: fixture.path("keep.bin")))
    }

    @Test func reportsFailures() throws {
        let fixture = try Fixture()
        try fixture.file("sealed/inner.bin", bytes: 10)
        chmod(fixture.path("sealed"), 0o555)  // can't delete entries of a read-only folder
        defer { chmod(fixture.path("sealed"), 0o755) }

        let record = try #require(fixture.remover.remove(
            [RemovalRequest(path: fixture.path("sealed/inner.bin"), bytes: 10)], mode: .deletePermanently).first)
        #expect(record.outcome == .failed(reason: "Permission denied"))
    }

    @Test func reportsProgress() throws {
        let fixture = try Fixture()
        for index in 0..<3 { try fixture.file("f\(index)", bytes: 1) }
        let seen = Locked<[Int]>([])
        _ = fixture.remover.remove(
            (0..<3).map { RemovalRequest(path: fixture.path("f\($0)"), bytes: 1) }, mode: .deletePermanently
        ) { done, _ in seen.withLock { $0.append(done) } }
        #expect(seen.withLock { $0 } == [1, 2, 3])
    }
}

@Suite struct ConfinementTests {
    @Test func confinedRemoversRefuseEverythingOutsideTheirRoot() throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        try outside.file("precious.bin", bytes: 10)
        let records = fixture.remover.remove([RemovalRequest(path: outside.path("precious.bin"), bytes: 10)],
                                             mode: .deletePermanently)
        #expect(records.first?.outcome == .skipped(reason: "Outside the folders this remover may change"))
        #expect(FileManager.default.fileExists(atPath: outside.path("precious.bin")))
    }
}

@Suite struct TreeRemovalTests {
    @Test func removingEntriesUpdatesEveryAncestor() throws {
        let fixture = try Fixture()
        try fixture.file("a/b/big.bin", bytes: 300_000)
        try fixture.file("a/b/small.bin", bytes: 4_000)
        try fixture.file("a/other.bin", bytes: 50_000)
        var options = ScanOptions()
        options.mountPointsOverride = ["/"]
        let root = try DiskTreeScanner(options: options).scan(fixture.root).root
        let a = try #require(root.children.first { $0.name == "a" })
        let b = try #require(a.children.first { $0.name == "b" })
        let big = fixture.allocatedSize("a/b/big.bin")
        let before = (root: root.allocatedSize, a: a.allocatedSize, b: b.allocatedSize)

        #expect(b.removeEntry(named: "big.bin"))
        #expect(b.allocatedSize == before.b - big)
        #expect(a.allocatedSize == before.a - big)
        #expect(root.allocatedSize == before.root - big)
        #expect(root.fileCount == 2)

        let bSize = b.allocatedSize
        #expect(a.removeEntry(named: "b"))
        #expect(root.allocatedSize == before.root - big - bSize)
        #expect(root.directoryCount == 1)
        #expect(root.fileCount == 1)
        #expect(!a.removeEntry(named: "b"))
    }
}
