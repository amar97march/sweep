import Foundation
import SQLite3
import SweepCore

/// Browsing traces for Safari, Chromium-family browsers and Firefox.
public struct BrowserPrivacy: Sendable {
    public enum Engine: String, Sendable { case chromium, firefox, safari }

    public enum Kind: String, Sendable, CaseIterable {
        case history, downloads, cookies, autofill, session

        var title: String {
            switch self {
            case .history: "Browsing History"
            case .downloads: "Download History"
            case .cookies: "Cookies"
            case .autofill: "Autofill Form Data"
            case .session: "Last Session Tabs"
            }
        }
    }

    struct Browser {
        let name: String
        let bundleID: String
        let engine: Engine
        let root: String
    }

    public let environment: ScanEnvironment

    public init(environment: ScanEnvironment) { self.environment = environment }

    var browsers: [Browser] {
        let chromium: [(String, String, String)] = [
            ("Google Chrome", "com.google.Chrome", "Library/Application Support/Google/Chrome"),
            ("Microsoft Edge", "com.microsoft.edgemac", "Library/Application Support/Microsoft Edge"),
            ("Brave", "com.brave.Browser", "Library/Application Support/BraveSoftware/Brave-Browser"),
            ("Arc", "company.thebrowser.Browser", "Library/Application Support/Arc/User Data"),
            ("Vivaldi", "com.vivaldi.Vivaldi", "Library/Application Support/Vivaldi"),
            ("Chromium", "org.chromium.Chromium", "Library/Application Support/Chromium"),
            ("Opera", "com.operasoftware.Opera", "Library/Application Support/com.operasoftware.Opera"),
        ]
        return chromium.map { Browser(name: $0.0, bundleID: $0.1, engine: .chromium, root: environment.user($0.2)) }
            + [Browser(name: "Firefox", bundleID: "org.mozilla.firefox", engine: .firefox,
                       root: environment.user("Library/Application Support/Firefox/Profiles")),
               Browser(name: "Safari", bundleID: "com.apple.Safari", engine: .safari, root: environment.user("Library/Safari"))]
    }

    public func category() -> ScanCategory? {
        let appPaths = AppCatalog.paths(AppCatalog.installed(in: environment))
        var groups: [ScanGroup] = []
        for browser in browsers {
            for (profileName, profile) in profiles(of: browser) {
                let items = traces(browser, profile: profile)
                guard !items.isEmpty else { continue }
                let icon: ItemIcon = appPaths[browser.bundleID.lowercased()].map { .file($0) } ?? .symbol("globe")
                groups.append(ScanGroup(id: "browser:\(browser.bundleID):\(profile)", title: browser.name,
                                        subtitle: profileName, icon: icon, items: items))
            }
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "browsers", title: "Browsing Data",
                            summary: "History, cookies and form data your browsers keep. The browser is closed before cleaning.",
                            symbol: "safari.fill", groups: groups)
    }

    func profiles(of browser: Browser) -> [(String, String)] {
        let fm = FileManager.default
        switch browser.engine {
        case .chromium:
            if fm.fileExists(atPath: browser.root + "/History") { return [("Default profile", browser.root)] }
            return ((try? fm.contentsOfDirectory(atPath: browser.root)) ?? []).sorted()
                .filter { ($0 == "Default" || $0.hasPrefix("Profile ")) && fm.fileExists(atPath: browser.root + "/" + $0 + "/History") }
                .map { ($0 == "Default" ? "Default profile" : $0, browser.root + "/" + $0) }
        case .firefox:
            return ((try? fm.contentsOfDirectory(atPath: browser.root)) ?? []).sorted()
                .filter { fm.fileExists(atPath: browser.root + "/" + $0 + "/places.sqlite") }
                .map { ("Profile " + ($0.split(separator: ".").last.map(String.init) ?? $0), browser.root + "/" + $0) }
        case .safari:
            return fm.fileExists(atPath: browser.root) ? [("Safari", browser.root)] : []
        }
    }

    func traces(_ browser: Browser, profile: String) -> [ScanItem] {
        var items: [ScanItem] = []
        func add(_ kind: Kind, count: Int?, unit: String, note: String? = nil) {
            guard note != nil || (count ?? 0) > 0 else { return }
            items.append(ScanItem(
                id: "privacy:\(browser.bundleID):\(profile):\(kind.rawValue)", title: kind.title,
                subtitle: count.map { "\($0.formatted()) \(unit)" } ?? note, size: 0, isSelectedByDefault: false,
                action: .custom(kind: "browserData", payload: [browser.engine.rawValue, kind.rawValue, profile, browser.bundleID, browser.name]),
                note: count == nil ? note : nil))
        }
        switch browser.engine {
        case .chromium:
            add(.history, count: SQLite.count(profile + "/History", "SELECT COUNT(*) FROM visits"), unit: "visits")
            add(.downloads, count: SQLite.count(profile + "/History", "SELECT COUNT(*) FROM downloads"), unit: "downloads")
            let cookies = [profile + "/Network/Cookies", profile + "/Cookies"].first(where: FileManager.default.fileExists)
            add(.cookies, count: cookies.flatMap { SQLite.count($0, "SELECT COUNT(*) FROM cookies") }, unit: "cookies")
            add(.autofill, count: SQLite.count(profile + "/Web Data", "SELECT COUNT(*) FROM autofill"), unit: "entries")
            let sessions = ((try? FileManager.default.contentsOfDirectory(atPath: profile + "/Sessions")) ?? []).count
            add(.session, count: sessions, unit: "session files")
        case .firefox:
            add(.history, count: SQLite.count(profile + "/places.sqlite", "SELECT COUNT(*) FROM moz_historyvisits"), unit: "visits")
            add(.cookies, count: SQLite.count(profile + "/cookies.sqlite", "SELECT COUNT(*) FROM moz_cookies"), unit: "cookies")
            add(.autofill, count: SQLite.count(profile + "/formhistory.sqlite", "SELECT COUNT(*) FROM moz_formhistory"), unit: "entries")
            let session = ["sessionstore.jsonlz4", "sessionstore-backups"].filter { FileManager.default.fileExists(atPath: profile + "/" + $0) }.count
            add(.session, count: session, unit: "session files")
        case .safari:
            let history = profile + "/History.db"
            if FileManager.default.fileExists(atPath: history) {
                if let count = SQLite.count(history, "SELECT COUNT(*) FROM history_visits") {
                    add(.history, count: count, unit: "visits")
                } else {
                    add(.history, count: nil, unit: "", note: "Needs Full Disk Access")
                }
            }
            let cookies = environment.user("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            if FileManager.default.fileExists(atPath: cookies) { add(.cookies, count: 1, unit: "cookie store") }
            if FileManager.default.fileExists(atPath: profile + "/LastSession.plist") { add(.session, count: 1, unit: "saved session") }
        }
        return items
    }

    /// Removes one kind of browsing data. The browser must not be running.
    public static func clear(engine: Engine, kind: Kind, profile: String, home: String) -> String? {
        switch (engine, kind) {
        case (.chromium, .history):
            return SQLite.execute(profile + "/History", "DELETE FROM visits; DELETE FROM urls; DELETE FROM keyword_search_terms; DELETE FROM segments; DELETE FROM segment_usage;")
        case (.chromium, .downloads):
            return SQLite.execute(profile + "/History", "DELETE FROM downloads; DELETE FROM downloads_url_chains;")
        case (.chromium, .cookies):
            let path = [profile + "/Network/Cookies", profile + "/Cookies"].first(where: FileManager.default.fileExists)
            return path.flatMap { SQLite.execute($0, "DELETE FROM cookies;") }
        case (.chromium, .autofill):
            return SQLite.execute(profile + "/Web Data", "DELETE FROM autofill;")
        case (.chromium, .session):
            return removeContents(profile + "/Sessions")
        case (.firefox, .history):
            return SQLite.execute(profile + "/places.sqlite",
                                  "DELETE FROM moz_historyvisits; DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL);")
        case (.firefox, .cookies):
            return SQLite.execute(profile + "/cookies.sqlite", "DELETE FROM moz_cookies;")
        case (.firefox, .autofill):
            return SQLite.execute(profile + "/formhistory.sqlite", "DELETE FROM moz_formhistory;")
        case (.firefox, .session):
            for name in ["sessionstore.jsonlz4", "sessionstore-backups"] { try? FileManager.default.removeItem(atPath: profile + "/" + name) }
            return nil
        case (.safari, .history):
            return SQLite.execute(profile + "/History.db", "DELETE FROM history_visits; DELETE FROM history_items;")
        case (.safari, .cookies):
            let path = home + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
            do { try FileManager.default.removeItem(atPath: path); return nil } catch { return error.localizedDescription }
        case (.safari, .session):
            do { try FileManager.default.removeItem(atPath: profile + "/LastSession.plist"); return nil } catch { return error.localizedDescription }
        default:
            return "Not supported for this browser"
        }
    }

    private static func removeContents(_ folder: String) -> String? {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            do { try FileManager.default.removeItem(atPath: folder + "/" + name) } catch { return error.localizedDescription }
        }
        return nil
    }
}

enum SQLite {
    /// A single integer from `query`, read without taking locks (works while the browser is open).
    static func count(_ path: String, _ query: String) -> Int? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : nil
    }

    /// Runs statements in one transaction. Returns an error message, or nil on success.
    static func execute(_ path: String, _ sql: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            return String(cString: sqlite3_errmsg(database))
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)
        guard sqlite3_exec(database, "BEGIN; " + sql + " COMMIT;", nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            return message
        }
        return nil
    }
}

/// Quarantines threats, clears privacy data, revokes permissions, forgets Wi-Fi networks.
public struct ProtectionPerformer: Sendable {
    public var environment: ScanEnvironment
    public var quarantineFolder = Quarantine.defaultFolder
    public var run: PerformanceScanner.Run = Shell.run
    public var administrator: @Sendable ([[String]]) -> Result<String, Administrator.Failure> = Administrator.runBatch
    /// Quits the app with a bundle identifier; false if it's still running.
    public var quitApp: @Sendable (String) async -> Bool = { _ in true }
    public var startupItems: PerformancePerformer

    public init(environment: ScanEnvironment) {
        self.environment = environment
        startupItems = PerformancePerformer(environment: environment)
    }

    public func perform(_ items: [ScanItem], progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> [ActionRecord] {
        var records: [ActionRecord] = []
        var wifi: [ScanItem] = []
        var quitBrowsers: [String: Bool] = [:]
        var clearedRecents = false
        func record(_ item: ScanItem, _ outcome: ActionRecord.Outcome) {
            records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: item.size, outcome: outcome))
        }
        for (index, item) in items.enumerated() {
            defer { progress(index + 1, items.count) }
            guard case .custom(let kind, let payload) = item.action else { continue }
            switch kind {
            case "quarantine" where payload.count == 2:
                do {
                    _ = try Quarantine.move(payload[0], threat: payload[1], folder: quarantineFolder)
                    record(item, .done("Quarantined"))
                } catch {
                    record(item, .failed(error.localizedDescription))
                }
            case "browserData" where payload.count == 5:
                guard let engine = BrowserPrivacy.Engine(rawValue: payload[0]), let dataKind = BrowserPrivacy.Kind(rawValue: payload[1]) else { continue }
                let bundleID = payload[3]
                if quitBrowsers[bundleID] == nil { quitBrowsers[bundleID] = await quitApp(bundleID) }
                guard quitBrowsers[bundleID] == true else { record(item, .skipped("Quit \(payload[4]) first")); continue }
                if let error = BrowserPrivacy.clear(engine: engine, kind: dataKind, profile: payload[2], home: environment.home) {
                    record(item, .failed(error))
                } else {
                    record(item, .done("Cleared"))
                }
            case "clearRecent" where payload.count == 1:
                do {
                    try FileManager.default.removeItem(atPath: payload[0])
                    clearedRecents = true
                    record(item, .done("Cleared"))
                } catch {
                    record(item, .failed(error.localizedDescription))
                }
            case "revokePermission" where payload.count == 2:
                let service = payload[0].replacingOccurrences(of: "kTCCService", with: "")
                let result = run("/usr/bin/tccutil", ["reset", service, payload[1]])
                record(item, result.status == 0 ? .done("Access revoked") : .failed(result.output.isEmpty ? "tccutil failed" : result.output))
            case "forgetWiFi" where payload.count == 2:
                wifi.append(item)
            case "removeBackgroundItem":
                records += await startupItems.perform([item])
            default:
                continue
            }
        }
        if clearedRecents { _ = run("/usr/bin/killall", ["sharedfilelistd"]) }  // reloads the now-empty lists
        if !wifi.isEmpty {
            let commands = wifi.compactMap { item -> [String]? in
                guard case .custom(_, let payload) = item.action else { return nil }
                return ["/usr/sbin/networksetup", "-removepreferredwirelessnetwork", payload[0], payload[1]]
            }
            let result = administrator(commands)
            for item in wifi {
                switch result {
                case .success: record(item, .done("Forgotten"))
                case .failure(.cancelled): record(item, .failed("Needs your administrator password"))
                case .failure(.failed(let message)): record(item, .failed(message))
                }
            }
        }
        return records
    }
}
