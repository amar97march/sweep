import Foundation
import Testing
@testable import SweepCore
@testable import SweepLens

@Suite struct SizeHistoryTests {
    private func write(_ path: String, bytes: Int) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private func scan(_ path: String) throws -> DirectoryNode {
        var options = ScanOptions()
        options.mountPointsOverride = ["/"]
        return try DiskTreeScanner(options: options).scan(path).root
    }

    @Test func growthIsNarrowedToWhereItHappened() throws {
        let base = try TestSandbox.newFolder("growth")
        defer { TestSandbox.remove(base) }
        try write(base + "/Library/Caches/app/blob", bytes: 200_000)
        try write(base + "/Documents/report.pdf", bytes: 120_000)
        let before = SizeSnapshot(of: try scan(base), date: Date(timeIntervalSince1970: 1_000), threshold: 10_000)

        // All the growth is inside one deep folder, plus one new big file at the top.
        try write(base + "/Library/Caches/app/more", bytes: 600_000)
        try write(base + "/Movie.mov", bytes: 300_000)
        let after = try scan(base)
        let growth = before.growth(of: after, minimum: 100_000)
        // The new file inside the cache explains all of Library's growth, so it's listed instead of Library.
        #expect(growth.map(\.path) == [base + "/Library/Caches/app/more", base + "/Movie.mov"])
        #expect(growth.allSatisfy { $0.before == nil })

        // Growth spread over several small files stays at the folder that holds them.
        let spread = SizeSnapshot(of: after, date: Date(), threshold: 10_000)
        for index in 0..<10 { try write(base + "/Documents/page\(index).png", bytes: 30_000) }
        let documents = try #require(spread.growth(of: try scan(base), minimum: 100_000).first)
        #expect(documents.path == base + "/Documents")
        #expect(documents.before != nil && documents.delta >= 300_000)
    }

    @Test func previousSizes() {
        let snapshot = SizeSnapshot(root: "/Users/me", date: Date(), sizes: ["/Users/me": 900, "/Users/me/Library": 600],
                                    depth: 2, threshold: 100)
        #expect(snapshot.previous("/Users/me/Library") == .size(600))
        #expect(snapshot.previous("/Users/me/Movies") == .belowThreshold)
        #expect(snapshot.previous("/Users/me/Library/Caches") == .belowThreshold)
        #expect(snapshot.previous("/Users/me/Movies/Clips") == .unknown)
        #expect(snapshot.previous("/Applications") == .unknown)
    }

    @MainActor
    @Test func lensModelShowsChangesPerItem() throws {
        let base = try TestSandbox.newFolder("growth-items")
        defer { TestSandbox.remove(base) }
        try write(base + "/big/file", bytes: 150_000)
        try write(base + "/same/file", bytes: 150_000)
        let before = SizeSnapshot(of: try scan(base), date: Date(), threshold: 10_000)
        try write(base + "/big/extra", bytes: 400_000)
        try write(base + "/new/file", bytes: 50_000)

        var options = ScanOptions()
        options.mountPointsOverride = ["/"]
        let model = LensModel(result: try DiskTreeScanner(options: options).scan(base), baseline: before)
        func change(_ name: String) -> LensModel.ItemChange? { model.change(for: model.items.first { $0.name == name }!) }
        guard case .changed(let grown) = change("big") else { Issue.record("no change for big"); return }
        #expect(grown >= 400_000)
        #expect(change("same") == .changed(0))
        #expect(change("new") == .new)
        #expect(model.totalChange.map { $0 > 400_000 } == true)
    }

    @Test func historyKeepsTheNewestSnapshotsOnDisk() throws {
        let base = try TestSandbox.newFolder("history")
        defer { TestSandbox.remove(base) }
        let history = SizeHistory(folder: URL(fileURLWithPath: base), keep: 2)
        for seconds in [100, 200, 300] {
            history.save(SizeSnapshot(root: "/Users/me", date: Date(timeIntervalSince1970: TimeInterval(seconds)),
                                      sizes: ["/Users/me": UInt64(seconds)], depth: 1, threshold: 1))
        }
        #expect(history.dates(for: "/Users/me").map(\.timeIntervalSince1970) == [300, 200])
        #expect(history.latest(for: "/Users/me")?.sizes["/Users/me"] == 300)
        #expect(history.dates(for: "/Other").isEmpty)

        let memory = SizeHistory(folder: nil, keep: 1)
        memory.save(SizeSnapshot(root: "/", date: Date(timeIntervalSince1970: 1), sizes: [:], depth: 1, threshold: 1))
        memory.save(SizeSnapshot(root: "/", date: Date(timeIntervalSince1970: 2), sizes: [:], depth: 1, threshold: 1))
        #expect(memory.dates(for: "/").map(\.timeIntervalSince1970) == [2])
    }

    @Test func twoScansInTheSameSecondAreBothKept() throws {
        let base = try TestSandbox.newFolder("history-ms")
        defer { TestSandbox.remove(base) }
        let history = SizeHistory(folder: URL(fileURLWithPath: base))
        let first = Date(timeIntervalSince1970: 1_000_000.100)
        history.save(SizeSnapshot(root: "/r", date: first, sizes: ["/r": 1], depth: 1, threshold: 1))
        history.save(SizeSnapshot(root: "/r", date: first.addingTimeInterval(0.5), sizes: ["/r": 2], depth: 1, threshold: 1))
        #expect(history.dates(for: "/r").count == 2)
        // Files from early builds, named in seconds, still load.
        let old = URL(fileURLWithPath: base).appendingPathComponent(SizeHistory.key("/r")).appendingPathComponent("900000.json")
        try JSONEncoder().encode(SizeSnapshot(root: "/r", date: Date(timeIntervalSince1970: 900_000), sizes: [:], depth: 1, threshold: 1))
            .write(to: old)
        #expect(history.dates(for: "/r").last == Date(timeIntervalSince1970: 900_000))
    }

    @Test func anUnreadableSnapshotFallsBackToTheNextOne() throws {
        let base = try TestSandbox.newFolder("history-bad")
        defer { TestSandbox.remove(base) }
        let history = SizeHistory(folder: URL(fileURLWithPath: base))
        history.save(SizeSnapshot(root: "/r", date: Date(timeIntervalSince1970: 1_000), sizes: ["/r": 7], depth: 1, threshold: 1))
        let broken = URL(fileURLWithPath: base).appendingPathComponent(SizeHistory.key("/r"))
            .appendingPathComponent(SizeHistory.fileName(Date(timeIntervalSince1970: 2_000)))
        try Data("not json".utf8).write(to: broken)
        let found = try #require(history.latestReadable(for: "/r"))
        #expect(found.snapshot.sizes["/r"] == 7)
        #expect(found.dates == [Date(timeIntervalSince1970: 1_000)])
        #expect(!FileManager.default.fileExists(atPath: broken.path))
    }

    @Test func historyOfFoldersNotScannedForMonthsIsForgotten() throws {
        let base = try TestSandbox.newFolder("history-old")
        defer { TestSandbox.remove(base) }
        let history = SizeHistory(folder: URL(fileURLWithPath: base))
        let now = Date()
        history.save(SizeSnapshot(root: "/old", date: now.addingTimeInterval(-400 * 86_400), sizes: [:], depth: 1, threshold: 1))
        history.save(SizeSnapshot(root: "/recent", date: now.addingTimeInterval(-10 * 86_400), sizes: [:], depth: 1, threshold: 1))
        history.save(SizeSnapshot(root: "/current", date: now, sizes: [:], depth: 1, threshold: 1))
        #expect(history.dates(for: "/old").isEmpty)
        #expect(history.dates(for: "/recent").count == 1)
        #expect(history.dates(for: "/current").count == 1)
    }
}
