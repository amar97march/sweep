import Darwin
import Testing
import Foundation
@testable import SweepCore

/// A temporary directory tree that deletes itself.
final class Fixture {
    let root: String

    init() throws {
        root = try TestSandbox.newFolder("core")
    }

    /// A remover that can only touch this fixture and uses `<root>/.Trash` as its Trash.
    var remover: FileRemover { FileRemover.sandboxed(in: root) }

    deinit {
        TestSandbox.remove(root)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func file(_ relative: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Non-repeating bytes so APFS cannot store the file compressed or sparse.
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: url)
    }

    /// Bytes on disk according to `lstat`, for comparison with the scanner.
    func allocatedSize(_ relative: String) -> UInt64 {
        var info = stat()
        precondition(lstat(path(relative), &info) == 0)
        return UInt64(info.st_blocks) * 512
    }
}

/// Every test file lives under `<package>/.build/test-fixtures`, never elsewhere on the Mac.
enum TestSandbox {
    static let root: String = {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = package.appendingPathComponent(".build/test-fixtures")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = realpath(folder.path, nil)!
        defer { free(resolved) }
        return String(cString: resolved)
    }()

    /// Deletes a fixture, first unlocking folders a test made unreadable (`chmod 0`, `chflags uchg`).
    static func remove(_ path: String) {
        func unlock(_ folder: String) {
            chmod(folder, 0o755)
            chflags(folder, 0)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let child = folder + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                chflags(child, 0)
                if info.st_mode & S_IFMT == S_IFDIR { unlock(child) }
            }
        }
        unlock(path)
        try? FileManager.default.removeItem(atPath: path)
    }

    static func newFolder(_ prefix: String) throws -> String {
        let path = root + "/" + prefix + "-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
