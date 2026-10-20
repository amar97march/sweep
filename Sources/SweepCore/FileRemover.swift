import Darwin
import Foundation

public enum RemovalMode: String, Sendable, Codable {
    /// Move to the Trash of the item's volume. Undoable from Finder until the Trash is emptied.
    case moveToTrash
    /// Delete immediately. Cannot be undone.
    case deletePermanently
}

public struct RemovalRequest: Sendable, Hashable {
    public let path: String
    /// Size shown to the user when they chose the item; recorded in the log.
    public let bytes: UInt64

    public init(path: String, bytes: UInt64) {
        self.path = path
        self.bytes = bytes
    }
}

public struct RemovalRecord: Sendable, Codable, Identifiable, Equatable {
    public enum Outcome: Sendable, Codable, Equatable {
        case trashed(location: String)
        case deleted
        /// Refused before touching the file (protected, locked, missing…).
        case skipped(reason: String)
        /// The file system refused the operation.
        case failed(reason: String)
    }

    public var id = UUID()
    public let date: Date
    public let path: String
    public let bytes: UInt64
    public let mode: RemovalMode
    public let outcome: Outcome

    public init(date: Date, path: String, bytes: UInt64, mode: RemovalMode, outcome: Outcome) {
        self.date = date
        self.path = path
        self.bytes = bytes
        self.mode = mode
        self.outcome = outcome
    }

    public var succeeded: Bool {
        switch outcome {
        case .trashed, .deleted: true
        case .skipped, .failed: false
        }
    }
}

/// Rules that keep a removal from damaging the system or the user's account.
public struct RemovalPolicy: Sendable {
    /// Folders that may be emptied but never removed themselves.
    public var protectedPaths: Set<String>
    /// Nothing below these prefixes may be removed.
    public var protectedPrefixes: [String]
    /// Volume roots are never removable.
    public var mountPoints: Set<String>
    /// When set, only paths inside these folders may be removed (used to confine tests to their sandbox).
    public var allowedRoots: [String]?

    public static var standard: RemovalPolicy {
        let home = NSHomeDirectory()
        var paths: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Users/Shared", "/Volumes", "/bin",
            "/sbin", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/etc", "/var", "/tmp", "/cores", "/dev",
            "/private", "/private/etc", "/private/var", "/private/tmp",
            home,
        ]
        for folder in ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public",
                       "Applications", "Library/Mobile Documents", "Library/CloudStorage"] {
            paths.insert(home + "/" + folder)
        }
        return RemovalPolicy(
            protectedPaths: paths,
            protectedPrefixes: [
                "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/lib/", "/usr/libexec/", "/usr/sbin/",
                "/usr/share/", "/usr/standalone/", "/private/var/db/", "/dev/", "/Library/Apple/",
            ],
            mountPoints: MountTable.mountPoints(),
            allowedRoots: nil
        )
    }

    /// The standard rules, plus: nothing outside `roots` may be touched.
    public static func confined(to roots: [String]) -> RemovalPolicy {
        var policy = standard
        policy.allowedRoots = roots
        return policy
    }

    /// Why `path` must not be removed, or `nil` if it may be.
    public func refusal(for path: String) -> String? {
        // Absolute, with no ".", ".." or empty components. (NSString.standardizingPath can't be used for
        // this: it also rewrites /private/var to /var.)
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"),
              path == "/" || !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return "Not a plain absolute path"
        }
        if let allowedRoots, !allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) {
            return "Outside the folders this remover may change"
        }
        if protectedPaths.contains(path) || mountPoints.contains(path) {
            return "Required folder; remove its contents instead"
        }
        if protectedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return "Part of macOS"
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? "No longer exists" : String(cString: strerror(errno))
        }
        if info.st_flags & UInt32(SF_RESTRICTED) != 0 || hasRootlessAttribute(path) {
            return "Protected by macOS"
        }
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 {
            return "Locked (unlock it in Finder → Get Info)"
        }
        return nil
    }

    private func hasRootlessAttribute(_ path: String) -> Bool {
        getxattr(path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}

/// Removes files and folders after checking them against a `RemovalPolicy`, and records every attempt.
public final class FileRemover: Sendable {
    public typealias Trash = @Sendable (URL) throws -> URL?

    public let policy: RemovalPolicy
    public let logURL: URL?
    let trash: Trash

    /// Moves an item to the Trash of its volume, as Finder does.
    public static let systemTrash: Trash = { url in
        var location: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &location)
        return location as URL?
    }

    public init(policy: RemovalPolicy = .standard, logURL: URL? = RemovalLog.defaultURL, trash: @escaping Trash = FileRemover.systemTrash) {
        self.policy = policy
        self.logURL = logURL
        self.trash = trash
    }

    /// A remover that can only touch files inside `root`, keeps its "Trash" in `root/.Trash`, and logs nothing.
    /// For tests.
    public static func sandboxed(in root: String) -> FileRemover {
        FileRemover(policy: .confined(to: [root]), logURL: nil) { url in
            let trash = URL(fileURLWithPath: root).appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    /// Removes each request in order. Blocking; call from a background thread.
    /// - Parameter progress: Called after each item with (finished, total).
    public func remove(
        _ requests: [RemovalRequest],
        mode: RemovalMode,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [RemovalRecord] {
        var records: [RemovalRecord] = []
        for (index, request) in requests.enumerated() {
            records.append(remove(request, mode: mode))
            progress?(index + 1, requests.count)
        }
        if let logURL { try? RemovalLog.append(records, to: logURL) }
        return records
    }

    private func remove(_ request: RemovalRequest, mode: RemovalMode) -> RemovalRecord {
        func record(_ outcome: RemovalRecord.Outcome) -> RemovalRecord {
            RemovalRecord(date: Date(), path: request.path, bytes: request.bytes, mode: mode, outcome: outcome)
        }
        if let reason = policy.refusal(for: request.path) { return record(.skipped(reason: reason)) }

        let url = URL(fileURLWithPath: request.path)
        do {
            switch mode {
            case .moveToTrash:
                let location = try trash(url)
                return record(.trashed(location: location?.path ?? ""))
            case .deletePermanently:
                try FileManager.default.removeItem(at: url)
                return record(.deleted)
            }
        } catch {
            return record(.failed(reason: Self.describe(error)))
        }
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            switch Int32(underlying.code) {
            case EACCES, EPERM: return "Permission denied"
            case EBUSY: return "In use"
            default: return String(cString: strerror(Int32(underlying.code)))
            }
        }
        if error.code == NSFileWriteNoPermissionError { return "Permission denied" }
        return error.localizedDescription
    }
}

/// Append-only history of removals, one JSON object per line.
public enum RemovalLog {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sweep/removals.jsonl")
    }

    public static func append(_ records: [RemovalRecord], to url: URL) throws {
        guard !records.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func read(from url: URL) throws -> [RemovalRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(RemovalRecord.self, from: Data($0.utf8)) }
    }
}
