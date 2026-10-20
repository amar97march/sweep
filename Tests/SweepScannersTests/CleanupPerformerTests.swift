import Darwin
import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct CleanupPerformerTests {
    private func item(_ path: String, size: UInt64 = 100, mode: RemovalMode = .deletePermanently) -> ScanItem {
        ScanItem(id: path, title: (path as NSString).lastPathComponent, size: size, isSelectedByDefault: true,
                 action: .remove(paths: [path], mode: mode))
    }

    @Test func removesItemsAndReportsEach() throws {
        let mac = try FakeMac()
        let a = try mac.file("Library/Caches/a/x.bin")
        let b = try mac.file("Library/Caches/b.bin")
        let records = CleanupPerformer.perform([item(a), item(b)], remover: mac.remover,
                                               allowAdministrator: false)
        #expect(records.map(\.outcome) == [.done("Removed"), .done("Removed")])
        #expect(records.map(\.itemID) == [a, b])
        #expect(!FileManager.default.fileExists(atPath: a) && !FileManager.default.fileExists(atPath: b))
    }

    @Test func administratorIsNeverUsedToMoveThingsToTheTrash() throws {
        let mac = try FakeMac()
        let locked = try mac.file("Library/Caches/sealed/inner.bin")
        let folder = (locked as NSString).deletingLastPathComponent
        chmod(folder, 0o555)
        defer { chmod(folder, 0o755) }
        let asked = Locked<[[String]]>([])
        let records = CleanupPerformer.perform([item(locked, mode: .moveToTrash)], remover: mac.remover, allowAdministrator: true,
                                               administrator: { paths in asked.withLock { $0.append(paths) }; return .success(()) })
        #expect(asked.withLock { $0 }.isEmpty)
        #expect(records.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: locked))
    }

    @Test func pathsThroughSymlinksAreNeverHandedToRoot() throws {
        let mac = try FakeMac()
        let locked = try mac.file("Library/Caches/sealed/inner.bin")
        let folder = (locked as NSString).deletingLastPathComponent
        let link = mac.home + "/Library/Caches/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder)
        chmod(folder, 0o555)
        defer { chmod(folder, 0o755) }
        let asked = Locked<[[String]]>([])
        _ = CleanupPerformer.perform([item(link + "/inner.bin")], remover: mac.remover, allowAdministrator: true,
                                     administrator: { paths in asked.withLock { $0.append(paths) }; return .success(()) })
        #expect(asked.withLock { $0 }.isEmpty)
    }

    @Test func rootRemovalQuotesEveryPath() {
        let command = Administrator.removeCommand(["/Library/Caches/it's here", "/tmp/a b;rm -rf ~"])
        #expect(command == "/bin/rm -rf -- '/Library/Caches/it'\\''s here' '/tmp/a b;rm -rf ~'")
        let long = Administrator.removeCommand((0..<10).map { "/p/\($0)" }, chunkLength: 20)
        #expect(long.components(separatedBy: "; ").count > 1)
        #expect(long.components(separatedBy: "; ").allSatisfy { $0.hasPrefix("/bin/rm -rf -- '") })
    }

    @Test func trashSettingAppliesWhenCleaning() {
        let cache = item("/Users/me/Library/Caches/app")
        let trashed = item("/Users/me/.Trash/old.zip")
        let model = item("/Users/me/.ollama/models/blob", mode: .moveToTrash)
        let kept = CleanupPerformer.applyingTrashPreference([cache, trashed, model], usesTrash: false)
        #expect(kept.map(\.action) == [cache.action, trashed.action, model.action])
        let moved = CleanupPerformer.applyingTrashPreference([cache, trashed, model], usesTrash: true)
        #expect(moved[0].action == .remove(paths: ["/Users/me/Library/Caches/app"], mode: .moveToTrash))
        #expect(moved[1].action == trashed.action)
        #expect(moved[2].action == model.action)
    }

    @Test func retriesPermissionFailuresOnceWithAdministrator() throws {
        let mac = try FakeMac()
        let locked = try mac.file("Library/Caches/sealed/inner.bin")
        let open = try mac.file("Library/Caches/open.bin")
        let folder = (locked as NSString).deletingLastPathComponent
        chmod(folder, 0o555)
        defer { chmod(folder, 0o755) }

        let calls = Locked<[[String]]>([])
        let records = CleanupPerformer.perform(
            [item(locked), item(open)], remover: mac.remover, allowAdministrator: true,
            administrator: { paths in
                calls.withLock { $0.append(paths) }
                chmod(folder, 0o755)  // stand-in for root: make it removable, then remove
                for path in paths { try? FileManager.default.removeItem(atPath: path) }
                return .success(())
            })

        #expect(calls.withLock { $0 } == [[locked]])
        #expect(records.first?.outcome == .done("Removed with administrator permission"))
        #expect(records.last?.outcome == .done("Removed"))
    }

    @Test func reportsCancelledAdministratorPrompt() throws {
        let mac = try FakeMac()
        let locked = try mac.file("Library/Caches/sealed/inner.bin")
        let folder = (locked as NSString).deletingLastPathComponent
        chmod(folder, 0o555)
        defer { chmod(folder, 0o755) }

        let records = CleanupPerformer.perform([item(locked)], remover: mac.remover,
                                               allowAdministrator: true, administrator: { _ in .failure(.cancelled) })
        #expect(records.first?.outcome == .failed("Needs your administrator password"))
        #expect(FileManager.default.fileExists(atPath: locked))
    }

    @Test func refusedPathsAreSkippedWithoutPrompting() throws {
        let mac = try FakeMac()
        let records = CleanupPerformer.perform([item("/System/Library")], remover: mac.remover,
                                               allowAdministrator: true,
                                               administrator: { _ in Issue.record("must not prompt"); return .success(()) })
        #expect(records.first?.succeeded == false)
    }

    @Test func shellQuoting() {
        #expect(Administrator.shellQuote("it's a file") == #"'it'\''s a file'"#)
        #expect(Administrator.appleScriptEscape(#"say "hi" \ now"#) == #"say \"hi\" \\ now"#)
    }
}
