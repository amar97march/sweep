import Foundation
import SweepCore

/// Large files in iCloud Drive and File Provider folders (Google Drive, OneDrive, Dropbox, Box…).
///
/// Only files the user can see in iCloud Drive (its own folder, and apps' "Documents" folders) are offered
/// for removal. Data apps keep privately in iCloud, like chat backups, is listed per app for information:
/// removing it file by file would leave the app with a broken backup.
public struct CloudScanner: Sendable {
    public struct Options: Sendable {
        /// Files at least this big are listed.
        public var largeFileSize: UInt64 = 50 * 1024 * 1024
        /// Downloaded files not opened for this long are preselected for removing the local copy.
        public var staleAge: TimeInterval = 30 * 86_400
        public init() {}
    }

    public struct Provider: Sendable, Hashable {
        public let name: String
        public let root: String
    }

    public let environment: ScanEnvironment
    public let options: Options

    public init(environment: ScanEnvironment, options: Options = Options()) {
        self.environment = environment
        self.options = options
    }

    /// iCloud Drive plus every File Provider domain in ~/Library/CloudStorage.
    public func providers() -> [Provider] {
        var providers: [Provider] = []
        let iCloud = environment.user("Library/Mobile Documents")
        if FileManager.default.fileExists(atPath: iCloud) { providers.append(Provider(name: "iCloud Drive", root: iCloud)) }
        let storage = environment.user("Library/CloudStorage")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: storage)) ?? []).sorted() where !name.hasPrefix(".") {
            providers.append(Provider(name: Self.displayName(name), root: storage + "/" + name))
        }
        return providers
    }

    static func displayName(_ folder: String) -> String {
        // "GoogleDrive-me@example.com" → "Google Drive (me@example.com)"
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let service = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box",
                       "iCloudDrive": "iCloud Drive"][parts[0]] ?? parts[0]
        return parts.count > 1 ? "\(service) (\(parts[1]))" : service
    }

    public func scan(progress: (String) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [ScanCategory] {
        // Walking a cloud folder must never download its placeholders.
        DatalessFiles.disableMaterializationForCurrentThread()
        var local: [ScanGroup] = [], remote: [ScanGroup] = []
        var appData: [String: (bytes: UInt64, files: Int, changed: Date?)] = [:]
        let cutoff = environment.now.addingTimeInterval(-options.staleAge)
        let iCloud = environment.user("Library/Mobile Documents")
        for provider in providers() {
            if isCancelled() { break }
            progress("Looking in \(provider.name)")
            var downloaded: [ScanItem] = [], cloudOnly: [ScanItem] = []
            for file in Self.files(under: provider.root) {
                if provider.root == iCloud, let container = Self.privateContainer(of: file.path, iCloudRoot: iCloud) {
                    let entry = appData[container] ?? (0, 0, nil)
                    appData[container] = (entry.bytes + file.logical, entry.files + 1,
                                          [entry.changed, file.accessed].compactMap { $0 }.max())
                    continue
                }
                guard file.logical >= options.largeFileSize else { continue }
                let name = (file.path as NSString).lastPathComponent
                let folder = provider.root == iCloud ? Self.iCloudDriveFolder(of: file.path, iCloudRoot: iCloud)
                    : (file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: provider.root, with: provider.name)
                if file.dataless {
                    cloudOnly.append(ScanItem(id: "cloud:" + file.path, title: name, subtitle: "In the cloud only · \(folder)",
                                              size: file.logical, date: file.accessed, isSelectedByDefault: false,
                                              action: .remove(paths: [file.path], mode: .moveToTrash)))
                } else if !file.pinned {
                    let stale = (file.accessed ?? .distantPast) < cutoff
                    downloaded.append(ScanItem(id: "evict:" + file.path, title: name,
                                               subtitle: (stale ? "Not opened recently · " : "") + folder,
                                               size: file.allocated, date: file.accessed, isSelectedByDefault: stale,
                                               action: .custom(kind: "evict", payload: [file.path])))
                }
            }
            if !downloaded.isEmpty {
                local.append(ScanGroup(id: "local:" + provider.root, title: provider.name, subtitle: "Downloaded to this Mac",
                                       icon: .symbol("icloud.and.arrow.down.fill"), items: downloaded.sorted { $0.size > $1.size }))
            }
            if !cloudOnly.isEmpty {
                remote.append(ScanGroup(id: "remote:" + provider.root, title: provider.name, subtitle: "Stored in the cloud",
                                        icon: .symbol("icloud.fill"), items: cloudOnly.sorted { $0.size > $1.size }))
            }
        }
        var categories: [ScanCategory] = []
        if !local.isEmpty {
            categories.append(ScanCategory(id: "localCopies", title: "Large Downloaded Files",
                                           summary: "Remove the local copy to free space. The file stays in the cloud and downloads again when you open it.",
                                           symbol: "icloud.and.arrow.down.fill", groups: local))
        }
        if !remote.isEmpty {
            categories.append(ScanCategory(id: "cloudFiles", title: "Large Cloud Files",
                                           summary: "Big files taking up your cloud storage. Removing them deletes them from the cloud.",
                                           symbol: "externaldrive.fill.badge.icloud", groups: remote))
        }
        let apps = appData.filter { $0.value.bytes >= options.largeFileSize }.sorted { $0.value.bytes > $1.value.bytes }
        if !apps.isEmpty {
            let installed = AppCatalog.installed(in: environment)
            let items = apps.map { container, data in
                ScanItem(id: "icloud-app:" + container, title: Self.appName(container: container, installed: installed),
                         subtitle: "\(data.files) \(data.files == 1 ? "file" : "files") in iCloud", size: data.bytes,
                         date: data.changed, isSelectedByDefault: false, action: .none,
                         note: "Managed by the app")
            }
            categories.append(ScanCategory(id: "iCloudAppData", title: "App Data in iCloud",
                                           summary: "Backups and data apps keep in your iCloud storage, like chat backups. Removing it file by file would break it, so manage it in the app or in System Settings → Apple Account → iCloud.",
                                           symbol: "lock.icloud.fill",
                                           groups: [ScanGroup(id: "icloud-apps", title: "Apps", subtitle: "Kept in iCloud by the apps themselves",
                                                              icon: .symbol("lock.icloud.fill"), items: items)]))
        }
        return categories
    }

    /// The app container a file in Mobile Documents belongs to, when the file is app-private data rather than
    /// something the user sees in iCloud Drive (its own folder, or an app's "Documents" folder).
    static func privateContainer(of path: String, iCloudRoot: String) -> String? {
        let parts = path.dropFirst(iCloudRoot.count + 1).split(separator: "/").map(String.init)
        guard let container = parts.first, parts.count > 1 else { return nil }
        if container == "com~apple~CloudDocs" || parts[1] == "Documents" { return nil }
        return container
    }

    /// "…/com~apple~CloudDocs/Videos/a.mov" → "iCloud Drive/Videos"; "…/com~apple~Pages/Documents/x" → "iCloud Drive/Pages".
    static func iCloudDriveFolder(of path: String, iCloudRoot: String) -> String {
        var parts = (path as NSString).deletingLastPathComponent.dropFirst(iCloudRoot.count + 1)
            .split(separator: "/").map(String.init)
        guard let container = parts.first else { return "iCloud Drive" }
        parts.removeFirst()
        if container != "com~apple~CloudDocs" {
            if parts.first == "Documents" { parts.removeFirst() }
            parts.insert(appName(container: container, installed: []), at: 0)
        }
        return (["iCloud Drive"] + parts).joined(separator: "/")
    }

    /// "57T9237FN3~net~whatsapp~WhatsApp" → "WhatsApp", or the installed app's name for that bundle identifier.
    static func appName(container: String, installed: [InstalledApp]) -> String {
        var parts = container.split(separator: "~").map(String.init)
        if parts.first == "iCloud" || parts.first?.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil {
            parts.removeFirst()
        }
        let bundleID = parts.joined(separator: ".")
        if let app = installed.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) { return app.name }
        guard let last = parts.last else { return container }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    struct CloudFile {
        let path: String
        let logical: UInt64
        let allocated: UInt64
        let dataless: Bool
        let pinned: Bool
        let accessed: Date?
    }

    static func files(under root: String) -> [CloudFile] {
        var result: [CloudFile] = []
        let reader = BulkDirectoryReader()
        var queue = [root]
        while let folder = queue.popLast() {
            reader.read(folder) { entry in
                if entry.name.hasPrefix(".") { return }
                let path = folder + "/" + entry.name
                switch entry.kind {
                case .directory: queue.append(path)
                case .file:
                    result.append(CloudFile(path: path, logical: entry.logicalSize, allocated: entry.allocatedSize,
                                            dataless: entry.isDataless, pinned: isPinned(path), accessed: accessDate(path)))
                default: break
                }
            }
        }
        return result
    }

    /// "Keep Downloaded" in Finder sets a File Provider pin attribute.
    static func isPinned(_ path: String) -> Bool {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: size)
        listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return names.contains { $0.hasPrefix("com.apple.fileprovider.pinned") }
    }

    static func accessDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(max(info.st_atimespec.tv_sec, info.st_mtimespec.tv_sec)))
    }
}

/// Removes local copies (keeping files in the cloud) and deletes cloud files.
public struct CloudPerformer: Sendable {
    public var remover = FileRemover()
    /// Removes the local copy of a cloud file.
    public var evict: @Sendable (String) -> String? = CloudPerformer.systemEvict

    public init() {}

    public static let systemEvict: @Sendable (String) -> String? = { path in
        do {
            try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
            return nil
        } catch {
            // File Provider folders (Google Drive, OneDrive…) are evicted by the system tool instead.
            let result = Shell.run("/usr/bin/fileproviderctl", ["evict", path])
            return result.status == 0 ? nil : (result.output.isEmpty ? error.localizedDescription : result.output)
        }
    }

    public func perform(_ items: [ScanItem], progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> [ActionRecord] {
        var records: [ActionRecord] = []
        for (index, item) in items.enumerated() {
            defer { progress(index + 1, items.count) }
            switch item.action {
            case .custom("evict", let payload) where payload.count == 1:
                if let error = evict(payload[0]) {
                    records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: 0, outcome: .failed(error)))
                } else {
                    records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: item.size,
                                                outcome: .done("Local copy removed")))
                }
            case .remove:
                records += CleanupPerformer.perform([item], remover: remover, allowAdministrator: false)
            default:
                continue
            }
        }
        return records
    }
}
