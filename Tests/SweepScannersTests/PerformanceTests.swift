import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

/// Every command goes through a stub: nothing real runs, nothing outside the sandbox changes.
final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let responses: [String: (Int32, String)]

    init(_ responses: [String: (Int32, String)] = [:]) { self.responses = responses }

    var run: PerformanceScanner.Run {
        { executable, arguments in
            self.lock.withLock { self.calls.append([executable] + arguments) }
            let key = ([(executable as NSString).lastPathComponent] + arguments.prefix(1)).joined(separator: " ")
            return self.responses[key] ?? (0, "")
        }
    }

    var recorded: [[String]] { lock.withLock { calls } }
}

@Suite struct PerformanceTests {
    static let btm = """
        ========================
         Records for UID 0 : FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000
        ========================
         Items:
         #1:
                         Name: rootthing
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 16.com.root.thing
                          URL: /Library/LaunchDaemons/com.root.thing.plist
        ========================
         Records for UID 501 : 11111111-2222-3333-4444-555555555555
        ========================
         Items:
         #1:
                         Name: Chat
               Developer Name: Chat Inc.
                         Type: login item (0x4)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 4.com.chat.helper
                          URL: file:///Applications/Chat.app/Contents/Library/LoginItems/Helper.app/
         #2:
                         Name: redis-server
               Developer Name: (null)
                         Type: legacy agent (0x10008)
                  Disposition: [disabled, allowed, notified] (0xa)
                   Identifier: 8.homebrew.mxcl.redis
                          URL: /Users/501/Library/LaunchAgents/homebrew.mxcl.redis.plist
              Executable Path: /opt/homebrew/opt/redis/bin/redis-server
            Parent Identifier: Unknown Developer
         #3:
                         Name: Updater
               Developer Name: Big Vendor
                         Type: legacy daemon (0x10010)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 16.com.bigvendor.updater
                          URL: /Library/LaunchDaemons/com.bigvendor.updater.plist
        """

    @Test func parsesOnlyTheCurrentUsersBackgroundItems() {
        let items = BackgroundItems.parse(Self.btm, userID: 501, home: "/Users/someone")
        #expect(items.map(\.name) == ["Chat", "redis-server", "Updater"])
        #expect(items[0].type == .loginItem && items[0].enabled && items[0].developer == "Chat Inc.")
        #expect(items[1].type == .agent && !items[1].enabled)
        #expect(items[1].plist == "/Users/someone/Library/LaunchAgents/homebrew.mxcl.redis.plist")
        #expect(items[1].developer == nil)
        #expect(items[2].type == .daemon && items[2].developer == "Big Vendor")
    }

    @Test func offersOnlyTasksThisMacSupports() throws {
        let mac = try FakeMac()
        let purge = try mac.systemFile("/usr/sbin/purge", bytes: 10)
        chmod(purge, 0o755)
        let commands = CommandLog(["tmutil listlocalsnapshots": (0, "com.apple.TimeMachine.2026-10-01-000000.local")])
        var environment = mac.environment()
        environment.userID = 501
        let categories = PerformanceScanner(environment: environment, run: commands.run).scan()
        let tasks = try #require(categories.category("maintenance")).groups.flatMap(\.items).map(\.title)

        #expect(tasks.contains("Free Up RAM"))
        #expect(tasks.contains("Thin Time Machine Snapshots"))
        #expect(!tasks.contains("Run Maintenance Scripts"))  // no /usr/sbin/periodic here
        #expect(!tasks.contains("Speed Up Mail"))            // no Mail database here
        #expect(commands.recorded.allSatisfy { ["/usr/bin/tmutil", "/usr/bin/sfltool"].contains($0[0]) })
    }

    @Test func recentlyRunTasksAreNotRecommendedAgain() throws {
        let mac = try FakeMac()
        let categories = PerformanceScanner(environment: mac.environment(), recentlyRun: ["flushDNS"],
                                            run: CommandLog().run).scan()
        let flush = try #require(categories.allItems.first { $0.title == "Flush DNS Cache" })
        #expect(!flush.isSelectedByDefault)
    }

    @Test func rootTasksShareOnePasswordPrompt() async throws {
        let mac = try FakeMac()
        let batches = Locked<[[[String]]]>([])
        var performer = PerformancePerformer(environment: mac.environment())
        performer.run = CommandLog().run
        performer.remover = mac.remover
        performer.administrator = { commands in batches.withLock { $0.append(commands) }; return .success("") }
        let items = [MaintenanceTask.flushDNS, .freeUpRAM, .thinSnapshots].map { task in
            ScanItem(id: task.rawValue, title: task.title, size: 0, isSelectedByDefault: true, action: .task(task.rawValue))
        }
        let records = await performer.perform(items)

        #expect(batches.withLock { $0 }.count == 1)
        #expect(batches.withLock { $0 }.first?.map { $0[0] } == ["/usr/bin/dscacheutil", "/usr/bin/killall", "/usr/sbin/purge"])
        #expect(records.map(\.title) == ["Flush DNS Cache", "Free Up RAM", "Thin Time Machine Snapshots"])
        #expect(records.allSatisfy { $0.succeeded })
    }

    @Test func cancelledPasswordPromptIsReported() async throws {
        let mac = try FakeMac()
        var performer = PerformancePerformer(environment: mac.environment())
        performer.run = CommandLog().run
        performer.administrator = { _ in .failure(.cancelled) }
        let item = ScanItem(id: "x", title: "Flush DNS Cache", size: 0, isSelectedByDefault: true, action: .task("flushDNS"))
        let records = await performer.perform([item])
        #expect(records.first?.outcome == .failed("Needs your administrator password"))
    }

    @Test func removesUserBackgroundItemsWithoutAPassword() async throws {
        let mac = try FakeMac()
        let plist = try mac.plist("Library/LaunchAgents/com.example.agent.plist", ["Label": "com.example.agent"])
        let commands = CommandLog()
        var performer = PerformancePerformer(environment: mac.environment())
        performer.run = commands.run
        performer.remover = mac.remover
        performer.administrator = { _ in Issue.record("must not prompt"); return .failure(.cancelled) }
        let item = ScanItem(id: "bg", title: "agent", size: 0, isSelectedByDefault: false,
                            action: .custom(kind: "removeBackgroundItem", payload: [plist, "com.example.agent", "agent", "user"]))
        let records = await performer.perform([item])

        #expect(records.first?.outcome == .done("Removed"))
        #expect(!FileManager.default.fileExists(atPath: plist))
        #expect(commands.recorded.first?.prefix(2) == ["/bin/launchctl", "bootout"])
    }

    @Test func systemBackgroundItemsGoThroughTheAdministratorBatch() async throws {
        let mac = try FakeMac()
        let batches = Locked<[[[String]]]>([])
        var performer = PerformancePerformer(environment: mac.environment())
        performer.run = CommandLog().run
        performer.administrator = { commands in batches.withLock { $0.append(commands) }; return .success("") }
        let plist = "/Library/LaunchDaemons/com.bigvendor.updater.plist"
        let item = ScanItem(id: "bg", title: "Updater", size: 0, isSelectedByDefault: false,
                            action: .custom(kind: "removeBackgroundItem", payload: [plist, "com.bigvendor.updater", "daemon", "system"]))
        _ = await performer.perform([item])
        let commands = try #require(batches.withLock { $0 }.first)
        #expect(commands.contains(["/bin/rm", "-f", plist]))
        #expect(commands.contains { $0.first == "/bin/sh" && $0.contains("system") && $0.contains(plist) })
    }

    @Test func sameItemTwiceDoesNotCrashOrRepeat() async throws {
        let mac = try FakeMac()
        var performer = PerformancePerformer(environment: mac.environment())
        performer.run = CommandLog().run
        performer.administrator = { _ in .success("") }
        let item = ScanItem(id: "thin", title: "Thin", size: 0, isSelectedByDefault: true, action: .task("thinSnapshots"))
        let records = await performer.perform([item, item])
        #expect(!records.isEmpty)
    }

    @Test func backgroundItemsListedTwiceShowOnce() throws {
        let mac = try FakeMac()
        let plist = try mac.plist("Library/LaunchAgents/com.example.agent.plist", ["Label": "com.example.agent", "Program": "/bin/true"])
        let item = BackgroundItem(name: "Agent", developer: "Example", type: .agent, enabled: true, identifier: "com.example.agent",
                                  plist: plist, executable: "/bin/true", label: "com.example.agent")
        let category = try #require(PerformanceScanner(environment: mac.environment()).backgroundItems([item, item]))
        #expect(category.groups.flatMap(\.items).count == 1)
    }

    @Test func agentsInsideAppsAreNeverOfferedForRemoval() throws {
        let mac = try FakeMac()
        let embedded = BackgroundItem(name: "Helper", developer: "Example", type: .agent, enabled: true, identifier: "8.com.example.helper",
                                      plist: "/Applications/Example.app/Contents/Library/LaunchAgents/com.example.helper.plist",
                                      executable: nil, label: "com.example.helper")
        #expect(PerformanceScanner(environment: mac.environment()).backgroundItems([embedded]) == nil)
    }
}
