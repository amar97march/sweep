import CryptoKit
import Foundation
import SweepCore

/// Sizes from one Disk Map scan, kept so a later scan of the same place can show what grew.
public struct SizeSnapshot: Codable, Sendable, Equatable {
    /// What one path measured last time.
    public enum Previous: Equatable, Sendable {
        case size(UInt64)
        /// Not recorded although its folder was: it was smaller than `threshold`, or didn't exist yet.
        case belowThreshold
        /// Deeper than the snapshot reaches.
        case unknown
    }

    public let root: String
    public let date: Date
    /// Allocated bytes of folders and files at least `threshold` bytes big, down to `depth` levels below the root.
    public let sizes: [String: UInt64]
    public let depth: Int
    public let threshold: UInt64

    public init(root: String, date: Date, sizes: [String: UInt64], depth: Int, threshold: UInt64) {
        self.root = root
        self.date = date
        self.sizes = sizes
        self.depth = depth
        self.threshold = threshold
    }

    /// Records `node`'s tree.
    public init(of node: DirectoryNode, date: Date, depth: Int = 6, threshold: UInt64 = 20_000_000) {
        var sizes: [String: UInt64] = [node.path: node.allocatedSize]
        var stack: [(DirectoryNode, Int)] = [(node, 0)]
        while let (folder, level) = stack.popLast() {
            guard level < depth else { continue }
            for child in folder.children where child.allocatedSize >= threshold {
                sizes[child.path] = child.allocatedSize
                stack.append((child, level + 1))
            }
            for file in folder.files where file.allocatedSize >= threshold {
                sizes[Self.join(folder.path, file.name)] = file.allocatedSize
            }
        }
        self.init(root: node.path, date: date, sizes: sizes, depth: depth, threshold: threshold)
    }

    public func previous(_ path: String) -> Previous {
        if let size = sizes[path] { return .size(size) }
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return .unknown }
        let parent = (path as NSString).deletingLastPathComponent
        return sizes[parent] != nil && level(of: path) <= depth ? .belowThreshold : .unknown
    }

    func level(of path: String) -> Int {
        let relative = root == "/" ? path.dropFirst() : path.dropFirst(root.count + 1)
        return relative.split(separator: "/").count
    }

    static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }
}

/// A place where the space grew between two scans.
public struct Growth: Identifiable, Sendable, Equatable {
    public let path: String
    public let now: UInt64
    /// Nil when it was under the snapshot's threshold, usually because it's new.
    public let before: UInt64?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var delta: Int64 { Int64(now) - Int64(before ?? 0) }
}

extension SizeSnapshot {
    /// Where `root` grew since this snapshot, narrowed down to the folders or files that explain it.
    ///
    /// Starting at the root, growth is followed into the children that account for most of it, so a
    /// 20 GB increase shows up as "~/Library/Containers/com.docker.docker" rather than as "~/Library".
    public func growth(of root: DirectoryNode, minimum: UInt64 = 100_000_000, limit: Int = 12) -> [Growth] {
        func change(_ path: String, now: UInt64) -> Growth? {
            switch previous(path) {
            case .size(let before): return Growth(path: path, now: now, before: before)
            case .belowThreshold: return Growth(path: path, now: now, before: nil)
            case .unknown: return nil
            }
        }
        var found: [Growth] = []
        func explain(_ node: DirectoryNode, _ growth: Growth) {
            let grown = node.children.compactMap { child in change(child.path, now: child.allocatedSize).map { (child, $0) } }
                .filter { $0.1.delta >= Int64(minimum) }
            let files = node.files.compactMap { file in change(Self.join(node.path, file.name), now: file.allocatedSize) }
                .filter { $0.delta >= Int64(minimum) }
            let explained = grown.reduce(Int64(0)) { $0 + $1.1.delta } + files.reduce(Int64(0)) { $0 + $1.delta }
            if !grown.isEmpty || !files.isEmpty, Double(explained) >= Double(growth.delta) * 0.7 {
                for (child, childGrowth) in grown { explain(child, childGrowth) }
                found += files
            } else {
                found.append(growth)
            }
        }
        for child in root.children {
            if let growth = change(child.path, now: child.allocatedSize), growth.delta >= Int64(minimum) { explain(child, growth) }
        }
        found += root.files.compactMap { change(Self.join(root.path, $0.name), now: $0.allocatedSize) }
            .filter { $0.delta >= Int64(minimum) }
        return Array(found.sorted { $0.delta > $1.delta }.prefix(limit))
    }
}

/// Snapshots of past scans, newest first, a few per scanned folder.
public final class SizeHistory: @unchecked Sendable {
    /// Where snapshots are written; nil keeps them in memory only (tests and screenshots).
    public let folder: URL?
    public let keep: Int
    private let memory = Locked<[String: [SizeSnapshot]]>([:])

    public init(folder: URL?, keep: Int = 8) {
        self.folder = folder
        self.keep = keep
    }

    /// Dates of earlier scans of `root`, newest first.
    public func dates(for root: String) -> [Date] {
        guard let folder else { return memory.withLock { ($0[root] ?? []).map(\.date) } }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(Self.key(root)).path)) ?? []
        return files.compactMap { Self.date(fromFileName: $0) }.sorted(by: >)
    }

    public func snapshot(for root: String, at date: Date) -> SizeSnapshot? {
        guard let folder else { return memory.withLock { $0[root]?.first { $0.date == date } } }
        guard let url = file(for: root, at: date), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SizeSnapshot.self, from: data)
    }

    public func latest(for root: String) -> SizeSnapshot? { latestReadable(for: root)?.snapshot }

    /// The newest snapshot of `root` that can be read, and the dates of every readable one (newest first).
    /// A file that can't be read (damaged, or from a newer Sweep) is skipped and removed.
    public func latestReadable(for root: String) -> (snapshot: SizeSnapshot, dates: [Date])? {
        var readable: [Date] = []
        var newest: SizeSnapshot?
        for date in dates(for: root) {
            if let snapshot = snapshot(for: root, at: date) {
                readable.append(date)
                if newest == nil { newest = snapshot }
            } else if let url = file(for: root, at: date) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return newest.map { ($0, readable) }
    }

    /// Saves `snapshot` and forgets the oldest ones beyond `keep`.
    public func save(_ snapshot: SizeSnapshot) {
        guard let folder else {
            memory.withLock { store in
                store[snapshot.root] = Array(([snapshot] + (store[snapshot.root] ?? [])).prefix(keep))
            }
            return
        }
        let directory = folder.appendingPathComponent(Self.key(snapshot.root))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.fileName(snapshot.date)), options: .atomic)
        for old in dates(for: snapshot.root).dropFirst(keep) {
            if let url = file(for: snapshot.root, at: old) { try? FileManager.default.removeItem(at: url) }
        }
        forgetFolders(notScannedSince: snapshot.date.addingTimeInterval(-Self.forgetAfter), keeping: Self.key(snapshot.root))
    }

    /// History of a folder not scanned for this long is removed.
    static let forgetAfter: TimeInterval = 180 * 86_400

    /// Removes the history of folders whose newest snapshot is older than `cutoff`.
    func forgetFolders(notScannedSince cutoff: Date, keeping current: String) {
        guard let folder, let keys = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for key in keys where key != current && !key.hasPrefix(".") {
            let directory = folder.appendingPathComponent(key)
            let newest = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .compactMap(Self.date(fromFileName:)).max()
            if (newest ?? .distantPast) < cutoff { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// One folder per scanned path, named by a hash so any path works as a folder name.
    static func key(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Milliseconds, so two scans in the same second don't overwrite each other.
    static func fileName(_ date: Date) -> String { "snapshot-\(Int64((date.timeIntervalSince1970 * 1000).rounded())).json" }

    static func date(fromFileName name: String) -> Date? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(5)
        if stem.hasPrefix("snapshot-"), let milliseconds = TimeInterval(stem.dropFirst(9)) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        // Early builds named files "<seconds>.json".
        return TimeInterval(stem).map { Date(timeIntervalSince1970: $0) }
    }

    /// The file a snapshot taken at `date` is stored in: today's name, or an early build's if that's what exists.
    func file(for root: String, at date: Date) -> URL? {
        guard let folder else { return nil }
        let directory = folder.appendingPathComponent(Self.key(root))
        let current = directory.appendingPathComponent(Self.fileName(date))
        let legacy = directory.appendingPathComponent("\(Int(date.timeIntervalSince1970)).json")
        return FileManager.default.fileExists(atPath: current.path) || !FileManager.default.fileExists(atPath: legacy.path) ? current : legacy
    }
}
