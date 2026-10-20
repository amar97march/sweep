import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// Worker threads. Directory listing is mostly waiting on the file system, so more threads than cores helps.
    public var threadCount = min(max(ProcessInfo.processInfo.activeProcessorCount * 2, 4), 32)
    public var bufferSize = BulkDirectoryReader.defaultBufferSize
    /// Descend into other mounted volumes found below the scan root.
    public var crossMountPoints = false
    /// Directories listed but not scanned.
    public var excludedPaths: Set<String> = ["/private/var/vm"]
    /// Skip Calendars / Reminders / Contacts data when Full Disk Access is missing, to avoid privacy prompts.
    public var skipPromptingPaths = !PrivacyAccess.hasFullDiskAccess
    /// Count each hard-linked inode once, like `du`.
    public var deduplicateHardLinks = true
    /// Also measure bytes not shared with APFS clones or snapshots. Slower.
    public var measurePrivateSize = false
    /// Never download iCloud / File Provider placeholders while scanning.
    public var preventDatalessDownloads = true
    /// Replaces the system mount table (for tests).
    public var mountPointsOverride: Set<String>?

    public init() {}
}

public struct ScanStatistics: Sendable, Codable, Equatable {
    public var directories = 0
    public var files = 0
    public var symlinks = 0
    public var otherEntries = 0
    public var inaccessibleDirectories = 0
    public var partialDirectories = 0
    public var skippedMountPoints = 0
    public var skippedExcluded = 0
    public var hardLinkDuplicates = 0
    public var hardLinkDuplicateBytes: UInt64 = 0
    public var datalessFiles = 0
    public var entryErrors = 0
    public var allocatedBytes: UInt64 = 0
    public var elapsedSeconds = 0.0

    mutating func add(_ other: ScanStatistics) {
        directories += other.directories
        files += other.files
        symlinks += other.symlinks
        otherEntries += other.otherEntries
        inaccessibleDirectories += other.inaccessibleDirectories
        partialDirectories += other.partialDirectories
        skippedMountPoints += other.skippedMountPoints
        skippedExcluded += other.skippedExcluded
        hardLinkDuplicates += other.hardLinkDuplicates
        hardLinkDuplicateBytes += other.hardLinkDuplicateBytes
        datalessFiles += other.datalessFiles
        entryErrors += other.entryErrors
        allocatedBytes += other.allocatedBytes
    }
}

public struct ScanProgress: Sendable {
    public var directories = 0
    public var files = 0
    public var allocatedBytes: UInt64 = 0
    public var currentPath = ""
    public var elapsedSeconds = 0.0

    public init() {}
}

/// The finished tree. Read-only, so safe to share between threads.
public struct ScanResult: @unchecked Sendable {
    public let root: DirectoryNode
    public let statistics: ScanStatistics
}

public enum ScanError: Error, Equatable {
    case notADirectory(String)
    case unreadable(String, errno: Int32)
    case cancelled

    /// macOS privacy protection refused access; Full Disk Access would allow it.
    public var needsFullDiskAccess: Bool {
        if case .unreadable(_, let code) = self { return code == EPERM }
        return false
    }
}

extension ScanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "“\(path)” isn't a folder."
        case .unreadable(let path, let code): "Can't read “\(path)”: \(String(cString: strerror(code)))."
        case .cancelled: "The scan was stopped."
        }
    }
}

/// Builds a size tree of a directory or volume.
///
/// Every directory is listed once with `getattrlistbulk` (names, kinds and sizes in bulk, no `stat` per file).
/// A fixed pool of threads shares one LIFO queue of directories. Sizes are allocated bytes (what the files
/// use on disk), with hard links counted once.
public final class DiskTreeScanner: @unchecked Sendable {
    public let options: ScanOptions
    private let pool = Locked<WorkPool<DirectoryNode>?>(nil)
    private let cancelled = Locked(false)

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    /// Stops a running scan; `scan` then throws `ScanError.cancelled`.
    public func cancel() {
        cancelled.withLock { $0 = true }
        pool.withLock { $0?.stop() }
    }

    public var isCancelled: Bool { cancelled.withLock { $0 } }

    /// Scans `path` and blocks until done. Call from a background thread.
    /// - Parameter progress: Called from worker threads at most every `progressInterval` seconds.
    public func scan(
        _ path: String,
        progressInterval: Double = 0.1,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> ScanResult {
        guard let resolved = realpath(path, nil) else {
            throw ScanError.unreadable(path, errno: errno)
        }
        let rootPath = String(cString: resolved)
        free(resolved)

        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw ScanError.unreadable(rootPath, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ScanError.notADirectory(rootPath) }

        var mountPoints = options.mountPointsOverride ?? MountTable.mountPoints()
        mountPoints.remove(rootPath)
        var excluded = options.excludedPaths
        if options.skipPromptingPaths { excluded.formUnion(PrivacyAccess.promptingPaths) }

        let root = DirectoryNode(name: rootPath, path: rootPath, parent: nil)
        let workPool = WorkPool(seed: [root])
        pool.withLock { $0 = workPool }
        defer { pool.withLock { $0 = nil } }
        if isCancelled { throw ScanError.cancelled }

        let context = Context(
            options: options,
            mountPoints: mountPoints,
            excluded: excluded,
            start: monotonicSeconds(),
            progressInterval: progressInterval,
            progress: progress
        )
        workPool.run(threadCount: options.threadCount, name: "sweep.scan") { pool in
            if context.options.preventDatalessDownloads {
                DatalessFiles.disableMaterializationForCurrentThread()
            }
            let reader = BulkDirectoryReader(
                bufferSize: context.options.bufferSize,
                measurePrivateSize: context.options.measurePrivateSize
            )
            while let directory = pool.next() {
                let subdirectories = context.list(directory, with: reader)
                pool.finish(adding: subdirectories)
            }
        }

        if isCancelled { throw ScanError.cancelled }
        if case .inaccessible(let code) = root.status { throw ScanError.unreadable(rootPath, errno: code) }

        root.finalizeTotals()
        var statistics = context.totals.withLock { $0.statistics }
        statistics.elapsedSeconds = monotonicSeconds() - context.start
        return ScanResult(root: root, statistics: statistics)
    }
}

private struct HardLinkKey: Hashable {
    let device: Int32
    let inode: UInt64
}

private struct Totals {
    var statistics = ScanStatistics()
    var lastReport = 0.0
}

/// State shared by all workers during one scan.
private final class Context: @unchecked Sendable {
    let options: ScanOptions
    let mountPoints: Set<String>
    let excluded: Set<String>
    let start: Double
    let progressInterval: Double
    let progress: (@Sendable (ScanProgress) -> Void)?
    let totals = Locked(Totals())
    let seenHardLinks = Locked(Set<HardLinkKey>())

    init(
        options: ScanOptions, mountPoints: Set<String>, excluded: Set<String>, start: Double,
        progressInterval: Double, progress: (@Sendable (ScanProgress) -> Void)?
    ) {
        self.options = options
        self.mountPoints = mountPoints
        self.excluded = excluded
        self.start = start
        self.progressInterval = progressInterval
        self.progress = progress
    }

    /// Lists one directory, fills in its node, and returns the subdirectories to scan next.
    func list(_ directory: DirectoryNode, with reader: BulkDirectoryReader) -> [DirectoryNode] {
        var files: [FileItem] = []
        var children: [DirectoryNode] = []
        var toScan: [DirectoryNode] = []
        var counts = ScanStatistics()
        var ownAllocated: UInt64 = 0
        var ownLogical: UInt64 = 0
        let prefix = directory.path == "/" ? "" : directory.path

        let failure = reader.read(directory.path) { entry in
            if entry.error != 0 { counts.entryErrors += 1 }
            guard !entry.name.isEmpty else { return }

            if entry.kind == .directory {
                let child = DirectoryNode(name: entry.name, path: prefix + "/" + entry.name, parent: directory)
                if !options.crossMountPoints && mountPoints.contains(child.path) {
                    child.status = .skippedMountPoint
                    counts.skippedMountPoints += 1
                } else if excluded.contains(child.path) {
                    child.status = .skippedExcluded
                    counts.skippedExcluded += 1
                } else {
                    toScan.append(child)
                }
                children.append(child)
                return
            }

            var flags: FileItem.Flags = []
            var allocated = entry.allocatedSize
            var logical = entry.logicalSize
            if entry.error != 0 { flags.insert(.entryError) }
            if entry.isDataless {
                flags.insert(.dataless)
                counts.datalessFiles += 1
            }
            if options.deduplicateHardLinks, entry.kind == .file, entry.linkCount > 1 {
                let key = HardLinkKey(device: entry.deviceID, inode: entry.fileID)
                let firstSighting = seenHardLinks.withLock { $0.insert(key).inserted }
                if !firstSighting {
                    flags.insert(.hardLinkDuplicate)
                    counts.hardLinkDuplicates += 1
                    counts.hardLinkDuplicateBytes += allocated
                    allocated = 0
                    logical = 0
                }
            }
            switch entry.kind {
            case .file: counts.files += 1
            case .symlink: counts.symlinks += 1
            default: counts.otherEntries += 1
            }
            ownAllocated += allocated
            ownLogical += logical
            files.append(FileItem(
                name: entry.name, kind: entry.kind, allocatedSize: allocated, logicalSize: logical,
                privateSize: entry.privateSize, flags: flags
            ))
        }

        directory.files = files
        directory.children = children
        directory.ownAllocatedSize = ownAllocated
        directory.ownLogicalSize = ownLogical
        switch failure {
        case nil:
            directory.status = .scanned
        case .open(let code)?:
            directory.status = .inaccessible(errno: code)
            counts.inaccessibleDirectories += 1
        case .read(let code)?:
            directory.status = .partial(errno: code)
            counts.partialDirectories += 1
        }
        counts.directories = 1
        counts.allocatedBytes = ownAllocated
        report(counts, path: directory.path)
        return toScan
    }

    private func report(_ counts: ScanStatistics, path: String) {
        let now = monotonicSeconds()
        let snapshot: ScanProgress? = totals.withLock { totals in
            totals.statistics.add(counts)
            guard progress != nil, now - totals.lastReport >= progressInterval else { return nil }
            totals.lastReport = now
            var update = ScanProgress()
            update.directories = totals.statistics.directories
            update.files = totals.statistics.files + totals.statistics.symlinks + totals.statistics.otherEntries
            update.allocatedBytes = totals.statistics.allocatedBytes
            update.currentPath = path
            update.elapsedSeconds = now - start
            return update
        }
        if let snapshot { progress?(snapshot) }
    }
}
