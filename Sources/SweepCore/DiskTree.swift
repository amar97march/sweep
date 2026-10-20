/// A non-directory entry inside a scanned directory.
public struct FileItem: Sendable, Hashable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Another path to the same inode was already counted, so this one counts as zero bytes.
        public static let hardLinkDuplicate = Flags(rawValue: 1 << 0)
        /// iCloud / File Provider placeholder: listed, but its contents are not on this Mac.
        public static let dataless = Flags(rawValue: 1 << 1)
        /// The file system reported an error for this entry.
        public static let entryError = Flags(rawValue: 1 << 2)
    }

    public let name: String
    public let kind: EntryKind
    /// Bytes on disk counted for this entry (zero for hard-link duplicates).
    public let allocatedSize: UInt64
    public let logicalSize: UInt64
    /// Bytes freed by deleting the file; `nil` unless the scan measured it.
    public let privateSize: UInt64?
    public let flags: Flags
}

public enum DirectoryStatus: Sendable, Equatable {
    case pending
    case scanned
    /// Listing stopped part-way through.
    case partial(errno: Int32)
    /// Could not be opened, usually because of permissions or privacy protection.
    case inaccessible(errno: Int32)
    /// Another volume is mounted here; not scanned.
    case skippedMountPoint
    /// Excluded by the scan options.
    case skippedExcluded

    public var wasSkipped: Bool { self == .skippedMountPoint || self == .skippedExcluded }
}

/// A directory in the scanned tree.
///
/// Thread-safety: a node is filled in by exactly one scanner worker, then handed to other threads only
/// through the work pool's lock, and totals are computed after every worker has finished. After `scan`
/// returns the tree is read-only, so it can be shared freely.
public final class DirectoryNode: @unchecked Sendable, Identifiable {
    public let name: String
    public let path: String
    public private(set) unowned(safe) var parent: DirectoryNode?

    public internal(set) var status: DirectoryStatus = .pending
    /// Files, symlinks and other entries, largest first.
    public internal(set) var files: [FileItem] = []
    /// Subdirectories, largest first.
    public internal(set) var children: [DirectoryNode] = []

    /// Bytes on disk of the files directly in this directory.
    public internal(set) var ownAllocatedSize: UInt64 = 0
    public internal(set) var ownLogicalSize: UInt64 = 0
    /// Bytes on disk of everything below this directory.
    public internal(set) var allocatedSize: UInt64 = 0
    public internal(set) var logicalSize: UInt64 = 0
    /// Non-directory entries below this directory.
    public internal(set) var fileCount = 0
    /// Directories below this directory, not counting itself.
    public internal(set) var directoryCount = 0

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, path: String, parent: DirectoryNode?) {
        self.name = name
        self.path = path
        self.parent = parent
    }

    /// Directories from the root down to this one.
    public var ancestry: [DirectoryNode] {
        var chain: [DirectoryNode] = []
        var node: DirectoryNode? = self
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }

    /// Removes a subfolder or file from the tree after it was removed from disk, and subtracts its size and
    /// counts from every ancestor. Call only from the thread that owns the finished tree (the main thread
    /// in the app).
    /// - Returns: `false` if this folder has no entry with that name.
    @discardableResult
    public func removeEntry(named name: String) -> Bool {
        var allocated: UInt64 = 0, logical: UInt64 = 0, files = 0, directories = 0
        if let index = children.firstIndex(where: { $0.name == name }) {
            let child = children.remove(at: index)
            allocated = child.allocatedSize
            logical = child.logicalSize
            files = child.fileCount
            directories = child.directoryCount + 1
        } else if let index = self.files.firstIndex(where: { $0.name == name }) {
            let file = self.files.remove(at: index)
            allocated = file.allocatedSize
            logical = file.logicalSize
            files = 1
            ownAllocatedSize -= min(ownAllocatedSize, allocated)
            ownLogicalSize -= min(ownLogicalSize, logical)
        } else {
            return false
        }
        var node: DirectoryNode? = self
        while let current = node {
            current.allocatedSize -= min(current.allocatedSize, allocated)
            current.logicalSize -= min(current.logicalSize, logical)
            current.fileCount -= min(current.fileCount, files)
            current.directoryCount -= min(current.directoryCount, directories)
            node = current.parent
        }
        return true
    }

    /// Computes totals bottom-up and sorts children and files by size. Iterative, so deep trees
    /// cannot overflow the stack.
    func finalizeTotals() {
        var stack: [(DirectoryNode, Bool)] = [(self, false)]
        while let (node, childrenDone) = stack.popLast() {
            if !childrenDone {
                stack.append((node, true))
                for child in node.children { stack.append((child, false)) }
                continue
            }
            var allocated = node.ownAllocatedSize
            var logical = node.ownLogicalSize
            var files = node.files.count
            var directories = node.children.count
            for child in node.children {
                allocated += child.allocatedSize
                logical += child.logicalSize
                files += child.fileCount
                directories += child.directoryCount
            }
            node.allocatedSize = allocated
            node.logicalSize = logical
            node.fileCount = files
            node.directoryCount = directories
            node.children.sort { $0.allocatedSize > $1.allocatedSize }
            node.files.sort { $0.allocatedSize > $1.allocatedSize }
        }
    }
}
