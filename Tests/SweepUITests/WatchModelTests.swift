import Foundation
import Testing
@testable import SweepCore
@testable import SweepUI
import SweepMonitor
@testable import SweepScanners

/// Records what a stand-in engine was asked to do.
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var all: [String] { lock.withLock { entries } }
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<250 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite struct UpdaterModelTests {
    private func update(_ name: String, _ source: AppUpdate.Source) -> AppUpdate {
        AppUpdate(appPath: "/Applications/\(name).app", appName: name, bundleID: "com.example.\(name)", installedVersion: "1.0",
                  newVersion: "2.0", source: source, releaseNotes: nil)
    }

    private var sparkle: AppUpdate.Source { .sparkle(download: URL(string: "https://example.com/a.zip")!, edSignature: nil, length: nil) }
    private var store: AppUpdate.Source { .appStore(page: URL(string: "https://apps.apple.com/app/x")!) }

    private func model(_ updates: [AppUpdate], calls: Calls, running: Set<String> = [], failing: Set<String> = []) -> UpdaterModel {
        let engine = UpdaterModel.Engine(check: {
            calls.add("check")
            return updates
        }, install: { update in
            calls.add("install " + update.appName)
            return failing.contains(update.appName) ? .failed("Nope") : .done("Updated to \(update.newVersion)")
        }, isRunning: { running.contains($0.appName) },
           relaunch: { calls.add("relaunch " + $0.appName) },
           openAppStoreUpdates: { calls.add("open App Store updates") })
        return UpdaterModel(engine: engine, keyPrefix: "test.updater.\(UUID().uuidString).")
    }

    @Test func checkingShowsWhatWasFound() async {
        let calls = Calls()
        let updater = model([update("A", sparkle), update("B", .homebrew(token: "b"))], calls: calls)
        #expect(updater.phase == .intro)
        #expect(!updater.hasChecked)
        updater.check()
        #expect(updater.phase == .checking)
        await waitUntil { updater.phase == .ready }
        #expect(updater.updates.map(\.appName) == ["A", "B"])
        #expect(updater.outstanding.count == 2)
        #expect(updater.lastChecked != nil)
        #expect(updater.hasChecked)
    }

    @Test func updateAllInstallsEachAndOpensTheAppStoreOnce() async {
        let calls = Calls()
        let updates = [update("A", sparkle), update("Pages", store), update("Numbers", store), update("Brew", .homebrew(token: "b"))]
        let updater = model(updates, calls: calls, running: ["A", "Brew"], failing: ["Brew"])
        updater.show(updates, checkedAt: Date())
        #expect(updater.runningApps(in: updates).map(\.appName) == ["A", "Brew"], "App Store apps aren't quit by Sweep")
        updater.updateAll()
        #expect(updater.isUpdating)
        await waitUntil { !updater.isUpdating }
        #expect(calls.all.filter { $0 == "open App Store updates" }.count == 1)
        #expect(!calls.all.contains("install Pages"))
        #expect(calls.all.contains("install A"))
        #expect(calls.all.contains("relaunch A"), "an app that was open is reopened after updating")
        #expect(!calls.all.contains("relaunch Brew"), "not after a failed update")
        #expect(updater.states[updates[0].id] == .done("Updated to 2.0"))
        #expect(updater.states[updates[1].id] == .done("Opened in the App Store"))
        #expect(updater.states[updates[3].id] == .failed("Nope"))
        #expect(updater.outstanding.map(\.appName) == ["Brew"], "a failed update can be tried again")
    }

    @Test func aSingleAppStoreUpdateOpensItsPage() async {
        let calls = Calls()
        let pages = update("Pages", store)
        let updater = model([pages], calls: calls)
        updater.show([pages], checkedAt: Date())
        updater.update(pages)
        await waitUntil { !updater.isUpdating }
        #expect(calls.all == ["install Pages"])
    }

    @Test func ignoringHidesAnAppOrOneVersion() {
        let updater = model([], calls: Calls())
        let a = update("A", sparkle), b = update("B", sparkle)
        updater.show([a, b], checkedAt: Date())
        updater.skipVersion(a)
        #expect(updater.updates.map(\.appName) == ["B"])
        #expect(updater.ignored.map(\.appName) == ["A"])
        updater.ignoreApp(b)
        #expect(updater.updates.isEmpty)
        updater.stopIgnoring(a)
        updater.stopIgnoring(b)
        #expect(updater.updates.count == 2)
        #expect(updater.ignoreList == UpdateIgnoreList())
    }

    @Test func theDailyCheckRunsOncePerDayAndOnlyWhenOn() async {
        let calls = Calls()
        let updater = model([update("A", sparkle)], calls: calls)
        let now = Date()
        await updater.checkInBackgroundIfDue(now: now)
        await updater.checkInBackgroundIfDue(now: now.addingTimeInterval(3_600))
        #expect(calls.all == ["check"])
        updater.checksDaily = false
        await updater.checkInBackgroundIfDue(now: now.addingTimeInterval(2 * 86_400))
        #expect(calls.all == ["check"])
    }
}

@MainActor
@Suite struct ActivityModelTests {
    private func item(_ name: String) -> BackgroundItem {
        BackgroundItem(name: name, developer: "Dev", type: .agent, enabled: true, identifier: "8." + name,
                       plist: "/Users/me/Library/LaunchAgents/\(name).plist", executable: "/opt/\(name)", label: "com.example.\(name)")
    }

    private final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var items: [BackgroundItem] = []
        var changes: [SensorLog.Change] = []
        var energy: [ProcessEnergy] = []
        var switched: [String] = []
        var outcome = BackgroundItemSwitch.Outcome.done
        var disabled: Set<String> = []
    }

    private func model(_ fake: Fake) -> ActivityModel {
        let engine = ActivityModel.Engine(
            readSensorLog: { _ in fake.lock.withLock { fake.changes } },
            liveSensors: { (["com.example.Recorder"], true) },
            listBackgroundItems: { fake.lock.withLock { fake.items } },
            launchdState: { _ in LaunchdState(running: ["com.example.a"], disabled: fake.lock.withLock { fake.disabled }) },
            signer: { $0.contains("bad") ? .unsigned : .developerID(name: "Dev", team: nil, notarized: true) },
            switchItem: { item, on in
                fake.lock.withLock {
                    fake.switched.append("\(item.name) \(on ? "on" : "off")")
                    return fake.outcome
                }
            },
            readEnergy: { fake.lock.withLock { fake.energy } },
            battery: { (0.5, true, true) },
            bootTime: { nil })
        return ActivityModel(engine: engine, storagePrefix: "test.\(UUID().uuidString).")
    }

    @Test func newBackgroundItemsAreFlaggedUntilReviewed() async {
        let fake = Fake()
        fake.items = [item("a"), item("bad")]
        let activity = model(fake)
        await activity.refreshBackground(notify: false)
        #expect(activity.backgroundItems.count == 2)
        #expect(activity.unreviewed.isEmpty, "the first look is the baseline")
        #expect(activity.backgroundChanges.isEmpty)
        #expect(activity.signer(for: activity.backgroundItems[1]) == .unsigned)
        #expect(activity.isRunning(activity.backgroundItems[0]))

        fake.lock.withLock { fake.items = [item("a"), item("c")] }
        await activity.refreshBackground(notify: false)
        #expect(activity.unreviewed == [activity.backgroundItems.first { $0.name == "c" }!.id])
        #expect(activity.backgroundChanges.map { "\($0.kind) \($0.item.name)" } == ["added c", "removed bad"])
        activity.markReviewed()
        #expect(activity.unreviewed.isEmpty)

        // A failed listing (nothing at all) isn't taken to mean everything was removed.
        fake.lock.withLock { fake.items = [] }
        await activity.refreshBackground(notify: false)
        #expect(activity.backgroundItems.count == 2)
    }

    @Test func switchingAnItemReportsFailures() async {
        let fake = Fake()
        fake.items = [item("a")]
        let activity = model(fake)
        await activity.refreshBackground(notify: false)
        let a = activity.backgroundItems[0]
        #expect(activity.isOn(a))
        fake.lock.withLock { fake.disabled = ["com.example.a"] }
        activity.setItem(a, on: false)
        await waitUntil { activity.switching.isEmpty && !fake.lock.withLock({ fake.switched }).isEmpty }
        await waitUntil { !activity.isOn(a) }
        #expect(fake.lock.withLock { fake.switched } == ["a off"])
        #expect(!activity.isOn(a), "launchd now lists it as disabled")
        fake.lock.withLock { fake.outcome = .failed("Not permitted") }
        activity.setItem(a, on: true)
        await waitUntil { activity.switchMessage != nil }
        #expect(activity.switchMessage == "Couldn't turn on a: Not permitted")
    }

    @Test func importsCameraAndMicrophoneUse() async {
        let fake = Fake()
        let now = Date()
        let cam = SensorUse(sensor: .camera, bundleID: "us.zoom.xos"), mic = SensorUse(sensor: .microphone, bundleID: "us.zoom.xos")
        fake.changes = [.init(date: now.addingTimeInterval(-600), active: [cam, mic]), .init(date: now.addingTimeInterval(-300), active: [mic])]
        let activity = model(fake)
        await activity.importSensorUse(notify: false)
        #expect(activity.sensors.sessions.count == 2)
        #expect(activity.sensors.inUse.map(\.use) == [mic])
        await activity.refreshLive()
        #expect(activity.cameraOn)
        let apps = activity.inUseByApp
        #expect(apps.map(\.bundleID) == ["com.example.Recorder", "us.zoom.xos"])
        #expect(ActivityModel.phrase([.camera, .microphone]) == "camera and microphone")
        #expect(ActivityModel.phrase([.camera, .microphone, .screen]) == "camera, microphone and screen recording")
        activity.clearSensorHistory()
        #expect(activity.sensors.sessions.isEmpty)
    }

    @Test func recordsEnergyPerApp() async {
        let fake = Fake()
        let app = EnergyApp(key: "com.example.App", name: "App", path: nil)
        let start = Date()
        fake.energy = [ProcessEnergy(pid: 5, started: 1, energy: 1_000_000_000, app: app)]
        let activity = model(fake)
        await activity.sampleEnergy(at: start)
        fake.lock.withLock { fake.energy = [ProcessEnergy(pid: 5, started: 1, energy: 4_600_000_000, app: app)] }
        await activity.sampleEnergy(at: start.addingTimeInterval(300))
        #expect(activity.energyUsage.first?.app == app)
        #expect(activity.energyUsage.first?.joules == 3.6)
        #expect(activity.energy.batteryTime(since: start.addingTimeInterval(-3_600)) == 300)
        activity.clearEnergyHistory()
        #expect(activity.energyUsage.isEmpty)
    }
}

@MainActor
@Suite struct KeepAwakeModelTests {
    private final class Assertions: @unchecked Sendable {
        let lock = NSLock()
        var log: [String] = []
        var refuse = false
        var next: UInt32 = 0
    }

    private func model(_ assertions: Assertions, running: Set<String> = [], battery: (Int?, Bool) = (80, false)) -> KeepAwakeModel {
        let power = PowerAssertions(take: { display, _ in
            assertions.lock.withLock {
                guard !assertions.refuse else { return nil }
                assertions.next += 1
                assertions.log.append("take \(assertions.next) \(display ? "display" : "system")")
                return assertions.next
            }
        }, release: { id in assertions.lock.withLock { assertions.log.append("release \(id)") } })
        let model = KeepAwakeModel(environment: .init(assertions: power, runningBundleIDs: { running }, battery: { battery }))
        model.keepsDisplayOn = true
        model.stopsOnLowBattery = true
        return model
    }

    @Test func holdsOneAssertionAndReleasesIt() {
        let assertions = Assertions()
        let awake = model(assertions)
        awake.start(.minutes(30))
        #expect(awake.isActive)
        #expect(awake.statusText().hasPrefix("Until "))
        awake.keepsDisplayOn = false  // swaps the assertion
        awake.start(.indefinitely)
        #expect(awake.statusText() == "Until you turn it off")
        awake.stop()
        #expect(!awake.isActive)
        #expect(assertions.log == ["take 1 display", "release 1", "take 2 system", "release 2", "take 3 system", "release 3"])
        #expect(awake.statusText() == "Your Mac sleeps as usual")
    }

    @Test func endsByItselfAndSaysWhy() {
        let assertions = Assertions()
        let awake = model(assertions)
        awake.start(.minutes(15))
        awake.check(now: Date().addingTimeInterval(16 * 60))
        #expect(!awake.isActive)
        #expect(awake.lastEnd == .timeUp)
        #expect(awake.statusText() == "Ended: time was up")
        #expect(assertions.log.last == "release 1")

        let following = model(Assertions(), running: [])
        following.start(.whileRunning(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
        following.check(now: Date())
        #expect(following.lastEnd == .appQuit("Xcode"))

        let low = model(Assertions(), battery: (15, true))
        low.start(.indefinitely)
        low.check(now: Date())
        #expect(low.lastEnd == .batteryLow(KeepAwakeModel.batteryFloor))
    }

    @Test func aRefusedAssertionLeavesItOff() {
        let assertions = Assertions()
        assertions.refuse = true
        let awake = model(assertions)
        awake.start(.minutes(60))
        #expect(!awake.isActive)
    }
}
