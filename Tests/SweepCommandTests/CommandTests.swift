import Darwin
import Foundation
import Testing
import SweepCore
@testable import sweep

/// Runs `sweep` in-process and keeps what it writes.
final class Captured {
    var output = ""
    var errors = ""
    var status: Int32 = -1

    init(_ arguments: [String]) {
        status = CLI.run(arguments, console: Console(write: { self.output += $0 },
                                                     writeError: { self.errors += $0 }, showsProgress: false))
    }

    /// `--json` output, parsed.
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }
}

func parsed(_ arguments: [String]) throws -> Arguments? {
    guard case .run(let parsed) = try Arguments.parse(arguments) else { return nil }
    return parsed
}

func usageMessage(_ arguments: [String]) -> String? {
    do {
        _ = try Arguments.parse(arguments)
        return nil
    } catch {
        return (error as? UsageError)?.message
    }
}

@Suite struct ArgumentTests {
    @Test func helpIsAnsweredAnywhereBeforeTheEndOfOptions() throws {
        for line in [["--help"], ["-h"], ["help"], ["lens", "/tmp", "--help"], ["render", "-h"],
                     ["lens", "--threads", "999", "--help"]] {
            #expect(try Arguments.parse(line) == .help, "\(line)")
        }
        #expect(try parsed(["lens", "--", "--help"])?.path == "--help")
    }

    @Test func helpGoesToStandardOutputAndSucceeds() {
        let run = Captured(["--help"])
        #expect(run.status == 0)
        #expect(run.output.contains("usage: sweep lens"))
        #expect(run.errors.isEmpty)
    }

    @Test func mistakesExitWith64AndSayWhatWasWrong() {
        let run = Captured(["lens", "/tmp", "--threads", "100000"])
        #expect(run.status == 64)
        #expect(run.output.isEmpty)
        #expect(run.errors.contains("--threads takes a whole number from 1 to 64, not “100000”"))
        #expect(run.errors.contains("sweep --help"))

        let empty = Captured([])
        #expect(empty.status == 64)
        #expect(empty.errors.contains("usage: sweep lens"))
    }

    @Test func threadsStayBetweenOneAndSixtyFour() throws {
        for bad in ["0", "65", "-4", "lots"] {
            #expect(usageMessage(["lens", "x", "--threads", bad]) != nil, "\(bad)")
        }
        #expect(try parsed(["lens", "x", "--threads", "64"])?.options.threadCount == 64)
        #expect(try parsed(["render", "x", "--out", "a.png", "--threads", "1"])?.options.threadCount == 1)
    }

    @Test func optionsBelongToTheirCommand() throws {
        for flag in [["--json"], ["--logical"], ["--private-size"], ["--top", "3"], ["--depth", "2"]] {
            #expect(usageMessage(["render", "x", "--out", "a.png"] + flag) == "\(flag[0]) only works with “sweep lens”")
        }
        for flag in [["--out", "a.png"], ["--width", "800"], ["--height", "600"]] {
            #expect(usageMessage(["lens", "x"] + flag) == "\(flag[0]) only works with “sweep render”")
        }
        let shared = try parsed(["lens", "x", "--cross-mounts", "--no-dedupe", "--private-size"])
        #expect(shared?.options.crossMountPoints == true)
        #expect(shared?.options.deduplicateHardLinks == false)
        #expect(shared?.options.measurePrivateSize == true)
        #expect(usageMessage(["render", "x"]) == "render needs --out <file.png>")
    }

    @Test func doubleDashEndsTheOptions() throws {
        #expect(try parsed(["lens", "--", "-folder"])?.path == "-folder")
        let late = try parsed(["lens", "--top", "3", "--", "--json"])
        #expect(late?.path == "--json")
        #expect(late?.json == false)
        #expect(late?.top == 3)
        #expect(usageMessage(["lens", "a", "--", "b"]) == "one path at a time (got “a” and “b”)")
    }

    @Test func eachMistakeIsNamed() {
        #expect(usageMessage(["scan", "x"]) == "unknown command “scan”")
        #expect(usageMessage(["lens", "x", "--fast"]) == "unknown option --fast")
        #expect(usageMessage(["lens", "x", "--top"]) == "--top needs a value")
        #expect(usageMessage(["lens", "--json"]) == "lens needs a folder to scan")
        #expect(usageMessage(["render", "x", "--out", "a.png", "--width", "50"]) != nil)
    }
}

@Suite struct LensCommandTests {
    @Test func scanFailuresAreSentences() throws {
        let fixture = try Fixture()
        try fixture.file("plain.txt", bytes: 10)
        let missing = Captured(["lens", fixture.path("nope")])
        #expect(missing.status == 1)
        #expect(missing.errors == "sweep: Can't read “\(fixture.path("nope"))”: No such file or directory.\n")
        let file = Captured(["lens", fixture.path("plain.txt")])
        #expect(file.status == 1)
        #expect(file.errors == "sweep: “\(fixture.path("plain.txt"))” isn't a folder.\n")
    }

    @Test func jsonGivesEveryEntryAPathAndStatusDownToTheDepthAsked() throws {
        let fixture = try Fixture()
        try fixture.file("big/inner.bin", bytes: 64_000)
        try fixture.file("big/deep/d.bin", bytes: 16_000)
        try fixture.file("small.bin", bytes: 8_000)
        let run = Captured(["lens", fixture.root, "--json", "--depth", "2"])
        #expect(run.status == 0)
        let json = run.json
        #expect(json["root"] as? String == fixture.root)
        #expect(json["sortedBy"] as? String == "allocated")
        let top = try #require(json["largest"] as? [[String: Any]])
        #expect(top.map { $0["name"] as? String } == ["big", "small.bin"])
        #expect(top[1]["path"] as? String == fixture.path("small.bin"))
        #expect(top[1]["kind"] as? String == "file")
        #expect(top[1]["largest"] == nil)
        for item in top { #expect(item["status"] as? String == "scanned") }

        let inside = try #require(top[0]["largest"] as? [[String: Any]])
        #expect(inside.map { $0["path"] as? String } == [fixture.path("big/inner.bin"), fixture.path("big/deep")])
        #expect(inside[1]["isDirectory"] as? Bool == true)
        #expect(inside[1]["largest"] == nil, "deeper than --depth 2")
        #expect(json["privateBytes"] == nil)
    }

    @Test func logicalSizesAndSortsByLength() throws {
        let fixture = try Fixture()
        try fixture.file("dense.bin", bytes: 64_000)
        try fixture.sparseFile("sparse.bin", length: 8_000_000)
        let onDisk = Captured(["lens", fixture.root, "--json"]).json["largest"] as? [[String: Any]]
        #expect(onDisk?.map { $0["name"] as? String } == ["dense.bin", "sparse.bin"])

        let logical = Captured(["lens", fixture.root, "--json", "--logical"]).json
        #expect(logical["sortedBy"] as? String == "logical")
        #expect((logical["largest"] as? [[String: Any]])?.map { $0["name"] as? String } == ["sparse.bin", "dense.bin"])

        let text = Captured(["lens", fixture.root, "--logical"]).output.split(separator: "\n")
        #expect(text.count > 3)
        #expect(text[2].hasSuffix("sparse.bin"))
        #expect(text[2].contains("8 MB"))
    }

    @Test func privateSizeShowsWhatDeletingWouldFree() throws {
        let fixture = try Fixture()
        try fixture.file("original.bin", bytes: 256_000)
        try fixture.clone("original.bin", to: "copy.bin")
        try fixture.file("plain.bin", bytes: 32_000)
        let json = Captured(["lens", fixture.root, "--json", "--private-size"]).json
        let items = try #require(json["largest"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0["name"] as! String, $0) })
        func bytes(_ name: String, _ key: String) -> UInt64? { (byName[name]?[key] as? NSNumber)?.uint64Value }
        #expect(bytes("plain.bin", "privateBytes") == bytes("plain.bin", "allocatedBytes"))
        let shared = try #require(bytes("copy.bin", "privateBytes"))
        #expect(shared < bytes("copy.bin", "allocatedBytes")!, "a clone shares its blocks, so deleting it frees less")
        let total = items.reduce(UInt64(0)) { $0 + (($1["privateBytes"] as? NSNumber)?.uint64Value ?? 0) }
        #expect((json["privateBytes"] as? NSNumber)?.uint64Value == total)

        let text = Captured(["lens", fixture.root, "--private-size"]).output
        #expect(text.contains("plain.bin  (frees "))
        #expect(text.contains("deleting it all would free"))
        #expect(!Captured(["lens", fixture.root]).output.contains("frees"))
    }

    @Test func topListsTheLargestAndCountsTheRest() throws {
        let fixture = try Fixture()
        for index in 1...5 { try fixture.file("f\(index).bin", bytes: index * 10_000) }
        let json = Captured(["lens", fixture.root, "--json", "--top", "2"]).json
        #expect((json["largest"] as? [[String: Any]])?.map { $0["name"] as? String } == ["f5.bin", "f4.bin"])
        let more = try #require(json["more"] as? [String: Any])
        #expect(more["items"] as? Int == 3)
        #expect(Captured(["lens", fixture.root, "--top", "2"]).output.contains("in 3 more items"))
    }
}

/// A temporary folder under `<package>/.build/test-fixtures` that deletes itself.
final class Fixture {
    let root: String

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = package.appendingPathComponent(".build/test-fixtures/command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = realpath(folder.path, nil)!
        defer { free(resolved) }
        root = String(cString: resolved)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { root + "/" + relative }

    func file(_ relative: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes so APFS can't store the file compressed.
        var generator = SystemRandomNumberGenerator()
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
    }

    /// A file `length` bytes long with no blocks allocated.
    func sparseFile(_ relative: String, length: Int) throws {
        let descriptor = open(path(relative), O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(length)) == 0 else { throw POSIXError(.EIO) }
    }

    /// An APFS clone: a second file sharing the first one's blocks.
    func clone(_ source: String, to destination: String) throws {
        guard copyfile(path(source), path(destination), nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0 else {
            throw POSIXError(.ENOTSUP)
        }
    }
}
