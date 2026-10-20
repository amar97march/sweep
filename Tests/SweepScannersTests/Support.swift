import Darwin
import Foundation
import Testing
@testable import SweepScanners

/// A fake home folder and system root that delete themselves.
final class FakeMac {
    let root: String
    var home: String { root + "/home" }
    var system: String { root + "/system" }

    init() throws {
        root = try TestSandbox.newFolder("scanners")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: system, withIntermediateDirectories: true)
    }

    deinit { TestSandbox.remove(root) }

    /// A remover that can only touch this fake Mac and uses `<root>/.Trash` as its Trash.
    var remover: FileRemover { FileRemover.sandboxed(in: root) }

    func environment(running: Set<String> = []) -> ScanEnvironment {
        ScanEnvironment(home: home, systemRoot: system, runningBundleIDs: running, preferredLanguages: ["en"],
                        now: Date())
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 20_000, contents: Data? = nil) throws -> String {
        let full = path.hasPrefix("/") ? path : home + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let data = contents ?? Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: URL(fileURLWithPath: full))
        return full
    }

    @discardableResult
    func systemFile(_ path: String, bytes: Int = 20_000) throws -> String {
        try file(system + path, bytes: bytes)
    }

    @discardableResult
    func app(_ name: String, bundleID: String, in folder: String? = nil, extra: [String: Any] = [:]) throws -> String {
        let path = (folder ?? system + "/Applications") + "/\(name).app"
        var info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": name,
                                   "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
        info.merge(extra) { $1 }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try file(path + "/Contents/Info.plist", contents: data)
        try file(path + "/Contents/MacOS/\(name)", bytes: 4_000)
        return path
    }

    @discardableResult
    func plist(_ path: String, _ value: Any) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        return try file(path, contents: data)
    }
}

extension Array where Element == SweepCore.ScanCategory {
    func category(_ id: String) -> SweepCore.ScanCategory? { first { $0.id == id } }
    var allItems: [SweepCore.ScanItem] { flatMap { $0.groups.flatMap(\.items) } }
}

import SweepCore

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
