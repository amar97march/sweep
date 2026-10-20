import CoreServices
import Foundation
import SweepCore

/// Where the scanners look. Tests point `home` and `systemRoot` at fixture folders.
public struct ScanEnvironment: Sendable {
    /// The user's home folder.
    public var home: String
    /// Prefix for system paths: "" on a real Mac, a fixture folder in tests.
    public var systemRoot: String
    /// Bundle identifiers of apps that are running now.
    public var runningBundleIDs: Set<String>
    /// Language codes the user keeps (from System Settings → Language & Region).
    public var preferredLanguages: [String]
    public var userID: uid_t
    public var now: Date
    /// Folders searched for installed apps.
    public var applicationFolders: [String]
    /// Environment variables tools read their settings from (OLLAMA_MODELS, HF_HOME…).
    public var variables: [String: String]

    public init(home: String, systemRoot: String = "", runningBundleIDs: Set<String> = [],
                preferredLanguages: [String] = ["en"], userID: uid_t = getuid(), now: Date = Date(),
                applicationFolders: [String]? = nil, variables: [String: String] = [:]) {
        self.home = home
        self.variables = variables
        self.systemRoot = systemRoot
        self.runningBundleIDs = runningBundleIDs
        self.preferredLanguages = preferredLanguages
        self.userID = userID
        self.now = now
        self.applicationFolders = applicationFolders
            ?? [systemRoot + "/Applications", home + "/Applications"]
    }

    /// The real Mac this process runs on.
    public static func live(runningBundleIDs: Set<String> = []) -> ScanEnvironment {
        ScanEnvironment(home: NSHomeDirectory(), runningBundleIDs: runningBundleIDs,
                        preferredLanguages: Locale.preferredLanguages, variables: ProcessInfo.processInfo.environment)
    }

    public func system(_ path: String) -> String { systemRoot + path }
    public func user(_ relative: String) -> String { home + "/" + relative }
}

/// An installed application bundle.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public let path: String
    public let bundleID: String
    public let name: String
    public let version: String?
    public let shortVersion: String?
    public let executable: String?
    public let isAppStore: Bool
    public let lastUsed: Date?
    public let info: [String: String]

    public var id: String { path }

    /// Reads `Contents/Info.plist`. Returns nil for folders that aren't app bundles.
    public init?(path: String) {
        let infoURL = URL(fileURLWithPath: path + "/Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { return nil }
        self.path = path
        self.bundleID = bundleID
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fileName
        version = plist["CFBundleVersion"] as? String
        shortVersion = plist["CFBundleShortVersionString"] as? String
        executable = plist["CFBundleExecutable"] as? String
        isAppStore = FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
        lastUsed = Self.lastUsedDate(path)
        var strings: [String: String] = [:]
        for (key, value) in plist { if let value = value as? String { strings[key] = value } }
        info = strings
    }

    private static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

public enum AppCatalog {
    /// Apps in the environment's application folders, including one level of subfolders
    /// (`/Applications/Utilities`, vendor folders). Does not look inside app bundles.
    public static func installed(in environment: ScanEnvironment) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        func visit(_ folder: String, depth: Int) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    if let app = InstalledApp(path: path), seen.insert(app.path).inserted { apps.append(app) }
                } else if depth < 2, isDirectory(path) {
                    visit(path, depth: depth + 1)
                }
            }
        }
        for folder in environment.applicationFolders { visit(folder, depth: 0) }
        return apps
    }

    /// Bundle identifier → display name, for labelling caches and logs.
    public static func names(_ apps: [InstalledApp]) -> [String: String] {
        var names: [String: String] = [:]
        for app in apps { names[app.bundleID.lowercased()] = app.name }
        return names
    }

    /// Bundle identifier → app path, for showing app icons.
    public static func paths(_ apps: [InstalledApp]) -> [String: String] {
        var paths: [String: String] = [:]
        for app in apps { paths[app.bundleID.lowercased()] = app.path }
        return paths
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Measures folders with the parallel scanner.
public enum Measure {
    /// Full tree under `path`, or nil if it can't be read.
    public static func tree(_ path: String, threads: Int = 8) -> DirectoryNode? {
        var options = ScanOptions()
        options.threadCount = threads
        options.skipPromptingPaths = false
        return try? DiskTreeScanner(options: options).scan(path).root
    }

    /// Allocated bytes of a file or folder (folders measured recursively).
    public static func size(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        if info.st_mode & S_IFMT == S_IFDIR { return tree(path, threads: 4)?.allocatedSize ?? 0 }
        return UInt64(info.st_blocks) * 512
    }

    /// Bytes on disk of one file, without following symlinks (sparse files count only what they use).
    public static func allocated(_ path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return UInt64(info.st_blocks) * 512
    }

    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

extension DirectoryNode {
    /// Entries directly inside this folder with their sizes: (name, path, bytes, isDirectory).
    var entries: [(name: String, path: String, bytes: UInt64, isDirectory: Bool)] {
        let prefix = path == "/" ? "" : path
        return children.map { ($0.name, $0.path, $0.allocatedSize, true) }
            + files.map { ($0.name, prefix + "/" + $0.name, $0.allocatedSize, false) }
    }
}
