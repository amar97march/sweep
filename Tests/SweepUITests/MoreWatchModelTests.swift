import Foundation
import Testing
@testable import SweepCore
@testable import SweepUI
@testable import SweepMonitor
@testable import SweepScanners

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<250 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite struct AlertsModelTests {
    private final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var cpu: [ProcessCPU] = []
        var accessories: [Accessory] = []
        var trash: [InstalledApp] = []
        var quit: [String] = []
    }

    private let chrome = EnergyApp(key: "com.google.Chrome", name: "Chrome", path: "/Applications/Chrome.app")

    private func model(_ fake: Fake, trash: String? = nil) -> AlertsModel {
        let engine = AlertsModel.Engine(
            readCPU: { fake.lock.withLock { fake.cpu } },
            readAccessories: { fake.lock.withLock { fake.accessories } },
            trashFolder: trash,
            trashedApps: { _ in fake.lock.withLock { fake.trash } },
            leftovers: { app in
                ScanCategory(id: "trashedLeftovers", title: "Left by \(app.name)", summary: "", symbol: "trash",
                             groups: [ScanGroup(id: "g", title: app.name, icon: .symbol("app"),
                                                items: [ScanItem(id: "x", title: "Caches", size: 100, isSelectedByDefault: true,
                                                                 action: .custom(kind: "fake", payload: []))])])
            },
            quit: { app in fake.lock.withLock { fake.quit.append(app.key) } })
        let alerts = AlertsModel(engine: engine, keyPrefix: "test.alerts.\(UUID().uuidString).")
        alerts.runawayMinutes = 2
        alerts.runawayThreshold = 0.8
        return alerts
    }

    @Test func aBusyAppIsFlaggedAndCanBeQuit() async {
        let fake = Fake()
        let alerts = model(fake)
        let start = Date()
        for minute in 0...3 {
            fake.lock.withLock { fake.cpu = [ProcessCPU(pid: 5, started: 1, time: UInt64(minute) * 60_000_000_000, app: chrome)] }
            await alerts.checkCPU(at: start.addingTimeInterval(Double(minute) * 60))
        }
        #expect(alerts.runaways.map(\.app.key) == ["com.google.Chrome"])
        #expect(abs((alerts.runaways.first?.usage ?? 0) - 1) < 0.01)
        alerts.quit(alerts.runaways[0])
        #expect(fake.lock.withLock { fake.quit } == ["com.google.Chrome"])
        #expect(alerts.runaways.isEmpty)
    }

    @Test func accessoriesAreReadAndLowOnesRemembered() async {
        let fake = Fake()
        fake.accessories = [Accessory(name: "Magic Mouse", kind: "Mouse", levels: ["Main": 12])]
        let alerts = model(fake)
        await alerts.refreshAccessories(notify: true)
        #expect(alerts.accessories.map(\.name) == ["Magic Mouse"])
    }

    @Test func trashedAppsLeaveLeftoversToReview() async throws {
        let fake = Fake()
        let folder = try TestFolder()
        let alerts = model(fake, trash: folder.path)
        await alerts.checkTrash()
        #expect(alerts.pendingLeftovers.isEmpty)
        let app = try folder.app("Zoomish", bundleID: "com.example.zoomish")
        fake.lock.withLock { fake.trash = [app] }
        await alerts.checkTrash()
        #expect(alerts.pendingLeftovers.map(\.title) == ["Left by Zoomish"])
        await alerts.checkTrash()
        #expect(alerts.pendingLeftovers.count == 1, "each trashed app once")
        alerts.offersLeftovers = false
        fake.lock.withLock { fake.trash = [app, try! folder.app("Other", bundleID: "com.example.other")] }
        await alerts.checkTrash()
        #expect(alerts.pendingLeftovers.count == 1, "switched off")
        #expect(alerts.takeLeftovers().count == 1)
        #expect(alerts.pendingLeftovers.isEmpty)
    }

    @Test func leftoversOpenInApplicationsForReview() {
        let state = AppState()
        state.alerts.preview(runaways: [], accessories: [], leftovers: [DemoData.alerts.leftovers[0]])
        state.reviewTrashedLeftovers()
        #expect(state.selection == .applications)
        #expect(state.catalog(for: .applications)?.phase == .review)
        #expect(state.catalog(for: .applications)?.categories.map(\.id) == ["trashedLeftovers"])
        #expect(state.catalog(for: .applications)?.selected.count == 2)
        #expect(state.alerts.pendingLeftovers.isEmpty)
    }
}

/// A folder under `.build/test-fixtures` with app bundles in it, deleted afterwards.
final class TestFolder {
    let path: String

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        path = package.appendingPathComponent(".build/test-fixtures/ui-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func app(_ name: String, bundleID: String) throws -> InstalledApp {
        let bundle = path + "/\(name).app"
        try FileManager.default.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": name],
                                                      format: .xml, options: 0)
        try info.write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        return try #require(InstalledApp(path: bundle))
    }
}

@MainActor
@Suite struct SecurityModelTests {
    @Test func problemsComeFirstAndSpeedResultsAreKept() async {
        let checks = [SecurityCheck(id: "a", title: "A", status: .good, detail: ""),
                      SecurityCheck(id: "b", title: "B", status: .warning, detail: ""),
                      SecurityCheck(id: "c", title: "C", status: .problem, detail: "")]
        let result = DiskSpeed.Result(write: 3e9, read: 4e9, date: Date())
        let security = SecurityModel(engine: .init(checks: { checks }, measureSpeed: { result }))
        await security.refreshIfDue()
        #expect(security.problems.map(\.id) == ["c", "b"])
        security.testSpeed()
        await settle { !security.isTestingSpeed }
        #expect(security.speed == result)

        let full = SecurityModel(engine: .init(checks: { [] }, measureSpeed: { throw DiskSpeed.Failure.notEnoughSpace }))
        full.testSpeed()
        await settle { !full.isTestingSpeed }
        #expect(full.speedError == "Needs about 3 GB of free space.")
    }
}

@MainActor
@Suite struct TweaksModelTests {
    private final class Writes: @unchecked Sendable {
        let lock = NSLock()
        var log: [String] = []
        var fail = false
    }

    @Test func changesAreRememberedAndRelaunchedOnRequest() async throws {
        let writes = Writes()
        let tweaks = TweaksModel(engine: .init(choice: { tweak in tweak.choices.firstIndex { $0.value == nil } ?? 0 },
                                                set: { tweak, choice in
                                                    writes.lock.withLock {
                                                        writes.log.append("\(tweak.id)=\(choice)")
                                                        return !writes.fail
                                                    }
                                                },
                                                relaunch: { process in writes.lock.withLock { writes.log.append("relaunch \(process)") } }))
        await tweaks.load()
        let hidden = try #require(Tweak.all.first { $0.id == "finderHidden" })
        let dock = try #require(Tweak.all.first { $0.id == "dockNoDelay" })
        #expect(tweaks.choice(hidden) == 1)
        tweaks.set(hidden, choice: 0)
        tweaks.set(dock, choice: 0)
        #expect(tweaks.choice(hidden) == 0)
        #expect(tweaks.needsRelaunch == ["Finder", "Dock"])
        tweaks.relaunch()
        #expect(writes.lock.withLock { writes.log }.suffix(2) == ["relaunch Dock", "relaunch Finder"])
        #expect(tweaks.needsRelaunch.isEmpty)

        tweaks.restoreAll()
        #expect(tweaks.choice(hidden) == 1)
        #expect(tweaks.choice(dock) == 1)

        writes.lock.withLock { writes.fail = true }
        tweaks.set(hidden, choice: 0)
        #expect(tweaks.failure == "Couldn't change \"Show hidden files\".")
        #expect(tweaks.choice(hidden) == 1)
    }
}

@MainActor
@Suite struct ActivityMoreTests {
    @Test func networkPrivacyAndBatteryHealthAreRecorded() async {
        let chrome = EnergyApp(key: "com.google.Chrome", name: "Chrome", path: nil)
        let counter = Counter()
        let watcher = KeyboardWatcher(pid: 9, executable: "/Applications/Typer.app/Contents/MacOS/Typer",
                                      app: EnergyApp(key: "typer", name: "Typer", path: "/Applications/Typer.app"), listenOnly: true, enabled: true)
        var engine = ActivityModel.Engine.inert
        engine.readTraffic = {
            let step = counter.next()
            return ([ProcessTraffic(pid: 3, name: "chrome", bytesIn: UInt64(step) * 1_000, bytesOut: UInt64(step) * 10)], [3: chrome])
        }
        engine.isOnExpensiveNetwork = { true }
        engine.batteryHealth = { (0.87, 412) }
        engine.permissions = { [TCCPermissions.Entry(service: "kTCCServiceCamera", client: "us.zoom.xos"),
                                TCCPermissions.Entry(service: "kTCCServiceSystemPolicyAllFiles", client: "com.apple.Terminal"),
                                TCCPermissions.Entry(service: "kTCCServiceSystemPolicyAllFiles", client: "com.example.a")] }
        engine.keyboardWatchers = { [watcher] }
        engine.signer = { _ in .unsigned }
        let activity = ActivityModel(engine: engine, storagePrefix: "test.\(UUID().uuidString).")
        let now = Date()
        await activity.sampleEnergy(at: now)
        await activity.sampleEnergy(at: now.addingTimeInterval(300))
        #expect(activity.networkUsage.first?.app == chrome)
        #expect(activity.networkUsage.first?.received == 1_000)
        #expect(activity.onExpensiveNetwork)
        #expect(activity.network.usage(since: now.addingTimeInterval(-60), expensiveOnly: true).first?.total == 1_010)
        #expect(activity.batteryHealth.entries.map(\.health) == [0.87], "once a day")

        await activity.refreshPrivacy()
        #expect(activity.keyboardWatchers == [watcher])
        #expect(activity.signers["/Applications/Typer.app"] == .unsigned)
        #expect(activity.permissionsByService.map(\.service) == ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceCamera"],
                "most sensitive first")
        #expect(activity.permissionsByService.first?.clients == ["com.apple.Terminal", "com.example.a"])
        activity.clearNetworkHistory()
        #expect(activity.networkUsage.isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
