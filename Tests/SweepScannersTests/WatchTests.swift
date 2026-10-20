import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct BackgroundWatchTests {
    private func item(_ name: String, _ type: BackgroundItem.Kind = .agent, plist: String? = nil, label: String? = nil) -> BackgroundItem {
        BackgroundItem(name: name, developer: "Dev", type: type, enabled: true, identifier: "8." + name,
                       plist: plist ?? "/Users/me/Library/LaunchAgents/\(name).plist", executable: "/opt/\(name)", label: label ?? name)
    }

    @Test func theFirstLookIsTheBaseline() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let first = BackgroundWatch.compare(known: nil, current: [item("a"), item("b")], now: Date()) { _ in created }
        #expect(first.added.isEmpty)
        #expect(first.removed.isEmpty)
        #expect(first.current.map(\.name) == ["a", "b"])
        // Items there before Sweep looked are dated by their plist, not by when Sweep first saw them.
        #expect(first.current.allSatisfy { $0.firstSeen == created })
    }

    @Test func noticesItemsComingAndGoing() {
        let then = Date(timeIntervalSince1970: 1_700_000_000), now = then.addingTimeInterval(3_600)
        let known = BackgroundWatch.compare(known: nil, current: [item("a"), item("b")], now: then) { _ in nil }.current
        let next = BackgroundWatch.compare(known: known, current: [item("b"), item("c"), item("c")], now: now) { _ in nil }
        #expect(next.added.map(\.name) == ["c"])
        #expect(next.added.first?.firstSeen == now)
        #expect(next.removed.map(\.name) == ["a"])
        #expect(next.current.map(\.name) == ["b", "c"], "the same item listed twice is one item")
        #expect(next.current.first?.firstSeen == then, "b keeps the date it was first seen")
        // Login items point at an app rather than a plist.
        var login = item("Chat", .loginItem)
        login.plist = nil
        login.bundlePath = "/Applications/Chat.app"
        let withLogin = BackgroundWatch.compare(known: next.current, current: [item("b"), item("c"), login], now: now) { _ in nil }
        #expect(withLogin.added.first?.kind == .loginItem)
        #expect(withLogin.added.first?.isSwitchable == false)
        #expect(withLogin.added.first?.signedPath == "/Applications/Chat.app")
    }

    @Test func btmLoginItemsKeepTheirApp() {
        let items = BackgroundItems.parse(PerformanceTests.btm, userID: 501, home: "/Users/someone")
        #expect(items.first?.bundlePath == "/Applications/Chat.app/Contents/Library/LoginItems/Helper.app")
        #expect(items.dropFirst().allSatisfy { $0.bundlePath == nil })
    }

    @Test func readsLaunchdState() {
        let list = "PID\tStatus\tLabel\n768\t0\thomebrew.mxcl.redis\n-\t0\tcom.adobe.ccxprocess\n85192\t0\tapplication.com.google.Chrome.1\n"
        #expect(LaunchdState.runningLabels(inList: list) == ["homebrew.mxcl.redis", "application.com.google.Chrome.1"])
        let disabled = """
            \tdisabled services = {
            \t\t"com.docker.helper" => enabled
            \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
            \t\t"com.example.old" => true
            \t}
            """
        #expect(LaunchdState.disabledLabels(in: disabled) == ["com.apple.ManagedClientAgent.enrollagent", "com.example.old"])

        let log = CommandLog(["launchctl list": (0, list), "launchctl print-disabled": (0, disabled),
                              "launchctl print": (0, "\tstate = running\n")])
        let state = LaunchdState.read(userID: 501, systemLabels: ["com.docker.vmnetd"], run: log.run)
        #expect(state.running.contains("com.docker.vmnetd"))
        #expect(state.disabled.contains("com.example.old"))
        #expect(log.recorded.contains(["/bin/launchctl", "print-disabled", "gui/501"]))
        #expect(log.recorded.contains(["/bin/launchctl", "print-disabled", "system"]))
        #expect(log.recorded.allSatisfy { ["list", "print", "print-disabled"].contains($0[1]) }, "only reads")
    }

    private func watched(_ kind: WatchedItem.Kind, label: String? = "com.example.agent") -> WatchedItem {
        WatchedItem(id: "x", name: "Agent", developer: nil, kind: kind, enabled: true, plist: "/Users/me/Library/LaunchAgents/a.plist",
                    executable: nil, label: label, bundlePath: kind == .loginItem ? "/Applications/A.app" : nil, firstSeen: Date())
    }

    @Test func turningAnAgentOffDisablesItForThisUserOnly() {
        let log = CommandLog()
        let toggle = BackgroundItemSwitch(userID: 501, run: log.run, administrator: { _ in Issue.record("no password for an agent"); return .success("") })
        #expect(toggle.set(watched(.agent), on: false) == .done)
        #expect(log.recorded == [["/bin/launchctl", "disable", "gui/501/com.example.agent"],
                                 ["/bin/launchctl", "bootout", "gui/501/com.example.agent"]])
        #expect(toggle.set(watched(.agent), on: true) == .done)
        #expect(log.recorded.suffix(2) == [["/bin/launchctl", "enable", "gui/501/com.example.agent"],
                                           ["/bin/launchctl", "bootstrap", "gui/501", "/Users/me/Library/LaunchAgents/a.plist"]])
        let failing = BackgroundItemSwitch(userID: 501, run: CommandLog(["launchctl disable": (1, "Operation not permitted")]).run,
                                           administrator: { _ in .success("") })
        #expect(failing.set(watched(.agent), on: false) == .failed("Operation not permitted"))
    }

    @Test func daemonsNeedTheAdministratorAndLoginItemsGoToSettings() {
        let commands = LockedCommands()
        let toggle = BackgroundItemSwitch(userID: 501, run: { _, _ in Issue.record("daemons go through the administrator"); return (1, "") },
                                          administrator: { batch in commands.set(batch); return .success("") })
        #expect(toggle.set(watched(.daemon), on: false) == .done)
        #expect(commands.value == [["/bin/launchctl", "disable", "system/com.example.agent"],
                                   ["/bin/launchctl", "bootout", "system/com.example.agent"]])
        let cancelled = BackgroundItemSwitch(userID: 501, run: { _, _ in (0, "") }, administrator: { _ in .failure(.cancelled) })
        #expect(cancelled.set(watched(.daemon), on: false) == .cancelled)
        #expect(toggle.set(watched(.loginItem), on: false) == .needsSystemSettings)
        #expect(toggle.set(watched(.agent, label: nil), on: false) == .needsSystemSettings)
    }

    @Test func signaturesSayWhoMadeAProgram() throws {
        #expect(Signer.check("/bin/ls") == .apple)
        #expect(Signer.check("/nonexistent/program") == .missing)
        let folder = try TestSandbox.newFolder("signer")
        defer { TestSandbox.remove(folder) }
        let script = folder + "/script.sh"
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: URL(fileURLWithPath: script))
        #expect(Signer.check(script) == .unsigned)
        #expect(!Signer.unsigned.isTrusted)
        #expect(Signer.developerID(name: "Example Ltd", team: "ABCDE12345", notarized: true).summary == "Signed by Example Ltd · notarized")
    }
}

final class LockedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    var value: [[String]] { lock.withLock { commands } }
    func set(_ new: [[String]]) { lock.withLock { commands = new } }
}

@Suite struct UpdaterTests {
    private func update(_ bundleID: String, _ version: String = "2.0", source: AppUpdate.Source = .homebrew(token: "x"),
                        path: String? = nil) -> AppUpdate {
        AppUpdate(appPath: path ?? "/Applications/\(bundleID).app", appName: bundleID, bundleID: bundleID, installedVersion: "1.0",
                  newVersion: version, source: source, releaseNotes: nil)
    }

    @Test func ignoredAppsAndSkippedVersionsAreHidden() {
        var ignore = UpdateIgnoreList()
        ignore.apps.insert("com.a")
        ignore.skippedVersions["com.b"] = "2.0"
        let updates = [update("com.a"), update("com.b"), update("com.b", "2.1"), update("com.c")]
        #expect(ignore.filter(updates).map { "\($0.bundleID)@\($0.newVersion)" } == ["com.b@2.1", "com.c@2.0"])
        // Saved and loaded as JSON, the way Updater keeps it.
        let data = try! JSONEncoder().encode(ignore)
        #expect(try! JSONDecoder().decode(UpdateIgnoreList.self, from: data) == ignore)
    }

    @Test func oneUpdatePerAppPreferringHomebrew() {
        let sparkle = AppUpdate.Source.sparkle(download: URL(string: "https://example.com/a.zip")!, edSignature: nil, length: nil)
        let chosen = UpdateChecker.oneEach([update("com.a", source: sparkle), update("com.a", source: .homebrew(token: "a")),
                                            update("com.b", source: sparkle)])
        #expect(chosen.count == 2)
        #expect(chosen.first { $0.bundleID == "com.a" }?.sourceName == "Homebrew")
        let reversed = UpdateChecker.oneEach([update("com.a", source: .homebrew(token: "a")), update("com.a", source: sparkle)])
        #expect(reversed.first?.sourceName == "Homebrew")
    }

    @Test func homebrewCasksAreMatchedByTheAppsTheyInstall() {
        let info = """
            {"casks": [{"token": "visual-studio-code", "artifacts": [{"app": ["Visual Studio Code.app"]}, {"binary": ["code"]}]},
                       {"token": "firefox", "artifacts": [{"app": [{"target": "/Applications/Firefox.app"}]}]}]}
            """
        let bundles = UpdateChecker.appBundles(inInfo: info)
        #expect(bundles["visual-studio-code"] == ["Visual Studio Code.app"])
        #expect(bundles["firefox"] == ["Firefox.app"])
        #expect(UpdateChecker.appBundles(inInfo: "not json").isEmpty)
    }

    @Test func feedsCanLinkTheirReleaseNotes() throws {
        let feed = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
              <item><sparkle:releaseNotesLink>https://example.com/notes/2.1.html</sparkle:releaseNotesLink>
                <enclosure url="https://example.com/2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1"/></item>
              <item><sparkle:releaseNotesLink>file:///etc/passwd</sparkle:releaseNotesLink>
                <enclosure url="https://example.com/2.0.zip" sparkle:version="200"/></item>
            </channel></rss>
            """
        let items = Appcast.parse(Data(feed.utf8))
        #expect(items.first?.notesLink == URL(string: "https://example.com/notes/2.1.html"))
        #expect(items.last?.notesLink == nil, "only web links")
    }

    @Test func releaseNotesBecomeReadableText() {
        let html = """
            <![CDATA[<h2>What&rsquo;s new</h2><style>p{}</style><ul><li>Faster&nbsp;search</li><li>Fixes &amp; tweaks</li></ul>
            <p>Thanks!<br>The team</p>]]>
            """
        #expect(ReleaseNotes.plainText(html) == "What’s new\n\n• Faster search\n• Fixes & tweaks\n\nThanks!\nThe team")
        #expect(ReleaseNotes.plainText("  Plain notes.  ") == "Plain notes.")
        #expect(ReleaseNotes.plainText("<p>It&#8217;s &#x2014; &amp;lt;fine&amp;gt;</p>") == "It’s — &lt;fine&gt;")
    }
}

/// Writes archives shaped like the background item database: a `BTMUserStore` holding `ItemRecord`s.
@objc(SweepTestBTMStore)
final class TestBTMStore: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let records: [TestBTMRecord]
    init(_ records: [TestBTMRecord]) { self.records = records }
    init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) { coder.encode(records as NSArray, forKey: "records") }
}

@objc(SweepTestBTMRecord)
final class TestBTMRecord: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let fields: [String: Any]
    init(_ fields: [String: Any]) { self.fields = fields }
    init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        for (key, value) in fields {
            if let number = value as? Int { coder.encode(number, forKey: key) } else { coder.encode(value, forKey: key) }
        }
    }
}

@Suite struct BackgroundTaskDatabaseTests {
    private func archive(_ records: [[String: Any]]) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("BTMUserStore", for: TestBTMStore.self)
        archiver.setClassName("ItemRecord", for: TestBTMRecord.self)
        archiver.encode(TestBTMStore(records.map(TestBTMRecord.init)), forKey: "userStore")
        archiver.finishEncoding()
        return archiver.encodedData
    }

    @Test func readsTheUsersItemsAndSystemDaemons() throws {
        let folder = try TestSandbox.newFolder("btm")
        defer { TestSandbox.remove(folder) }
        let user = try #require(BackgroundTaskDatabase.uuid(of: getuid()))
        let userRecords: [[String: Any]] = [
            ["identifier": "2.com.example.chat", "name": "Chat", "developerName": "Chat Inc.", "type": 0x2, "disposition": 0x2,
             "url": URL(fileURLWithPath: "/Applications/Chat.app")],
            ["identifier": "4.com.example.chat.helper", "name": "ChatHelper", "container": "2.com.example.chat", "type": 0x4,
             "disposition": 0xb, "url": NSURL(string: "/Contents/Library/LoginItems/ChatHelper.app")!],
            ["identifier": "8.com.example.chat.agent", "name": "Agent", "container": "2.com.example.chat", "type": 0x8,
             "disposition": 0xa, "url": NSURL(string: "/Contents/Library/LaunchAgents/com.example.chat.agent.plist")!,
             "executablePath": "Contents/MacOS/agent"],
            ["identifier": "2.com.example.opener", "name": "Opener", "type": 0x2, "disposition": 0xb,
             "url": URL(fileURLWithPath: "/Applications/Opener.app")],
            ["identifier": "Unknown Developer", "type": 0x20, "disposition": 0x2],
            ["identifier": "8.homebrew.mxcl.redis", "name": "redis-server", "type": 0x10008, "disposition": 0xb,
             "url": URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/homebrew.mxcl.redis.plist"),
             "executablePath": "/opt/homebrew/opt/redis/bin/redis-server"],
            ["identifier": "64.com.example.importer", "name": "Importer.mdimporter", "type": 0x40, "disposition": 0xb],
        ]
        let systemRecords: [[String: Any]] = [
            ["identifier": "16.com.example.daemon", "name": "com.example.daemon", "developerName": "Example", "type": 0x10010,
             "disposition": 0xb, "url": URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.daemon.plist")],
        ]
        try archive(userRecords).write(to: URL(fileURLWithPath: folder + "/BackgroundItems-v18-\(user).btm"))
        try Data("old".utf8).write(to: URL(fileURLWithPath: folder + "/BackgroundItems-v16-\(user).btm"))
        try archive(systemRecords).write(to: URL(fileURLWithPath: folder + "/BackgroundItems-v18-FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE.btm"))

        let items = try #require(BackgroundTaskDatabase.items(userID: getuid(), home: "/Users/me", folder: folder))
        #expect(items.map(\.name) == ["ChatHelper", "Agent", "Opener", "redis-server", "com.example.daemon"])
        let helper = items[0]
        #expect(helper.type == .loginItem)
        #expect(helper.enabled)
        #expect(helper.developer == "Chat Inc.", "taken from the app that contains it")
        #expect(helper.bundlePath == "/Applications/Chat.app/Contents/Library/LoginItems/ChatHelper.app")
        let agent = items[1]
        #expect(agent.type == .agent)
        #expect(!agent.enabled)
        #expect(agent.plist == "/Applications/Chat.app/Contents/Library/LaunchAgents/com.example.chat.agent.plist")
        #expect(agent.executable == "/Applications/Chat.app/Contents/MacOS/agent")
        #expect(agent.label == "com.example.chat.agent")
        #expect(items[2].type == .app, "an app that opens at login")
        #expect(items[3].executable == "/opt/homebrew/opt/redis/bin/redis-server")
        #expect(items[4].type == .daemon)
        #expect(items[4].developer == "Example")
    }

    @Test func withoutADatabaseTheOldSourcesAreUsed() throws {
        let mac = try FakeMac()
        var environment = mac.environment()
        environment.userID = 501
        let log = CommandLog(["sfltool dumpbtm": (0, PerformanceTests.btm)])
        let items = BackgroundItems.list(environment: environment, run: log.run)
        #expect(items.map(\.name) == ["Chat", "redis-server", "Updater"])
        #expect(BackgroundTaskDatabase.items(userID: getuid(), home: "/Users/me", folder: mac.system + "/nothing") == nil)
        let damaged = try TestSandbox.newFolder("btm-damaged")
        defer { TestSandbox.remove(damaged) }
        let user = try #require(BackgroundTaskDatabase.uuid(of: getuid()))
        try Data("not an archive".utf8).write(to: URL(fileURLWithPath: damaged + "/BackgroundItems-v18-\(user).btm"))
        #expect(BackgroundTaskDatabase.items(userID: getuid(), home: "/Users/me", folder: damaged) == nil)
    }
}
