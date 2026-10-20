import Darwin
import Foundation

/// A value guarded by a lock.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A LIFO queue of work items shared by a fixed set of threads.
///
/// LIFO order makes the walk mostly depth-first, which keeps the queue short and the
/// directory metadata the kernel just read still warm.
final class WorkPool<Item: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [Item]
    private var active = 0
    private var stopped = false

    init(seed: [Item]) { pending = seed }

    /// Runs `worker` on `threadCount` threads and returns when all work is done or the pool is stopped.
    func run(threadCount: Int, name: String, worker: @escaping @Sendable (WorkPool<Item>) -> Void) {
        let group = DispatchGroup()
        for index in 0..<max(threadCount, 1) {
            group.enter()
            let thread = Thread {
                worker(self)
                group.leave()
            }
            thread.name = "\(name).\(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
    }

    /// Next item to process, or `nil` once nothing is queued, nothing is running, or the pool was stopped.
    func next() -> Item? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped { return nil }
            if let item = pending.popLast() {
                active += 1
                return item
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    /// Marks one item as done and queues the work it produced.
    func finish(adding items: [Item]) {
        condition.lock()
        pending.append(contentsOf: items)
        active -= 1
        if !items.isEmpty || active == 0 { condition.broadcast() }
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

public enum MountTable {
    /// Paths where a file system is mounted, for example `/`, `/System/Volumes/Data` and `/Volumes/USB`.
    public static func mountPoints() -> Set<String> {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return ["/"] }
        defer { free(mounts) }
        var result = Set<String>()
        for index in 0..<Int(count) {
            var mountedOn = mounts[index].f_mntonname
            let path = withUnsafeBytes(of: &mountedOn) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            result.insert(path)
        }
        return result
    }
}

public enum PrivacyAccess {
    /// What reading one protected location says about Full Disk Access.
    public enum Probe: Equatable, Sendable {
        case granted
        case denied
        /// Not on this Mac; try the next location.
        case missing
    }

    /// Locations only Full Disk Access can read. Several, because which exist depends on the macOS version
    /// and the Mac: macOS 27 has no per-user TCC database, and not everyone has used Mail or Safari.
    public static var probes: [String] {
        let home = NSHomeDirectory()
        return [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
            home + "/Library/Cookies",
        ]
    }

    /// Whether this process has Full Disk Access: the first protected location that exists decides.
    public static var hasFullDiskAccess: Bool { hasFullDiskAccess(probing: probes) }

    public static func hasFullDiskAccess(probing paths: [String], probe: (String) -> Probe = probe) -> Bool {
        for path in paths {
            switch probe(path) {
            case .granted: return true
            case .denied: return false
            case .missing: continue
            }
        }
        return false
    }

    /// Opens a file, or lists a folder, the way a scan would.
    public static func probe(_ path: String) -> Probe {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .denied }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard let directory = opendir(path) else { return .denied }
            defer { closedir(directory) }
            errno = 0
            // Privacy protection allows opening the folder but refuses to list it.
            return readdir(directory) != nil || errno == 0 ? .granted : .denied
        }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .denied }
        close(fd)
        return .granted
    }

    /// Folders whose contents trigger a privacy prompt (Calendars, Reminders, Contacts) instead of failing quietly.
    public static var promptingPaths: Set<String> {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Calendars",
            home + "/Library/Reminders",
            home + "/Library/Application Support/AddressBook",
        ]
    }
}

public enum DatalessFiles {
    /// Stops the calling thread from downloading iCloud / File Provider placeholders while it walks the tree.
    /// Falls back to the whole process if the system rejects the per-thread setting.
    @discardableResult
    public static func disableMaterializationForCurrentThread() -> Bool {
        if setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                          IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 {
            return true
        }
        return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                              IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
    }
}

public enum ByteFormat {
    /// Decimal units, as Finder shows them.
    public static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 KB", not "Zero KB"
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// At most three digits ("4.4 GB", "52.9 GB", "128 GB"), for badges where space is tight.
    public static func short(_ bytes: UInt64) -> String {
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (size, unit) in units where Double(bytes) >= size {
            let value = Double(bytes) / size
            let number = value >= 100 ? value.formatted(.number.precision(.fractionLength(0)))
                : value.formatted(.number.precision(.fractionLength(0...1)))
            return "\(number) \(unit)"
        }
        return "\(bytes) bytes"
    }
}

func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}
