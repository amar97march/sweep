import Foundation
import SQLite3
import SweepCore

/// Maintenance tasks plus everything that starts automatically: login items and background (launchd) items.
public struct PerformanceScanner: Sendable {
    public typealias Run = @Sendable (String, [String]) -> (status: Int32, output: String)

    public let environment: ScanEnvironment
    public let run: Run
    /// Task identifiers run recently enough not to recommend again.
    public let recentlyRun: Set<String>

    public init(environment: ScanEnvironment, recentlyRun: Set<String> = [], run: @escaping Run = Shell.quick) {
        self.environment = environment
        self.run = run
        self.recentlyRun = recentlyRun
    }

    public func scan(progress: (String) -> Void = { _ in }) -> [ScanCategory] {
        progress("Checking maintenance tasks")
        var categories: [ScanCategory] = []
        if let tasks = maintenance() { categories.append(tasks) }
        progress("Looking at login and background items")
        let items = BackgroundItems.list(environment: environment, run: run)
        if let login = loginItems(items) { categories.append(login) }
        if let background = backgroundItems(items) { categories.append(background) }
        return categories
    }

    // MARK: Maintenance

    func maintenance() -> ScanCategory? {
        let available = MaintenanceTask.allCases.filter { $0.isAvailable(environment: environment, run: run) }
        let items = available.map { task in
            ScanItem(id: "task:" + task.rawValue, title: task.title, subtitle: task.detail, size: 0, date: nil,
                     isSelectedByDefault: task.isRecommended && !recentlyRun.contains(task.rawValue),
                     action: .task(task.rawValue))
        }
        guard !items.isEmpty else { return nil }
        let recommended = items.filter(\.isSelectedByDefault)
        let other = items.filter { !$0.isSelectedByDefault }
        var groups: [ScanGroup] = []
        if !recommended.isEmpty {
            groups.append(ScanGroup(id: "tasks:recommended", title: "Recommended", subtitle: "Quick and safe to run now",
                                    icon: .symbol("star.fill"), items: recommended))
        }
        if !other.isEmpty {
            groups.append(ScanGroup(id: "tasks:other", title: "Other Tasks", subtitle: "Run these when something feels off",
                                    icon: .symbol("wrench.and.screwdriver.fill"), items: other))
        }
        return ScanCategory(id: "maintenance", title: "Maintenance Tasks",
                            summary: "Housekeeping macOS doesn't always do on its own. Tasks marked with a lock ask for your password.",
                            symbol: "wrench.and.screwdriver.fill", groups: groups)
    }

    // MARK: Startup items

    func loginItems(_ items: [BackgroundItem]) -> ScanCategory? {
        var seen = Set<String>()
        let login = items.filter { ($0.type == .loginItem || $0.type == .app) && seen.insert($0.identifier).inserted }
        guard !login.isEmpty else { return nil }
        let entries = login.map { item in
            ScanItem(id: "login:" + item.identifier, title: item.name,
                     subtitle: (item.enabled ? "Opens at login" : "Turned off") + (item.developer.map { " · \($0)" } ?? ""),
                     size: 0, isSelectedByDefault: false,
                     action: .custom(kind: "openLoginItemsSettings", payload: [item.identifier]),
                     note: nil)
        }
        return ScanCategory(id: "loginItems", title: "Login Items",
                            summary: "Apps that open when you log in. macOS lets you turn these off in System Settings.",
                            symbol: "power.circle.fill",
                            groups: [ScanGroup(id: "login", title: "Open at login", icon: .symbol("person.crop.circle.badge.checkmark"),
                                               items: entries)])
    }

    func backgroundItems(_ items: [BackgroundItem]) -> ScanCategory? {
        // sfltool can list the same plist more than once; show it once. A plist inside an app bundle belongs to the
        // app (removing it would break the app's signature): it's switched off in System Settings, never removed.
        var seen = Set<String>()
        let background = items.filter { item in
            guard item.type.isLaunchd, let plist = item.plist, !plist.contains(".app/") else { return false }
            return seen.insert(plist).inserted
        }
        guard !background.isEmpty else { return nil }
        let byDeveloper = Dictionary(grouping: background) { $0.developer ?? "Unknown developer" }
        let groups = byDeveloper.keys.sorted().map { developer in
            ScanGroup(id: "bg:" + developer, title: developer,
                      subtitle: "\(byDeveloper[developer]!.count) background items",
                      icon: .symbol(developer == "Unknown developer" ? "questionmark.circle.fill" : "gearshape.2.fill"),
                      items: byDeveloper[developer]!.map { item in
                          let isSystem = !(item.plist ?? "").hasPrefix(environment.home)
                          return ScanItem(
                              id: "bg:" + (item.plist ?? item.identifier), title: item.name,
                              subtitle: [item.enabled ? "Running at startup" : "Turned off",
                                         item.type == .daemon ? "system-wide" : nil,
                                         item.executable].compactMap { $0 }.joined(separator: " · "),
                              size: 0, isSelectedByDefault: false,
                              action: .custom(kind: "removeBackgroundItem",
                                              payload: [item.plist!, item.label ?? "", item.type == .daemon ? "daemon" : "agent",
                                                        isSystem ? "system" : "user"]))
                      })
        }
        return ScanCategory(id: "backgroundItems", title: "Background Items",
                            summary: "Helpers and services that run in the background. Removing one stops it from starting.",
                            symbol: "gearshape.2.fill", groups: groups)
    }
}

/// Maintenance tasks and the commands behind them.
public enum MaintenanceTask: String, CaseIterable, Sendable {
    case flushDNS, freeUpRAM, thinSnapshots, speedUpMail, rebuildLaunchServices, reindexSpotlight,
         repairPermissions, periodicScripts

    public var title: String {
        switch self {
        case .flushDNS: "Flush DNS Cache"
        case .freeUpRAM: "Free Up RAM"
        case .thinSnapshots: "Thin Time Machine Snapshots"
        case .speedUpMail: "Speed Up Mail"
        case .rebuildLaunchServices: "Rebuild Launch Services"
        case .reindexSpotlight: "Reindex Spotlight"
        case .repairPermissions: "Repair Home Folder Permissions"
        case .periodicScripts: "Run Maintenance Scripts"
        }
    }

    public var detail: String {
        switch self {
        case .flushDNS: "Fixes websites that won't load after network changes. Needs your password."
        case .freeUpRAM: "Asks macOS to release inactive memory right away. Needs your password."
        case .thinSnapshots: "Reclaims space held by local Time Machine snapshots."
        case .speedUpMail: "Compacts Mail's message database. Mail will be closed first."
        case .rebuildLaunchServices: "Fixes duplicate apps in “Open With” and wrong default apps."
        case .reindexSpotlight: "Rebuilds the search index. Searches are incomplete for a while afterwards. Needs your password."
        case .repairPermissions: "Resets permissions in your home folder. Needs your password."
        case .periodicScripts: "Runs the daily, weekly and monthly system scripts. Needs your password."
        }
    }

    var isRecommended: Bool { [.flushDNS, .freeUpRAM, .thinSnapshots, .speedUpMail].contains(self) }

    public var needsAdministrator: Bool { [.flushDNS, .freeUpRAM, .reindexSpotlight, .repairPermissions, .periodicScripts].contains(self) }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    func isAvailable(environment: ScanEnvironment, run: PerformanceScanner.Run) -> Bool {
        let fm = FileManager.default
        switch self {
        case .periodicScripts: return fm.isExecutableFile(atPath: environment.system("/usr/sbin/periodic"))
        case .freeUpRAM: return fm.isExecutableFile(atPath: environment.system("/usr/sbin/purge"))
        case .speedUpMail: return MailDatabase.envelopeIndex(home: environment.home) != nil
        case .rebuildLaunchServices: return fm.isExecutableFile(atPath: environment.system(Self.lsregister))
        case .thinSnapshots:
            let result = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
            return result.status == 0 && result.output.contains("com.apple.TimeMachine")
        default: return true
        }
    }

    /// The command as root, for tasks that need it.
    func administratorCommands(userID: uid_t) -> [[String]] {
        switch self {
        case .flushDNS: [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]]
        case .freeUpRAM: [["/usr/sbin/purge"]]
        case .reindexSpotlight: [["/usr/bin/mdutil", "-E", "/"]]
        case .repairPermissions: [["/usr/sbin/diskutil", "resetUserPermissions", "/", String(userID)]]
        case .periodicScripts: [["/usr/sbin/periodic", "daily", "weekly", "monthly"]]
        default: []
        }
    }
}

enum MailDatabase {
    static func envelopeIndex(home: String) -> String? {
        let mail = home + "/Library/Mail"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: mail)) ?? [])
            .filter { $0.hasPrefix("V") }.sorted { Version.compare($0, $1) == .orderedDescending }
        for version in versions {
            let path = mail + "/" + version + "/MailData/Envelope Index"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Runs VACUUM on Mail's database. Mail must not be running.
    static func vacuum(_ path: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            return String(cString: sqlite3_errmsg(database))
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "VACUUM;", nil, nil, nil) == SQLITE_OK else {
            return String(cString: sqlite3_errmsg(database))
        }
        return nil
    }
}

/// An item from Background Task Management (what System Settings → Login Items shows).
public struct BackgroundItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case loginItem, app, agent, daemon, other

        var isLaunchd: Bool { self == .agent || self == .daemon }
    }

    public var name: String
    public var developer: String?
    public var type: Kind
    public var enabled: Bool
    public var identifier: String
    /// The launchd plist for agents and daemons.
    public var plist: String?
    public var executable: String?
    public var label: String?
    /// The app bundle, for login items and apps that register their own helpers.
    public var bundlePath: String? = nil
}

extension String {
    func trimmingSuffix(_ suffix: String) -> Substring { hasSuffix(suffix) ? dropLast(suffix.count) : self[...] }
}

public enum BackgroundItems {
    /// Items for the current user: from the background item database when this macOS has one per user, else from
    /// `sfltool dumpbtm`, else from the LaunchAgents folders.
    public static func list(environment: ScanEnvironment, run: PerformanceScanner.Run) -> [BackgroundItem] {
        if let items = BackgroundTaskDatabase.items(userID: environment.userID, home: environment.home,
                                                    folder: environment.system(BackgroundTaskDatabase.folder)), !items.isEmpty {
            return items
        }
        let result = run("/usr/bin/sfltool", ["dumpbtm"])
        let parsed = result.status == 0 ? parse(result.output, userID: environment.userID, home: environment.home) : []
        return parsed.isEmpty ? fromFolders(environment) : parsed
    }

    /// Parses `sfltool dumpbtm` output, keeping only the current user's records.
    public static func parse(_ output: String, userID: uid_t, home: String) -> [BackgroundItem] {
        var items: [BackgroundItem] = []
        var inUser = false
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard inUser, let typeText = fields["Type"], let identifier = fields["Identifier"] else { return }
            let kind: BackgroundItem.Kind
            if typeText.hasPrefix("login item") { kind = .loginItem }
            else if typeText.hasPrefix("app") { kind = .app }
            else if typeText.contains("agent") { kind = .agent }
            else if typeText.contains("daemon") { kind = .daemon }
            else { kind = .other }
            guard kind != .other else { return }
            var url = fields["URL"].flatMap { $0 == "(null)" ? nil : $0 }
            if let value = url, value.hasPrefix("file://") { url = URL(string: value)?.path }
            if let value = url, value.hasPrefix("/Users/\(userID)/") {
                url = home + "/" + value.dropFirst("/Users/\(userID)/".count)
            }
            let developer = [fields["Developer Name"], fields["Parent Identifier"]]
                .compactMap { $0 }.first { $0 != "(null)" && $0 != "Unknown Developer" }
            let name = fields["Name"].flatMap { $0 == "(null)" ? nil : $0 } ?? identifier
            let plist = (url?.hasSuffix(".plist") ?? false) ? url : nil
            items.append(BackgroundItem(
                name: name, developer: developer, type: kind,
                enabled: fields["Disposition"]?.contains("[enabled") ?? false,
                identifier: identifier, plist: plist, executable: fields["Executable Path"],
                label: plist.flatMap { NSDictionary(contentsOfFile: $0)?["Label"] as? String }
                    ?? identifier.split(separator: ".", maxSplits: 1).last.map(String.init),
                bundlePath: url.flatMap { $0.hasSuffix(".app") || $0.hasSuffix(".app/") ? String($0.trimmingSuffix("/")) : nil }))
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Records for UID") {
                flush()
                inUser = text.split(separator: " ").dropFirst(3).first.map { $0 == "\(userID)" } ?? false
            } else if text.range(of: #"^#\d+:$"#, options: .regularExpression) != nil {
                flush()
            } else if let colon = text.firstIndex(of: ":") {
                let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                fields[key] = value
            }
        }
        flush()
        return items
    }

    static func fromFolders(_ environment: ScanEnvironment) -> [BackgroundItem] {
        let folders: [(String, BackgroundItem.Kind)] = [
            (environment.user("Library/LaunchAgents"), .agent),
            (environment.system("/Library/LaunchAgents"), .agent),
            (environment.system("/Library/LaunchDaemons"), .daemon),
        ]
        return folders.flatMap { folder, kind in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
                .filter { $0.hasSuffix(".plist") }
                .map { name in
                    let path = folder + "/" + name
                    let plist = NSDictionary(contentsOfFile: path)
                    let label = plist?["Label"] as? String
                    return BackgroundItem(name: label ?? name, developer: nil, type: kind,
                                          enabled: !((plist?["Disabled"] as? Bool) ?? false), identifier: label ?? name,
                                          plist: path, executable: LaunchItem.program(ofPlistAt: path, home: environment.home),
                                          label: label)
                }
        }
    }
}

/// Runs maintenance tasks and removes background items.
public struct PerformancePerformer: Sendable {
    public var environment: ScanEnvironment
    public var run: PerformanceScanner.Run = Shell.run
    public var administrator: @Sendable ([[String]]) -> Result<String, Administrator.Failure> = Administrator.runBatch
    public var quitMail: @Sendable () async -> Bool = { true }
    public var openLoginItemsSettings: @Sendable () async -> Void = {}
    public var remover = FileRemover()

    public init(environment: ScanEnvironment) { self.environment = environment }

    public func perform(_ items: [ScanItem], progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> [ActionRecord] {
        var records: [ActionRecord] = []
        var adminCommands: [[String]] = []
        var adminItems: [ScanItem] = []
        func record(_ item: ScanItem, _ outcome: ActionRecord.Outcome) {
            records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: 0, outcome: outcome))
        }

        for (index, item) in items.enumerated() {
            defer { progress(index + 1, items.count) }
            switch item.action {
            case .task(let id):
                guard let task = MaintenanceTask(rawValue: id) else { continue }
                if task.needsAdministrator {
                    adminCommands += task.administratorCommands(userID: environment.userID)
                    adminItems.append(item)
                } else {
                    record(item, await runUserTask(task))
                }
            case .custom("removeBackgroundItem", let payload) where payload.count == 4:
                let (plist, label, kind, scope) = (payload[0], payload[1], payload[2], payload[3])
                if scope == "user" {
                    _ = run("/bin/launchctl", ["bootout", "gui/\(environment.userID)", plist])
                    let result = remover.remove([RemovalRequest(path: plist, bytes: 0)], mode: .moveToTrash).first
                    record(item, result?.succeeded == true ? .done("Removed") : .failed(result.map(Self.reason) ?? "Failed"))
                } else {
                    let domain = kind == "daemon" ? "system" : "gui/\(environment.userID)"
                    // bootout fails harmlessly when the job isn't loaded, so it must not stop the batch.
                    adminCommands.append(["/bin/sh", "-c", "/bin/launchctl bootout \"$1\" \"$2\" 2>/dev/null; exit 0", "sh", domain, plist])
                    adminCommands.append(["/bin/rm", "-f", plist])
                    _ = label
                    adminItems.append(item)
                }
            case .custom("openLoginItemsSettings", _):
                await openLoginItemsSettings()
                record(item, .done("Opened Login Items settings"))
            default:
                continue
            }
        }

        if !adminCommands.isEmpty {
            let result = administrator(adminCommands)
            for item in adminItems {
                switch result {
                case .success: record(item, .done(item.action == .task(MaintenanceTask.reindexSpotlight.rawValue)
                                                  ? "Reindexing started" : "Done"))
                case .failure(.cancelled): record(item, .failed("Needs your administrator password"))
                case .failure(.failed(let message)): record(item, .failed(message.isEmpty ? "Failed" : message))
                }
            }
        }
        // Keep the order the user saw.
        let order = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.sorted { (order[$0.itemID ?? ""] ?? 0) < (order[$1.itemID ?? ""] ?? 0) }
    }

    func runUserTask(_ task: MaintenanceTask) async -> ActionRecord.Outcome {
        switch task {
        case .thinSnapshots:
            let result = run("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "10000000000", "4"])
            return result.status == 0 ? .done("Snapshots thinned") : .failed(result.output.isEmpty ? "tmutil failed" : result.output)
        case .rebuildLaunchServices:
            let result = run(MaintenanceTask.lsregister, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
            return result.status == 0 ? .done("Rebuilt") : .failed("lsregister failed")
        case .speedUpMail:
            guard let index = MailDatabase.envelopeIndex(home: environment.home) else { return .skipped("Mail isn't set up") }
            guard await quitMail() else { return .skipped("Quit Mail first") }
            if let error = MailDatabase.vacuum(index) { return .failed(error) }
            _ = run("/usr/bin/mdimport", [environment.user("Library/Mail")])
            return .done("Mail database compacted")
        default:
            return .skipped("Needs administrator rights")
        }
    }

    static func reason(_ record: RemovalRecord) -> String {
        switch record.outcome {
        case .skipped(let reason), .failed(let reason): reason
        default: "Failed"
        }
    }
}

public enum Shell {
    /// Runs a program and returns its exit status and combined output.
    public static let run: PerformanceScanner.Run = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `run` with a 30-second limit, for listing commands that should answer at once (`sfltool` can wait for an
    /// approval that never comes).
    public static let quick: PerformanceScanner.Run = { executable, arguments in run(executable, arguments, timeout: 30) }

    /// Like `run`, but stops the program if it hasn't finished after `timeout` seconds (status -2).
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = Locked(Data())
        let reader = DispatchQueue(label: "Shell.output")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            read.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            finished.wait()
            read.wait()
            return (-2, String(decoding: output.withLock { $0 }, as: UTF8.self))
        }
        read.wait()
        return (process.terminationStatus, String(decoding: output.withLock { $0 }, as: UTF8.self))
    }
}
