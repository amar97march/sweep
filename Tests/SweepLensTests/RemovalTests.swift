import Foundation
import Testing
@testable import SweepCore
@testable import SweepLens

@MainActor
@Suite struct MarkingAndRemovalTests {
    /// root/ big/ (a.bin 400 KB, b.bin 100 KB), small/ (c.bin 10 KB), top.bin 50 KB
    private func scanFixture() throws -> (ScanResult, String) {
        let base = URL(fileURLWithPath: try TestSandbox.newFolder("removal"))
        let files = ["big/a.bin": 400_000, "big/b.bin": 100_000, "small/c.bin": 10_000, "top.bin": 50_000]
        for (path, size) in files {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var generator = SystemRandomNumberGenerator()
            try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
        }
        var options = ScanOptions()
        options.mountPointsOverride = ["/"]
        let result = try DiskTreeScanner(options: options).scan(base.path)
        return (result, result.root.path)
    }

    private func item(_ model: LensModel, _ name: String) throws -> LensItem {
        try #require(model.items.first { $0.name == name })
    }

    @Test func markingAFolderCoversItsContents() throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let big = try item(model, "big")

        model.open(big)
        let inner = try item(model, "a.bin")
        model.toggleMark(inner)
        #expect(model.marked.count == 1)

        model.goBack()
        model.toggleMark(big)  // replaces the mark on a.bin
        #expect(Array(model.marked.keys) == [big.id])
        #expect(model.markedSize == big.size)
        #expect(model.isCoveredByMarkedFolder(inner))

        model.toggleMark(inner)  // covered items can't be marked separately
        #expect(model.marked.count == 1)
        model.toggleMark(big)
        #expect(model.marked.isEmpty)
    }

    @Test func otherItemsCannotBeMarked() throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let other = try #require(LensItem.items(of: result.root, limit: 1, minimumFraction: 0).last)
        #expect(!model.canMark(other))
        model.toggleMark(other)
        #expect(model.marked.isEmpty)
    }

    @Test func removalSessionDeletesUpdatesTheTreeAndReports() async throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let big = try item(model, "big")
        let top = try item(model, "top.bin")
        let before = result.root.allocatedSize
        model.toggleMark(big)
        model.toggleMark(top)

        let session = RemovalSession(items: model.markedItems, remover: FileRemover.sandboxed(in: path))
        #expect(session.warnings.isEmpty)
        session.deletesPermanently = true
        session.start(updating: model)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .finished = session.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .finished(let records) = session.phase else {
            Issue.record("removal did not finish")
            return
        }
        #expect(records.count == 2 && records.allSatisfy(\.succeeded))
        #expect(!FileManager.default.fileExists(atPath: big.path!))
        #expect(!FileManager.default.fileExists(atPath: top.path!))
        #expect(result.root.allocatedSize == before - big.size - top.size)
        #expect(model.items.map(\.name) == ["small"])
        #expect(model.marked.isEmpty)
    }

    @Test func previewSessionsNeverRemoveAnything() async throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let top = try item(model, "top.bin")
        model.toggleMark(top)

        let session = RemovalSession(items: model.markedItems, remover: FileRemover.sandboxed(in: path))
        session.preview(.review)
        session.deletesPermanently = true
        session.start(updating: model)
        try await Task.sleep(for: .milliseconds(200))

        guard case .review = session.phase else {
            Issue.record("a preview session started removing")
            return
        }
        #expect(FileManager.default.fileExists(atPath: top.path!))
        #expect(model.isMarked(top))
    }

    @Test func itemsTheReviewSaidWouldBeSkippedStaySkipped() async throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        // Not there when the review opens ("No longer exists"), back by the time the user confirms.
        let late = path + "/late.bin"
        let item = LensItem(id: late, name: "late.bin", size: 10, kind: .file, path: late, directory: nil, container: result.root)
        let session = RemovalSession(items: [item], remover: FileRemover.sandboxed(in: path))
        #expect(session.warnings[late] != nil)
        try Data(count: 10).write(to: URL(fileURLWithPath: late))

        session.start(updating: model)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .finished = session.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .finished(let records) = session.phase else { Issue.record("removal did not finish"); return }
        #expect(FileManager.default.fileExists(atPath: late))
        #expect(records.count == 1 && !records[0].succeeded)
    }

    @Test func runningAppsBlockFoldersAroundThemAndFilesInsideThem() {
        let running = [(bundle: "/Applications/Xcode.app", name: "Xcode")]
        let blocked = RunningApplications.blocking(["/Applications", "/Applications/Xcode.app/Contents/Developer/Platforms/X.platform",
                                                    "/Applications/Other.app"], running: running)
        #expect(blocked == ["/Applications": "Xcode", "/Applications/Xcode.app/Contents/Developer/Platforms/X.platform": "Xcode"])
    }

    @Test func skippedItemsAreWrittenToTheRemovalLog() async throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let log = URL(fileURLWithPath: path + "/removals.jsonl")
        let remover = FileRemover(policy: .confined(to: [path]), logURL: log) { url in
            let destination = URL(fileURLWithPath: path + "/.Trash-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        let gone = path + "/gone.bin"
        let item = LensItem(id: gone, name: "gone.bin", size: 10, kind: .file, path: gone, directory: nil, container: result.root)
        let session = RemovalSession(items: [item], remover: remover)
        session.start(updating: model)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .finished = session.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let records = try RemovalLog.read(from: log)
        #expect(records.map(\.path) == [gone])
        if case .skipped = records.first?.outcome {} else { Issue.record("not logged as skipped") }
    }

    @Test func protectedItemsAreFlaggedBeforeRemoval() throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let systemFolder = LensItem(id: "/System", name: "System", size: 1, kind: .directory, path: "/System",
                                    directory: nil, container: result.root)
        let session = RemovalSession(items: [systemFolder], remover: FileRemover.sandboxed(in: path))
        #expect(session.warnings["/System"] != nil)
        #expect(session.removableItems.isEmpty)
    }
}
