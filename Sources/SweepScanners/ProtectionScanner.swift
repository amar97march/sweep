import Foundation
import Security
import SQLite3
import SweepCore

/// Malware (YARA rules), suspicious startup items, and privacy traces.
public struct ProtectionScanner: Sendable {
    public enum Depth: String, Sendable { case quick, deep }

    public let environment: ScanEnvironment
    public let depth: Depth
    public let rules: YaraRuleSet?
    public let run: PerformanceScanner.Run
    /// Files larger than this aren't scanned for malware.
    public var maximumFileSize = 50_000_000

    public init(environment: ScanEnvironment, depth: Depth = .quick, rules: YaraRuleSet? = RuleSource.xprotect(),
                run: @escaping PerformanceScanner.Run = Shell.quick) {
        self.environment = environment
        self.depth = depth
        self.rules = rules
        self.run = run
    }

    public func scan(progress: (String) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [ScanCategory] {
        var categories: [ScanCategory] = []
        let background = BackgroundItems.list(environment: environment, run: run)
        if let rules {
            progress("Checking files against \(rules.publicRules.count) malware signatures")
            if let threats = threats(rules: rules, background: background, progress: progress, isCancelled: isCancelled) {
                categories.append(threats)
            }
        }
        guard !isCancelled() else { return categories }
        progress("Checking startup items")
        if let suspicious = suspiciousStartupItems(background) { categories.append(suspicious) }
        progress("Looking for browsing traces")
        if let browsers = BrowserPrivacy(environment: environment).category() { categories.append(browsers) }
        progress("Checking app permissions and recent items")
        if let other = otherPrivacy() { categories.append(other) }
        return categories
    }

    // MARK: Malware

    func scanTargets(background: [BackgroundItem]) -> [String] {
        var files = Set<String>()
        for item in background {
            if let executable = item.executable { files.insert(executable) }
            if let plist = item.plist, let program = LaunchItem.program(ofPlistAt: plist, home: environment.home) { files.insert(program) }
        }
        let helperFolder = environment.system("/Library/PrivilegedHelperTools")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: helperFolder)) ?? [] { files.insert(helperFolder + "/" + name) }
        for app in AppCatalog.installed(in: environment) {
            if let executable = app.executable { files.insert(app.path + "/Contents/MacOS/" + executable) }
        }
        let shallow = [("Downloads", 3), ("Desktop", 2), ("Library/Application Support", 2)].map { (environment.user($0.0), $0.1) }
            + [(environment.system("/Users/Shared"), 3), (environment.system("/private/tmp"), 2), (environment.system("/private/var/tmp"), 2)]
        let deep = depth == .deep ? [(environment.home, 12), (environment.system("/Applications"), 12)] : []
        for (folder, maxDepth) in shallow + deep {
            files.formUnion(Self.executables(under: folder, maxDepth: maxDepth))
        }
        return files.sorted()
    }

    /// Mach-O binaries and scripts under `folder`.
    static func executables(under folder: String, maxDepth: Int) -> [String] {
        var found: [String] = []
        let reader = BulkDirectoryReader()
        var queue = [(folder, 0)]
        while let (current, level) = queue.popLast() {
            reader.read(current) { entry in
                let path = current + "/" + entry.name
                if entry.kind == .directory {
                    if level < maxDepth && !FileWalker.skippedFolders.contains(entry.name) { queue.append((path, level + 1)) }
                } else if entry.kind == .file && !entry.isDataless && entry.logicalSize >= 4 && Self.isExecutableFormat(path) {
                    found.append(path)
                }
            }
        }
        return found
    }

    static func isExecutableFormat(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let machO: Set<UInt32> = [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca]
        return machO.contains(magic) || head.starts(with: [0x23, 0x21])  // "#!"
    }

    func threats(rules: YaraRuleSet, background: [BackgroundItem], progress: (String) -> Void,
                 isCancelled: () -> Bool) -> ScanCategory? {
        let targets = scanTargets(background: background)
        let found = Locked<[ScanItem]>([])
        let done = Locked(0)
        let maximum = maximumFileSize
        // Files are independent, so scan them on every core, a batch at a time so Stop takes effect quickly.
        let batch = 256
        for start in stride(from: 0, to: targets.count, by: batch) {
            if isCancelled() { break }
            let slice = Array(targets[start..<min(start + batch, targets.count)])
            DispatchQueue.concurrentPerform(iterations: slice.count) { index in
                let path = slice[index]
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return }
                let hits = rules.matches(data)
                done.withLock { $0 += 1 }
                guard let first = hits.first else { return }
                let name = rules.rules.first { $0.name == first }?.meta["description"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? first
                found.withLock {
                    $0.append(ScanItem(id: "threat:" + path, title: (path as NSString).lastPathComponent,
                                       subtitle: "\(name) · \(path)", size: UInt64(info.st_blocks) * 512, isSelectedByDefault: true,
                                       action: .custom(kind: "quarantine", payload: [path, name])))
                }
            }
        }
        progress("Checked \(targets.count.formatted()) files")
        let items = found.withLock { $0 }.sorted { $0.id < $1.id }
        guard !items.isEmpty else { return nil }
        return ScanCategory(id: "threats", title: "Threats",
                            summary: "Files matching known malware signatures. They're moved to quarantine, where you can restore them.",
                            symbol: "ladybug.fill",
                            groups: [ScanGroup(id: "threats", title: "Malware", subtitle: "\(items.count) found",
                                               icon: .symbol("exclamationmark.shield.fill"), items: items)])
    }

    // MARK: Startup heuristics

    func suspiciousStartupItems(_ background: [BackgroundItem]) -> ScanCategory? {
        let items = background.compactMap { item -> ScanItem? in
            guard item.type.isLaunchd, let plist = item.plist else { return nil }
            let reasons = Self.suspicionReasons(plist: plist, item: item, home: environment.home)
            guard !reasons.isEmpty else { return nil }
            let isSystem = !plist.hasPrefix(environment.home)
            return ScanItem(id: "suspicious:" + plist, title: item.name, subtitle: reasons.joined(separator: " · "),
                            size: 0, isSelectedByDefault: false,
                            action: .custom(kind: "removeBackgroundItem",
                                            payload: [plist, item.label ?? "", item.type == .daemon ? "daemon" : "agent",
                                                      isSystem ? "system" : "user"]))
        }
        guard !items.isEmpty else { return nil }
        return ScanCategory(id: "suspicious", title: "Suspicious Startup Items",
                            summary: "Background items that behave like adware or malware. Review each one before removing it.",
                            symbol: "exclamationmark.triangle.fill",
                            groups: [ScanGroup(id: "suspicious", title: "Needs review", icon: .symbol("eye.trianglebadge.exclamationmark.fill"),
                                               items: items)])
    }

    static func suspicionReasons(plist: String, item: BackgroundItem, home: String) -> [String] {
        guard let definition = NSDictionary(contentsOfFile: plist) else { return [] }
        var reasons: [String] = []
        let arguments = (definition["ProgramArguments"] as? [String]) ?? []
        let program = LaunchItem.program(ofPlistAt: plist, home: home) ?? ""
        let commandLine = ([program] + arguments).joined(separator: " ").lowercased()

        if let environment = definition["EnvironmentVariables"] as? [String: Any],
           environment.keys.contains(where: { $0.hasPrefix("DYLD_") }) {
            reasons.append("Injects code into other programs (DYLD)")
        }
        let interpreters = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/osascript", "/usr/bin/perl"]
        if interpreters.contains(where: { program.hasPrefix($0) }),
           ["curl ", "wget ", "base64", "| sh", "|sh", "| bash", "eval "].contains(where: commandLine.contains) {
            reasons.append("Downloads or decodes and runs code")
        }
        let suspiciousPlaces = ["/tmp/", "/private/tmp/", "/users/shared/", "/var/folders/", "/private/var/tmp/"]
        let lowerProgram = program.lowercased()
        let hidden = program.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
        if suspiciousPlaces.contains(where: lowerProgram.hasPrefix) || hidden {
            reasons.append("Runs from a hidden or temporary folder")
        }
        if !program.isEmpty, FileManager.default.fileExists(atPath: program), !interpreters.contains(program),
           CodeSignature.status(program) == .unsigned, !reasons.isEmpty {
            reasons.append("Not signed")
        }
        if (plist as NSString).lastPathComponent.hasPrefix("com.apple."), !plist.hasPrefix("/System/"),
           CodeSignature.status(program) != .apple {
            reasons.append("Pretends to be part of macOS")
        }
        return reasons
    }

    // MARK: Other privacy

    func otherPrivacy() -> ScanCategory? {
        var groups: [ScanGroup] = []
        // Recent items lists (Finder, apps, servers).
        let shared = environment.user("Library/Application Support/com.apple.sharedfilelist")
        var recent: [ScanItem] = []
        for folder in [shared, shared + "/com.apple.LSSharedFileList.ApplicationRecentDocuments"] {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            where Self.isRecentItemsList(name, inAppFolder: folder != shared) {
                let path = folder + "/" + name
                let title = name.replacingOccurrences(of: "com.apple.LSSharedFileList.", with: "")
                    .replacingOccurrences(of: ".sfl3", with: "").replacingOccurrences(of: ".sfl2", with: "")
                recent.append(ScanItem(id: "recent:" + path, title: title, subtitle: "Recently used list", size: 0,
                                       isSelectedByDefault: true, action: .custom(kind: "clearRecent", payload: [path])))
            }
        }
        if !recent.isEmpty {
            groups.append(ScanGroup(id: "privacy:recent", title: "Recent Items", subtitle: "Lists of files, apps and servers you used",
                                    icon: .symbol("clock.arrow.circlepath"), items: recent))
        }
        // Apps allowed to use the camera, microphone, screen recording, etc.
        let permissions = TCCPermissions.allowed(home: environment.home, systemRoot: environment.systemRoot)
        if !permissions.isEmpty {
            let items = permissions.map { entry in
                ScanItem(id: "tcc:\(entry.service):\(entry.client)", title: entry.client,
                         subtitle: "Allowed: \(TCCPermissions.label(entry.service))", size: 0, isSelectedByDefault: false,
                         action: .custom(kind: "revokePermission", payload: [entry.service, entry.client]))
            }
            groups.append(ScanGroup(id: "privacy:tcc", title: "App Permissions", subtitle: "Revoke access you no longer want to give",
                                    icon: .symbol("hand.raised.fill"), items: items))
        }
        // Saved Wi-Fi networks.
        let networks = WiFiNetworks.saved(run: run)
        if !networks.ssids.isEmpty {
            groups.append(ScanGroup(id: "privacy:wifi", title: "Saved Wi-Fi Networks", subtitle: "Your Mac joins these automatically",
                                    icon: .symbol("wifi"), items: networks.ssids.map { ssid in
                                        ScanItem(id: "wifi:" + ssid, title: ssid, subtitle: "Saved network", size: 0,
                                                 isSelectedByDefault: false,
                                                 action: .custom(kind: "forgetWiFi", payload: [networks.device, ssid]))
                                    }))
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "privacy", title: "Privacy", summary: "Traces of what you've used, and what apps may access.",
                            symbol: "hand.raised.circle.fill", groups: groups)
    }

    /// Only "recent" lists are traces. The same folder keeps the Finder sidebar (FavoriteItems, FavoriteVolumes,
    /// ProjectsItems, iCloudItems), which must never be cleared. The file format number changes between macOS
    /// versions (.sfl2, .sfl3, .sfl4…), so any is accepted.
    static func isRecentItemsList(_ name: String, inAppFolder: Bool) -> Bool {
        guard name.range(of: #"\.sfl\d+$"#, options: .regularExpression) != nil else { return false }
        return inAppFolder || name.hasPrefix("com.apple.LSSharedFileList.Recent")
    }
}

/// Where malware rules come from: Apple's XProtect rules, read in place, plus any rule files the user adds.
public enum RuleSource {
    public static let xprotectPaths = [
        "/var/protected/xprotect/XProtect.bundle/Contents/Resources/XProtect.yara",
        "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.yara",
    ]

    public static func xprotect(extraFolder: String? = nil) -> YaraRuleSet? {
        var sources: [String] = []
        if let path = xprotectPaths.first(where: FileManager.default.isReadableFile),
           let text = try? String(contentsOfFile: path, encoding: .utf8) { sources.append(text) }
        let folder = extraFolder ?? NSHomeDirectory() + "/Library/Application Support/Sweep/Rules"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        where name.hasSuffix(".yar") || name.hasSuffix(".yara") {
            if let text = try? String(contentsOfFile: folder + "/" + name, encoding: .utf8) { sources.append(text) }
        }
        return sources.isEmpty ? nil : YaraRuleSet(source: sources.joined(separator: "\n"))
    }
}

public enum CodeSignature {
    public enum Status: Sendable, Equatable { case apple, developer, adHoc, unsigned, invalid }

    public static func status(_ path: String) -> Status {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        let validity = SecStaticCodeCheckValidity(code, [], nil)
        if validity == errSecCSUnsigned { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess { return .apple }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        return team == nil ? .adHoc : .developer
    }
}

/// Apps' privacy permissions from the TCC databases (readable with Full Disk Access).
///
/// The user's database holds per-user grants (Camera, Microphone, Automation…) and the system one holds Mac-wide
/// grants (Accessibility, Screen Recording, Input Monitoring, Full Disk Access). macOS 27 moved the user's database
/// into a protected system container that even Full Disk Access can't open, so there only system grants are listed.
public enum TCCPermissions {
    public struct Entry: Sendable, Hashable {
        public let service: String
        public let client: String
        public init(service: String, client: String) {
            self.service = service
            self.client = client
        }
    }

    static let relativePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// The databases on this Mac: the user's (macOS 26 and earlier), then the system's.
    public static func databases(home: String, systemRoot: String) -> [String] {
        [home + relativePath, systemRoot + relativePath].filter { path in
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
    }

    /// Apps (by bundle identifier) allowed a permission, from every database this process can read.
    public static func allowed(home: String, systemRoot: String) -> [Entry] {
        let entries = Set(databases(home: home, systemRoot: systemRoot).flatMap(allowed(inDatabaseAt:)))
        return entries.sorted { ($0.client, $0.service) < ($1.client, $1.service) }
    }

    /// Opened read-only and without following links, so the scan can never change a database.
    static func allowed(inDatabaseAt path: String) -> [Entry] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)  // tccd holds the write lock only briefly
        // auth_value 2 is "allowed"; client_type 0 is a bundle identifier, the only kind tccutil can reset.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT DISTINCT service, client FROM access WHERE auth_value = 2 AND client_type = 0",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let service = sqlite3_column_text(statement, 0), let client = sqlite3_column_text(statement, 1) else { continue }
            entries.append(Entry(service: String(cString: service), client: String(cString: client)))
        }
        return entries
    }

    public static func label(_ service: String) -> String {
        let names = [
            "kTCCServiceCamera": "Camera", "kTCCServiceMicrophone": "Microphone", "kTCCServiceScreenCapture": "Screen Recording",
            "kTCCServiceAccessibility": "Accessibility", "kTCCServiceListenEvent": "Input Monitoring",
            "kTCCServiceAppleEvents": "Automation", "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
            "kTCCServiceAddressBook": "Contacts", "kTCCServiceCalendar": "Calendars", "kTCCServiceReminders": "Reminders",
            "kTCCServicePhotos": "Photos", "kTCCServiceSystemPolicyDesktopFolder": "Desktop Folder",
            "kTCCServiceSystemPolicyDocumentsFolder": "Documents Folder", "kTCCServiceSystemPolicyDownloadsFolder": "Downloads Folder",
            "kTCCServiceSpeechRecognition": "Speech Recognition", "kTCCServiceSystemPolicyRemovableVolumes": "Removable Volumes",
            "kTCCServiceSystemPolicyNetworkVolumes": "Network Volumes", "kTCCServiceLocation": "Location",
            "kTCCServiceSystemPolicyAppBundles": "App Management", "kTCCServiceDeveloperTool": "Developer Tools",
        ]
        return names[service] ?? service.replacingOccurrences(of: "kTCCService", with: "")
    }
}

enum WiFiNetworks {
    static func saved(run: PerformanceScanner.Run) -> (device: String, ssids: [String]) {
        let ports = run("/usr/sbin/networksetup", ["-listallhardwareports"]).output
        var device = "en0"
        let lines = ports.split(separator: "\n").map(String.init)
        for (index, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if index + 1 < lines.count, lines[index + 1].hasPrefix("Device: ") { device = String(lines[index + 1].dropFirst(8)) }
        }
        let result = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device])
        guard result.status == 0 else { return (device, []) }
        let ssids = result.output.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (device, ssids)
    }
}

/// Moves threats out of the way instead of deleting them, with a manifest so they can be restored.
public enum Quarantine {
    public static var defaultFolder: String { NSHomeDirectory() + "/Library/Application Support/Sweep/Quarantine" }

    public struct Entry: Codable, Sendable {
        public let originalPath: String
        public let quarantinedPath: String
        public let threat: String
        public let date: Date
        public let mode: UInt16
    }

    public static func move(_ path: String, threat: String, folder: String = defaultFolder) throws -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        let slot = folder + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: slot, withIntermediateDirectories: true)
        let destination = slot + "/" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        chmod(destination, info.st_mode & 0o666)  // can't run from quarantine
        let entry = Entry(originalPath: path, quarantinedPath: destination, threat: threat, date: Date(), mode: UInt16(info.st_mode & 0o7777))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: URL(fileURLWithPath: slot + "/manifest.json"))
        return entry
    }

    public static func restore(_ entry: Entry) throws {
        try FileManager.default.moveItem(atPath: entry.quarantinedPath, toPath: entry.originalPath)
        chmod(entry.originalPath, mode_t(entry.mode))
        try? FileManager.default.removeItem(atPath: (entry.quarantinedPath as NSString).deletingLastPathComponent)
    }
}
