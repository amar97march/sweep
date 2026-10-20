import Darwin

/// Kind of a directory entry, from `ATTR_CMN_OBJTYPE` (`enum vtype` in <sys/vnode.h>).
public enum EntryKind: UInt8, Sendable, Codable {
    case file, directory, symlink, other

    init(vtype: UInt32) {
        switch vtype {
        case 1: self = .file        // VREG
        case 2: self = .directory   // VDIR
        case 5: self = .symlink     // VLNK
        default: self = .other      // devices, sockets, FIFOs
        }
    }
}

/// One entry returned by `getattrlistbulk`.
public struct DirectoryEntry: Sendable {
    public var name = ""
    public var kind = EntryKind.other
    public var deviceID: Int32 = 0
    public var fileID: UInt64 = 0
    /// BSD flags (`st_flags`).
    public var flags: UInt32 = 0
    public var linkCount: UInt32 = 1
    /// Logical length in bytes. Zero for directories.
    public var logicalSize: UInt64 = 0
    /// Bytes allocated on disk. Zero for directories.
    public var allocatedSize: UInt64 = 0
    /// Bytes that would be freed if the file were deleted (not shared with clones or snapshots).
    /// Only filled in when the reader was created with `measurePrivateSize`.
    public var privateSize: UInt64?
    /// Per-entry error (`ATTR_CMN_ERROR`); the other fields may be missing when non-zero.
    public var error: Int32 = 0

    /// True for iCloud / File Provider placeholders whose contents are not on disk.
    public var isDataless: Bool { flags & Attr.datalessFlag != 0 }
}

public enum DirectoryReadError: Error, Equatable, Sendable {
    /// The directory could not be opened (for example `EACCES` or `EPERM` from privacy protection).
    case open(errno: Int32)
    /// Listing stopped part-way; entries delivered before the error are valid.
    case read(errno: Int32)
}

/// Lists directories with `getattrlistbulk`, which returns names and sizes for many entries per system call.
///
/// Not thread-safe: each thread should own its reader, because the reader reuses one buffer.
public final class BulkDirectoryReader {
    /// 256 KiB holds a few thousand entries per call; the system minimum is far smaller.
    public static let defaultBufferSize = 256 * 1024

    private let buffer: UnsafeMutableRawPointer
    private let bufferSize: Int
    private var attributes: attrlist
    private let options: UInt64

    public init(bufferSize: Int = BulkDirectoryReader.defaultBufferSize, measurePrivateSize: Bool = false) {
        precondition(bufferSize >= 1024, "getattrlistbulk needs room for at least one entry")
        self.bufferSize = bufferSize
        buffer = .allocate(byteCount: bufferSize, alignment: 8)

        var list = attrlist()
        list.bitmapcount = u_short(Attr.bitmapCount)
        list.commonattr = Attr.returnedAttrs | Attr.name | Attr.error | Attr.devID
            | Attr.objType | Attr.flags | Attr.fileID
        list.fileattr = Attr.linkCount | Attr.totalSize | Attr.allocSize
        var options: UInt64 = 0
        if measurePrivateSize {
            list.forkattr = Attr.privateSize
            options |= Attr.optionCommonExtended
        }
        attributes = list
        self.options = options
    }

    deinit { buffer.deallocate() }

    /// Lists `path` and calls `body` for every entry. Symbolic links are reported, never followed.
    /// - Returns: `nil` on success, otherwise the error that stopped the listing.
    @discardableResult
    public func read(_ path: String, _ body: (DirectoryEntry) -> Void) -> DirectoryReadError? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .open(errno: errno) }
        defer { close(fd) }

        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, bufferSize, options)
            if count == 0 { return nil }
            if count < 0 { return .read(errno: errno) }
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = record.loadUnaligned(as: UInt32.self)
                body(Self.parse(record))
                record += Int(length)
            }
        }
    }

    /// Decodes one packed record. Attributes appear in a fixed order (see getattrlist(2)), each aligned
    /// to 4 bytes, and only the ones listed in the returned-attributes set are present.
    private static func parse(_ record: UnsafeRawPointer) -> DirectoryEntry {
        var entry = DirectoryEntry()
        var cursor = record + 4  // skip the record length

        // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr
        let common = cursor.loadUnaligned(as: UInt32.self)
        let file = cursor.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let fork = cursor.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        cursor += 20

        // ATTR_CMN_ERROR, when requested, comes right after the returned-attributes set.
        if common & Attr.error != 0 {
            entry.error = cursor.loadUnaligned(as: Int32.self)
            cursor += 4
        }
        if common & Attr.name != 0 {
            // attrreference_t: offset from this field to the name, and length including the NUL.
            let offset = Int(cursor.loadUnaligned(as: Int32.self))
            let length = Int(cursor.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let bytes = UnsafeRawBufferPointer(start: cursor + offset, count: max(length - 1, 0))
            entry.name = String(decoding: bytes, as: UTF8.self)
            cursor += 8
        }
        if common & Attr.devID != 0 {
            entry.deviceID = cursor.loadUnaligned(as: Int32.self)
            cursor += 4
        }
        if common & Attr.objType != 0 {
            entry.kind = EntryKind(vtype: cursor.loadUnaligned(as: UInt32.self))
            cursor += 4
        }
        if common & Attr.flags != 0 {
            entry.flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if common & Attr.fileID != 0 {
            entry.fileID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }
        if file & Attr.linkCount != 0 {
            entry.linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        if file & Attr.totalSize != 0 {
            entry.logicalSize = UInt64(max(cursor.loadUnaligned(as: Int64.self), 0))
            cursor += 8
        }
        if file & Attr.allocSize != 0 {
            entry.allocatedSize = UInt64(max(cursor.loadUnaligned(as: Int64.self), 0))
            cursor += 8
        }
        if fork & Attr.privateSize != 0 {
            entry.privateSize = UInt64(max(cursor.loadUnaligned(as: Int64.self), 0))
        }
        return entry
    }
}

/// Constants from <sys/attr.h> and <sys/stat.h> (checked against the macOS SDK).
enum Attr {
    static let bitmapCount: UInt16 = 5                    // ATTR_BIT_MAP_COUNT
    static let name: UInt32 = 0x0000_0001                 // ATTR_CMN_NAME
    static let devID: UInt32 = 0x0000_0002                // ATTR_CMN_DEVID
    static let objType: UInt32 = 0x0000_0008              // ATTR_CMN_OBJTYPE
    static let flags: UInt32 = 0x0004_0000                // ATTR_CMN_FLAGS
    static let fileID: UInt32 = 0x0200_0000               // ATTR_CMN_FILEID
    static let error: UInt32 = 0x2000_0000                // ATTR_CMN_ERROR
    static let returnedAttrs: UInt32 = 0x8000_0000        // ATTR_CMN_RETURNED_ATTRS
    static let linkCount: UInt32 = 0x0000_0001            // ATTR_FILE_LINKCOUNT
    static let totalSize: UInt32 = 0x0000_0002            // ATTR_FILE_TOTALSIZE
    static let allocSize: UInt32 = 0x0000_0004            // ATTR_FILE_ALLOCSIZE
    static let privateSize: UInt32 = 0x0000_0008          // ATTR_CMNEXT_PRIVATESIZE (forkattr)
    static let optionCommonExtended: UInt64 = 0x0000_0020 // FSOPT_ATTR_CMN_EXTENDED
    static let datalessFlag: UInt32 = 0x4000_0000         // SF_DATALESS
}
