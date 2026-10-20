import CoreServices
import Foundation
import SQLite3
import SweepCore

/// Finds junk: caches, logs, broken preferences and launch agents, old iOS backups, developer junk,
/// Trash contents and downloadable Mail attachments.
public struct CleanupScanner: Sendable {
    public let environment: ScanEnvironment
    /// How cleaned items are removed. Junk is deleted outright unless the user prefers the Trash.
    public let mode: RemovalMode

    public init(environment: ScanEnvironment, mode: RemovalMode = .deletePermanently) {
        self.environment = environment
        self.mode = mode
    }

    /// Runs every scanner. `progress` gets a short description of the step being run.
    public func scan(progress: (String) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [ScanCategory] {
        let apps = AppCatalog.installed(in: environment)
        let names = AppCatalog.names(apps)
        let appPaths = AppCatalog.paths(apps)
        let steps: [(String, () -> ScanCategory?)] = [
            ("Looking for user caches", { userCaches(names: names, appPaths: appPaths) }),
            ("Looking for system caches", { systemCaches(names: names, appPaths: appPaths) }),
            ("Looking for logs", { logs(names: names) }),
            ("Checking preferences", { brokenPreferences() }),
            ("Checking launch agents", { brokenLaunchAgents(apps: apps) }),
            ("Looking for iOS device files", { deviceBackups() }),
            ("Looking for developer junk", { developerJunk() }),
            ("Looking for deleted users", { deletedUsers() }),
            ("Checking Trash bins", { trashBins() }),
            ("Looking for Mail attachments", { mailAttachments() }),
        ]
        var categories: [ScanCategory] = []
        for (message, step) in steps {
            if isCancelled() { break }
            progress(message)
            if let category = step(), !category.groups.isEmpty { categories.append(category) }
        }
        return categories
    }

    // MARK: Caches

    func userCaches(names: [String: String], appPaths: [String: String] = [:]) -> ScanCategory? {
        var groups: [ScanGroup] = []
        groups += cacheGroups(in: environment.user("Library/Caches"), names: names, appPaths: appPaths)
        for container in subfolders(environment.user("Library/Containers")) {
            groups += cacheGroups(in: container + "/Data/Library/Caches", names: names, appPaths: appPaths,
                                  owner: (container as NSString).lastPathComponent)
        }
        groups += developerToolCaches()
        return category("userCaches", "User Cache Files", symbol: "archivebox.fill",
                        summary: "Apps rebuild these files when needed. Removing them frees space and can fix glitches.",
                        groups: merge(groups))
    }

    func systemCaches(names: [String: String], appPaths: [String: String] = [:]) -> ScanCategory? {
        let groups = cacheGroups(in: environment.system("/Library/Caches"), names: names, appPaths: appPaths,
                                 skipApple: true)
        return category("systemCaches", "System Cache Files", symbol: "externaldrive.fill",
                        summary: "Caches shared by all users. Some need your administrator password to remove.",
                        groups: groups)
    }

    /// One group per cache folder owner; deep-search folders list their children as separate items.
    private func cacheGroups(in folder: String, names: [String: String], appPaths: [String: String],
                             owner: String? = nil, skipApple: Bool = false) -> [ScanGroup] {
        // An app controls its own container, so it could swap its Caches folder for a link to ~/Documents.
        // Sweep only looks at cache folders reached without going through a link.
        guard CleanupPerformer.isPlainPath(folder), let tree = Measure.tree(folder) else { return [] }
        var groups: [ScanGroup] = []
        for entry in tree.entries where entry.bytes > 0 {
            let key = (owner ?? entry.name)
            if Exclusions.isExcludedCache(entry.name, owner: owner) { continue }
            // Listed once, under developer tool caches, where they aren't preselected.
            if owner == nil, Exclusions.developerToolCaches.contains(entry.name) { continue }
            if skipApple, key.hasPrefix("com.apple.") { continue }
            let label = names[key.lowercased()] ?? displayName(forCacheFolder: key)
            let running = environment.runningBundleIDs.contains(key)
            let note: String? = nil
            var items: [ScanItem] = []
            if entry.isDirectory, Exclusions.deepSearchCaches.contains(entry.name),
               let node = tree.children.first(where: { $0.name == entry.name }) {
                for child in node.entries where child.bytes > 0 {
                    items.append(removable(child.path, title: child.name, bytes: child.bytes, selected: !running,
                                           subtitle: running ? "In use by \(label)" : child.path, note: note))
                }
            } else {
                items.append(removable(entry.path, title: entry.name, bytes: entry.bytes, selected: !running,
                                       subtitle: running ? "\(label) is open — quit it first for best results" : entry.path,
                                       note: note))
            }
            let icon: ItemIcon = appPaths[key.lowercased()].map { .file($0) } ?? .file(entry.path)
            groups.append(ScanGroup(id: "cache:" + entry.path, title: label,
                                    subtitle: owner == nil ? nil : "Sandboxed app",
                                    icon: icon, items: items))
        }
        return groups
    }

    /// Package-manager and toolchain caches in the home folder that are safe to rebuild.
    private func developerToolCaches() -> [ScanGroup] {
        let candidates: [(String, String)] = [
            (".npm/_cacache", "npm"), (".gradle/caches", "Gradle"), (".cache/pip", "pip"),
            ("Library/Caches/Yarn", "Yarn"), (".cache/yarn", "Yarn"), (".cargo/registry/cache", "Cargo"),
            ("go/pkg/mod/cache/download", "Go modules"), (".cocoapods/repos", "CocoaPods"),
            ("Library/Caches/CocoaPods", "CocoaPods"),
        ]
        return candidates.compactMap { relative, title in
            let path = environment.user(relative)
            guard Measure.exists(path) else { return nil }
            let bytes = Measure.size(path)
            guard bytes > 0 else { return nil }
            // Developer caches are big but slow to rebuild, so they aren't preselected.
            return ScanGroup(id: "devcache:" + path, title: title, subtitle: "Developer tool cache",
                             icon: .symbol("hammer.fill"),
                             items: [removable(path, title: relative, bytes: bytes, selected: false, subtitle: path)])
        }
    }

    // MARK: Logs

    func logs(names: [String: String]) -> ScanCategory? {
        var groups: [ScanGroup] = []
        for (folder, label) in [(environment.user("Library/Logs"), "User Logs"),
                                (environment.system("/Library/Logs"), "System Logs")] {
            guard let tree = Measure.tree(folder) else { continue }
            var items: [ScanItem] = []
            for entry in tree.entries where entry.bytes > 10_240 && entry.name != ".DS_Store" {
                if Exclusions.excludedLogs.contains(entry.name) { continue }
                let title = names[entry.name.lowercased()] ?? entry.name
                items.append(removable(entry.path, title: title, bytes: entry.bytes, selected: true,
                                       subtitle: entry.path, date: Measure.modificationDate(entry.path)))
            }
            if !items.isEmpty {
                groups.append(ScanGroup(id: "logs:" + folder, title: label, subtitle: folder,
                                        icon: .symbol("doc.text.fill"), items: items))
            }
        }
        // Rotated system logs: compressed old copies are never needed.
        let varLog = environment.system("/private/var/log")
        let rotated = (try? FileManager.default.contentsOfDirectory(atPath: varLog))?
            .filter { $0.range(of: #"\.\d+\.(gz|bz2)$"#, options: .regularExpression) != nil } ?? []
        let rotatedItems = rotated.compactMap { name -> ScanItem? in
            let path = varLog + "/" + name
            let bytes = Measure.size(path)
            return bytes > 0 ? removable(path, title: name, bytes: bytes, selected: true, subtitle: path) : nil
        }
        if !rotatedItems.isEmpty {
            groups.append(ScanGroup(id: "logs:rotated", title: "Old System Logs", subtitle: varLog,
                                    icon: .symbol("doc.zipper"), items: rotatedItems))
        }
        return category("logs", "Log Files", symbol: "doc.text.magnifyingglass",
                        summary: "Activity records apps and macOS keep. Useful only when troubleshooting.",
                        groups: groups)
    }

    // MARK: Broken items

    func brokenPreferences() -> ScanCategory? {
        let folder = environment.user("Library/Preferences")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let items = names.sorted().compactMap { name -> ScanItem? in
            guard name.hasSuffix(".plist"), !name.hasPrefix("."), !name.contains(".lockfile") else { return nil }
            let path = folder + "/" + name
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty,
                  (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil else { return nil }
            return removable(path, title: name, bytes: Measure.size(path), selected: true,
                             subtitle: "Can't be read — the app will recreate it")
        }
        guard !items.isEmpty else { return nil }
        return category("brokenPreferences", "Broken Preferences", symbol: "exclamationmark.triangle.fill",
                        summary: "Settings files that are damaged and can't be read by their apps.",
                        groups: [ScanGroup(id: "prefs", title: "Damaged preference files", icon: .symbol("gearshape.fill"),
                                           items: items)])
    }

    func brokenLaunchAgents(apps: [InstalledApp]) -> ScanCategory? {
        let folder = environment.user("Library/LaunchAgents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let items = names.sorted().compactMap { name -> ScanItem? in
            guard name.hasSuffix(".plist") else { return nil }
            let path = folder + "/" + name
            guard let program = LaunchItem.program(ofPlistAt: path, home: environment.home) else { return nil }
            // Only a program at a full path Sweep can check counts as missing. A bare command ("sh", "python3")
            // is looked up on launchd's PATH, and a program on an external drive may just be unplugged.
            guard program.hasPrefix("/"), !program.hasPrefix("/Volumes/") else { return nil }
            if Measure.exists(environment.systemRoot + program) || Measure.exists(program) { return nil }
            return removable(path, title: name, bytes: Measure.size(path), selected: true,
                             subtitle: "Starts \(program), which no longer exists")
        }
        guard !items.isEmpty else { return nil }
        return category("brokenLaunchAgents", "Broken Login Items", symbol: "bolt.horizontal.circle.fill",
                        summary: "Background tasks that try to start programs that have been deleted.",
                        groups: [ScanGroup(id: "agents", title: "Launch agents", icon: .symbol("bolt.fill"),
                                           items: items)])
    }

    // MARK: Devices and developer junk

    func deviceBackups() -> ScanCategory? {
        let folder = environment.user("Library/Application Support/MobileSync/Backup")
        struct Backup {
            let path: String
            let name: String
            /// The device's UDID, from the backup itself. Names aren't unique: two iPads can both be "iPad".
            let device: String?
            let date: Date
            let bytes: UInt64
            /// Finder's "Archive" keeps a copy in a folder named after the device plus a date; the user asked for it.
            var isArchived: Bool { device.map { (path as NSString).lastPathComponent.caseInsensitiveCompare($0) != .orderedSame } ?? false }
        }
        let backups = subfolders(folder).map { path -> Backup in
            let info = NSDictionary(contentsOfFile: path + "/Info.plist")
            let name = (info?["Device Name"] as? String) ?? "Unknown device"
            let device = (info?["Unique Identifier"] as? String) ?? (info?["Target Identifier"] as? String)
            let date = (info?["Last Backup Date"] as? Date) ?? Measure.modificationDate(path) ?? .distantPast
            return Backup(path: path, name: name, device: device, date: date, bytes: Measure.size(path))
        }
        // Without an identifier Sweep can't tell devices apart, so each such backup is its own group.
        let byDevice = Dictionary(grouping: backups) { $0.device?.uppercased() ?? $0.path }
        let duplicateNames = Set(Dictionary(grouping: byDevice.values.compactMap(\.first), by: \.name).filter { $0.value.count > 1 }.keys)
        let groups = byDevice.keys.sorted().map { key -> ScanGroup in
            let sorted = byDevice[key]!.sorted { $0.date > $1.date }
            let current = sorted.filter { !$0.isArchived }
            let items = sorted.map { backup -> ScanItem in
                // Keep each device's newest backup and anything archived on purpose; older ones are preselected
                // only when the device is known for sure.
                let isNewest = backup.path == current.first?.path
                let selected = backup.device != nil && !backup.isArchived && !isNewest
                let title = backup.isArchived ? "Archived backup" : isNewest ? "Latest backup" : "Older backup"
                return removable(backup.path, title: title, bytes: backup.bytes, selected: selected, subtitle: backup.path,
                                 date: backup.date)
            }
            let first = sorted[0]
            let title = duplicateNames.contains(first.name) ? "\(first.name) (…\((first.device ?? key).suffix(4)))" : first.name
            return ScanGroup(id: "backup:" + key, title: title, subtitle: "\(sorted.count) \(sorted.count == 1 ? "backup" : "backups")",
                             icon: .symbol("iphone"), items: items)
        }
        return category("deviceBackups", "iOS Device Files", symbol: "iphone.gen3",
                        summary: "Local backups of iPhones and iPads, and software updates downloaded for them. The newest backup of each device is kept by default.",
                        groups: groups + softwareUpdates())
    }

    /// Software updates Finder downloaded to restore or update devices. Finder downloads them again when needed.
    func softwareUpdates() -> [ScanGroup] {
        let folders = ["iPhone", "iPad", "iPod"].map { environment.user("Library/iTunes/\($0) Software Updates") }
        let items = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
                .filter { $0.hasSuffix(".ipsw") }
                .map { name -> ScanItem in
                    let path = folder + "/" + name
                    return removable(path, title: name, bytes: Measure.size(path), selected: true, subtitle: path,
                                     date: Measure.modificationDate(path))
                }
        }
        return items.isEmpty ? [] : [ScanGroup(id: "firmware", title: "Software Updates",
                                              subtitle: "Downloaded to update or restore devices",
                                              icon: .symbol("arrow.down.circle.fill"), items: items)]
    }

    func developerJunk() -> ScanCategory? {
        let xcode = environment.user("Library/Developer/Xcode")
        var groups: [ScanGroup] = []
        func group(_ id: String, _ title: String, _ folder: String, selected: Bool, perEntry: Bool = true) {
            guard let tree = Measure.tree(folder) else { return }
            let entries = perEntry ? tree.entries.filter { $0.bytes > 0 }
                : [(name: (folder as NSString).lastPathComponent, path: folder, bytes: tree.allocatedSize, isDirectory: true)]
            let items = entries.filter { $0.bytes > 0 }.map { entry in
                removable(entry.path, title: Self.derivedDataName(entry.name), bytes: entry.bytes, selected: selected,
                          subtitle: entry.path, date: Measure.modificationDate(entry.path))
            }
            if !items.isEmpty {
                groups.append(ScanGroup(id: "dev:" + id, title: title, subtitle: folder, icon: .symbol("hammer.fill"),
                                        items: items))
            }
        }
        group("derived", "Xcode Derived Data", xcode + "/DerivedData", selected: true)
        group("archives", "Xcode Archives", xcode + "/Archives", selected: false)
        for platform in ["iOS", "watchOS", "tvOS", "macOS", "visionOS"] {
            group("support-\(platform)", "\(platform) Device Support", xcode + "/\(platform) DeviceSupport", selected: false)
        }
        group("devicelogs", "iOS Device Logs", xcode + "/iOS Device Logs", selected: true)
        group("doccache", "Documentation Cache", xcode + "/DocumentationCache", selected: false, perEntry: false)
        group("simcaches", "Simulator Caches", environment.user("Library/Developer/CoreSimulator/Caches"),
              selected: true, perEntry: false)
        return category("developerJunk", "Developer Junk", symbol: "hammer.circle.fill",
                        summary: "Build products and device files from Xcode. Xcode recreates what it needs.",
                        groups: groups)
    }

    static func derivedDataName(_ name: String) -> String {
        // "MyApp-abcdefghijklmnopqrstuvwxyz" → "MyApp"
        if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) > 20 {
            return String(name[..<dash])
        }
        return name
    }

    func deletedUsers() -> ScanCategory? {
        let folder = environment.system("/Users/Deleted Users")
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { $0.hasSuffix(".dmg") }
            .map { name -> ScanItem in
                let path = folder + "/" + name
                return removable(path, title: name, bytes: Measure.size(path), selected: false, subtitle: path)
            }
        guard !items.isEmpty else { return nil }
        return category("deletedUsers", "Deleted Users", symbol: "person.crop.circle.badge.xmark",
                        summary: "Disk images macOS kept when user accounts were deleted.",
                        groups: [ScanGroup(id: "deletedUsers", title: "Archived accounts", icon: .symbol("person.fill"),
                                           items: items)])
    }

    // MARK: Trash

    func trashBins() -> ScanCategory? {
        var groups: [ScanGroup] = []
        func trash(_ id: String, _ title: String, _ folder: String) {
            guard let tree = Measure.tree(folder) else { return }
            let items = tree.entries.filter { $0.name != ".DS_Store" }.map { entry in
                removable(entry.path, title: entry.name, bytes: entry.bytes, selected: true, subtitle: entry.path,
                          date: Measure.modificationDate(entry.path), mode: .deletePermanently)
            }
            if !items.isEmpty {
                groups.append(ScanGroup(id: "trash:" + id, title: title, subtitle: folder, icon: .symbol("trash.fill"),
                                        items: items))
            }
        }
        trash("home", "Trash", environment.user(".Trash"))
        trash("icloud", "iCloud Drive Trash", environment.user("Library/Mobile Documents/com~apple~CloudDocs/.Trash"))
        for volume in subfolders(environment.system("/Volumes")) {
            let name = (volume as NSString).lastPathComponent
            trash("volume:" + name, "Trash on \(name)", volume + "/.Trashes/\(environment.userID)")
        }
        return category("trash", "Trash Bins", symbol: "trash.square.fill",
                        summary: "Items already in the Trash. Emptying them frees the space for good.",
                        groups: groups)
    }

    // MARK: Mail

    func mailAttachments() -> ScanCategory? {
        var groups: [ScanGroup] = []
        // Attachments of server-backed (IMAP / iCloud) accounts can be downloaded again from the server.
        let mail = environment.user("Library/Mail")
        // Without the accounts database (no Full Disk Access) we can't tell POP from IMAP, so skip accounts.
        let imapAccounts = MailAccounts.imapAccountFolders(home: environment.home) ?? []
        for version in subfolders(mail) where (version as NSString).lastPathComponent.hasPrefix("V") {
            for account in subfolders(version) {
                let id = (account as NSString).lastPathComponent
                guard imapAccounts.contains(id) else { continue }
                var items: [ScanItem] = []
                for attachments in Self.findFolders(named: "Attachments", under: account, maxDepth: 6) {
                    guard let tree = Measure.tree(attachments) else { continue }
                    for message in tree.children where message.allocatedSize > 0 {
                        for file in message.entries where file.bytes > 0 {
                            items.append(removable(file.path, title: file.name, bytes: file.bytes, selected: true,
                                                   subtitle: "Can be downloaded again from the mail server",
                                                   date: Measure.modificationDate(file.path)))
                        }
                    }
                }
                if !items.isEmpty {
                    groups.append(ScanGroup(id: "mail:" + id, title: "Mail account", subtitle: id,
                                            icon: .symbol("envelope.fill"), items: items))
                }
            }
        }
        // Files opened from messages and saved by Mail.
        for downloads in [environment.user("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                          environment.user("Library/Mail Downloads")] {
            guard let tree = Measure.tree(downloads) else { continue }
            let items = tree.children.flatMap { folder in
                folder.entries.filter { $0.bytes > 0 }.map { file in
                    removable(file.path, title: file.name, bytes: file.bytes, selected: !Self.wasModified(file.path),
                              subtitle: "Opened from Mail", date: Measure.modificationDate(file.path))
                }
            }
            if !items.isEmpty {
                groups.append(ScanGroup(id: "mail:downloads:" + downloads, title: "Mail Downloads", subtitle: downloads,
                                        icon: .symbol("arrow.down.doc.fill"), items: items))
            }
        }
        return category("mail", "Mail Attachments", symbol: "paperclip.circle.fill",
                        summary: "Local copies of attachments. Messages keep them on the server, so you can download them again.",
                        groups: groups)
    }

    /// A file the user edited after Mail saved it is kept by default.
    static func wasModified(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mtimespec.tv_sec > info.st_birthtimespec.tv_sec + 2
    }

    static func findFolders(named name: String, under root: String, maxDepth: Int) -> [String] {
        var found: [String] = []
        func walk(_ folder: String, _ depth: Int) {
            guard depth <= maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for child in names where !child.hasPrefix(".") {
                let path = folder + "/" + child
                guard AppCatalog.isDirectory(path) else { continue }
                if child == name { found.append(path) } else { walk(path, depth + 1) }
            }
        }
        walk(root, 0)
        return found
    }

    // MARK: Helpers

    private func removable(_ path: String, title: String, bytes: UInt64, selected: Bool, subtitle: String? = nil,
                           date: Date? = nil, note: String? = nil, mode: RemovalMode? = nil) -> ScanItem {
        ScanItem(id: path, title: title, subtitle: subtitle, size: bytes, date: date, isSelectedByDefault: selected,
                 action: .remove(paths: [path], mode: mode ?? self.mode), note: note)
    }

    private func category(_ id: String, _ title: String, symbol: String, summary: String,
                          groups: [ScanGroup]) -> ScanCategory? {
        let groups = groups.filter { !$0.items.isEmpty }.sorted { $0.size > $1.size }
        return groups.isEmpty ? nil : ScanCategory(id: id, title: title, summary: summary, symbol: symbol, groups: groups)
    }

    /// Groups with the same title (an app's cache in several places) become one.
    private func merge(_ groups: [ScanGroup]) -> [ScanGroup] {
        var merged: [String: ScanGroup] = [:]
        var order: [String] = []
        for group in groups {
            if var existing = merged[group.title] {
                existing.items += group.items
                merged[group.title] = existing
            } else {
                merged[group.title] = group
                order.append(group.title)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private func subfolders(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { folder + "/" + $0 }
            .filter(AppCatalog.isDirectory)
    }

    private func displayName(forCacheFolder name: String) -> String {
        // "com.vendor.AppName" → "AppName"
        let parts = name.split(separator: ".")
        if parts.count >= 3, let last = parts.last { return String(last) }
        return name
    }
}

/// Reading launchd job definitions.
public enum LaunchItem {
    /// The program a launchd plist starts, with `~` expanded. Nil if the plist can't be read.
    public static func program(ofPlistAt path: String, home: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: path) else { return nil }
        var program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard var resolved = program, !resolved.isEmpty else { return nil }
        if resolved.hasPrefix("~") { resolved = home + resolved.dropFirst() }
        if !resolved.hasPrefix("/"), let directory = plist["WorkingDirectory"] as? String {
            resolved = directory + "/" + resolved
        }
        program = resolved
        // Commands run through a shell or interpreter, like "/bin/sh -c …", always "exist"; that's fine.
        return program
    }
}

/// Which Mail account folders belong to IMAP / iCloud accounts.
enum MailAccounts {
    /// Folder identifiers of server-backed mail accounts, or nil if the accounts database can't be read.
    static func imapAccountFolders(home: String) -> Set<String>? {
        let path = home + "/Library/Accounts/Accounts4.sqlite"
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        let query = """
            SELECT a.ZIDENTIFIER FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
            WHERE t.ZIDENTIFIER IN ('com.apple.account.IMAP', 'com.apple.account.IMAPMail', 'com.apple.account.AppleAccount', 'com.apple.account.Google', 'com.apple.account.Exchange')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var identifiers = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { identifiers.insert(String(cString: text)) }
        }
        return identifiers
    }
}

enum Exclusions {
    /// Cache folders that hold state, not just caches, or that macOS needs.
    static let caches: Set<String> = [
        "CloudKit", "com.apple.bird", "com.apple.nsurlsessiond", "com.apple.containermanagerd", "com.apple.HomeKit",
        "com.apple.homed", "FamilyCircle", "com.apple.akd", "com.apple.ap.adprivacyd", "com.apple.findmy.fmipcore",
        "com.apple.icloud.fmfd", "com.apple.Safari.SafeBrowsing", "com.apple.passd", "com.apple.appstoreagent",
        "com.apple.amsengagementd", "com.apple.parsecd", "com.apple.TCC", "com.apple.iCloudHelper",
    ]
    /// Cache folders worth listing child by child.
    static let deepSearchCaches: Set<String> = ["Google", "Microsoft", "JetBrains", "Adobe", "com.apple.Safari"]
    /// Sweep's own folder holds the removal history that "Show Log File" opens; it isn't junk.
    static let excludedLogs: Set<String> = ["DiagnosticReports", "com.apple.xpc.launchd", "Sweep"]
    /// Folders in ~/Library/Caches that developer tool caches already list.
    static let developerToolCaches: Set<String> = ["Yarn", "CocoaPods"]

    static func isExcludedCache(_ name: String, owner: String?) -> Bool {
        if name == ".DS_Store" { return true }
        if caches.contains(name) { return true }
        if let owner, caches.contains(owner) { return true }
        return false
    }
}
