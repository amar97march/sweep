import Foundation
import Testing
@testable import SweepMonitor
import SweepNative

@Suite struct DriveHealthTests {
    private func drive(used: Int = 1, spare: Int = 100, threshold: Int = 10, warnings: DriveHealth.Warnings = [],
                       errors: UInt64 = 0) -> DriveHealth {
        DriveHealth(name: "Test SSD", isInternal: true, capacity: 500_000_000_000, percentageUsed: used, availableSpare: spare,
                    spareThreshold: threshold, warnings: warnings, temperatureCelsius: 35, bytesWritten: 1, bytesRead: 1,
                    powerOnHours: 1, powerCycles: 1, unsafeShutdowns: 0, mediaErrors: errors)
    }

    @Test func readsTheNVMeLogInBytesAndCelsius() {
        var log = SweepNVMeHealth()
        log.temperatureKelvin = 310
        log.percentageUsed = 3
        log.availableSpare = 100
        log.availableSpareThreshold = 99
        log.dataUnitsWritten = 67_413_713
        log.dataUnitsRead = 2
        log.powerOnHours = 1_015
        let drive = DriveHealth(name: "SSD", isInternal: true, capacity: nil, log: log)
        #expect(drive.temperatureCelsius == 37)
        #expect(drive.bytesWritten == 67_413_713 * 512_000)
        #expect(drive.bytesRead == 1_024_000)
        #expect(drive.lifeLeft == 97)
        #expect(drive.status == .good)
        log.temperatureKelvin = 0
        #expect(DriveHealth(name: "SSD", isInternal: true, capacity: nil, log: log).temperatureCelsius == nil, "0 means not reported")
    }

    @Test func statusFollowsWearErrorsAndTheDrivesOwnWarnings() {
        #expect(drive().status == .good)
        #expect(drive().problems.isEmpty)
        #expect(drive(used: 85).status == .watch)
        #expect(drive(errors: 2).status == .watch)
        #expect(drive(errors: 2).problems.first?.text == "2 unrecovered data errors so far.")
        #expect(drive(warnings: .temperature).status == .watch)
        #expect(drive(used: 100).status == .failing)
        #expect(drive(spare: 5, threshold: 10).status == .failing)
        #expect(drive(warnings: .readOnly).status == .failing)
        #expect(drive(warnings: .reliabilityDegraded).status == .failing)
        // The most serious problem comes first.
        #expect(drive(used: 85, warnings: .readOnly).problems.map(\.status) == [.failing, .watch])
        #expect(drive(used: 300).lifeLeft == 0)
    }

    @Test func writtenPerDayNeedsReadingsADayApart() {
        var log = DriveWriteLog()
        var ssd = drive()
        let start = Date(timeIntervalSince1970: 1_000_000)
        ssd.bytesWritten = 1_000_000_000_000
        log.record(ssd, at: start)
        ssd.bytesWritten = 1_050_000_000_000
        log.record(ssd, at: start.addingTimeInterval(3_600))  // too soon: ignored
        #expect(log.writtenPerDay(ssd) == nil)
        log.record(ssd, at: start.addingTimeInterval(2 * 86_400))
        #expect(log.writtenPerDay(ssd) == 25_000_000_000)
        // Readings older than 120 days are dropped.
        log.record(ssd, at: start.addingTimeInterval(200 * 86_400))
        #expect(log.entries[ssd.id]?.count == 1)
    }

    @Test func aFailingDriveTopsTheHealthReport() {
        let snapshot = SystemSnapshot(date: Date(), cpuUsage: 0.1, cpuCores: 8,
                                      memory: .init(total: 16, used: 8, wired: 1, compressed: 1, cached: 1, swapUsed: 0, pressureLevel: 1),
                                      disk: .init(total: 1_000, available: 500), battery: nil, network: nil, uptime: 100, thermalState: .nominal)
        let failing = HealthScore.evaluate(HealthInputs(snapshot: snapshot, drives: [drive(), drive(warnings: .readOnly)]))
        #expect(failing.recommendations.first?.id == "drive")
        #expect(failing.recommendations.first?.severity == .critical)
        #expect(failing.recommendations.first?.title == "Back up your Mac now")
        let worn = HealthScore.evaluate(HealthInputs(snapshot: snapshot, drives: [drive(used: 90)]))
        #expect(worn.recommendations.first { $0.id == "drive" }?.severity == .warning)
        #expect(HealthScore.evaluate(HealthInputs(snapshot: snapshot, drives: [drive()])).recommendations.allSatisfy { $0.id != "drive" })
    }
}

@Suite struct SensorLogTests {
    private func line(_ timestamp: String, _ message: String) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "eventMessage": message, "processID": 624])
        return String(decoding: json, as: UTF8.self)
    }

    @Test func parsesTheIndicatorMessages() {
        let uses = SensorLog.uses(inMessage: #"Active activity attributions changed to ["cam:us.zoom.xos", "mic:us.zoom.xos", "loc:com.apple.weather", "scr:com.apple.screencaptureui"]"#)
        #expect(uses == [SensorUse(sensor: .camera, bundleID: "us.zoom.xos"), SensorUse(sensor: .microphone, bundleID: "us.zoom.xos"),
                         SensorUse(sensor: .screen, bundleID: "com.apple.screencaptureui")])
        #expect(SensorLog.uses(inMessage: "Active activity attributions changed to []") == [])
        #expect(SensorLog.uses(inMessage: "Sorted active attributions from SystemStatus update: []") == nil)
    }

    @Test func readsChangesFromLogJSON() {
        let output = [line("2026-10-19 23:37:01.686623+0530", #"Active activity attributions changed to ["cam:net.example.Mirror"]"#),
                      line("2026-10-19 23:37:07.398000+0530", "Active activity attributions changed to []"),
                      "Filtering the log data using \"subsystem == ...\"",
                      line("2026-10-19 23:30:00.000000+0530", "Something else")].joined(separator: "\n")
        let changes = SensorLog.changes(fromNDJSON: output)
        #expect(changes.count == 2)
        #expect(changes[0].active == [SensorUse(sensor: .camera, bundleID: "net.example.Mirror")])
        #expect(changes[1].active.isEmpty)
        #expect(changes[1].date.timeIntervalSince(changes[0].date) > 5.7)
        let expected = ISO8601DateFormatter().date(from: "2026-10-19T18:07:01Z")!.addingTimeInterval(0.686)
        #expect(abs(changes[0].date.timeIntervalSince(expected)) < 0.002)
    }

    @Test func readAsksTheLogForTheRightEntriesOnly() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = LockedArguments()
        _ = SensorLog.read(since: since) { executable, arguments in
            seen.set([executable] + arguments)
            return ""
        }
        let arguments = seen.value
        #expect(arguments.first == "/usr/bin/log")
        #expect(arguments.contains("ndjson"))
        #expect(arguments.contains("--start"))
        #expect(arguments.contains { $0.contains("sensor-indicators") })
        _ = SensorLog.read(since: nil) { _, arguments in seen.set(arguments); return nil }
        #expect(seen.value.suffix(2) == ["--last", "7d"])
    }

    @Test func historyTurnsChangesIntoSessions() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        let cam = SensorUse(sensor: .camera, bundleID: "us.zoom.xos"), mic = SensorUse(sensor: .microphone, bundleID: "us.zoom.xos")
        var history = SensorHistory()
        history.apply([.init(date: at(0), active: [cam, mic]), .init(date: at(600), active: [mic]), .init(date: at(900), active: [])],
                      now: at(1_000))
        #expect(history.sessions.count == 2)
        #expect(history.sessions.first { $0.sensor == .camera }?.duration(now: at(1_000)) == 600)
        #expect(history.sessions.first { $0.sensor == .microphone }?.end == at(900))
        #expect(history.inUse.isEmpty)
        #expect(history.readThrough == at(900))

        // Importing the same changes again changes nothing; a flicker under two seconds stays one session.
        history.apply([.init(date: at(900), active: [])], now: at(1_000))
        history.apply([.init(date: at(2_000), active: [cam]), .init(date: at(2_060), active: []),
                       .init(date: at(2_061), active: [cam])], now: at(2_100))
        #expect(history.sessions.filter { $0.sensor == .camera }.count == 2)
        #expect(history.inUse.map(\.use) == [cam])

        // Still open from before a restart: closed at the restart.
        history.apply([], bootTime: at(5_000), now: at(6_000))
        #expect(history.inUse.isEmpty)
        #expect(history.sessions.last?.end == at(5_000))
    }

    @Test func historyForgetsSessionsAfterNinetyDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let use = SensorUse(sensor: .camera, bundleID: "a")
        var history = SensorHistory()
        history.apply([.init(date: now.addingTimeInterval(-100 * 86_400), active: [use]),
                       .init(date: now.addingTimeInterval(-100 * 86_400 + 60), active: []),
                       .init(date: now.addingTimeInterval(-3_600), active: [use]), .init(date: now.addingTimeInterval(-3_000), active: [])],
                      now: now)
        #expect(history.sessions.count == 1)
        let summary = history.summary(since: now.addingTimeInterval(-86_400), now: now)
        #expect(summary.count == 1)
        #expect(summary.first?.duration == 600)
        #expect(summary.first?.sessions == 1)
    }
}

/// Collects a closure's arguments across the Sendable boundary.
final class LockedArguments: @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [String] = []
    var value: [String] { lock.withLock { arguments } }
    func set(_ new: [String]) { lock.withLock { arguments = new } }
}

@Suite struct EnergyTests {
    @Test func helpersCountTowardTheirApp() {
        let ids = ["/Applications/Google Chrome.app": "com.google.Chrome"]
        let helper = EnergyApp.owning(executable: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") { ids[$0] }
        #expect(helper == EnergyApp(key: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app"))
        #expect(EnergyApp.owning(executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") { _ in nil } == .system)
        #expect(EnergyApp.owning(executable: "/usr/libexec/trustd") { _ in nil } == .system)
        #expect(EnergyApp.owning(executable: "") { _ in nil } == .system)
        let safari = EnergyApp.owning(executable: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari") { _ in "com.apple.Safari" }
        #expect(safari.key == "com.apple.Safari")
        #expect(EnergyApp.owning(executable: "/opt/homebrew/bin/node") { _ in nil }.name == "node")
    }

    @Test func ledgerCountsOnlyEnergyUsedBetweenReadings() {
        let chrome = EnergyApp(key: "chrome", name: "Chrome", path: nil), xcode = EnergyApp(key: "xcode", name: "Xcode", path: nil)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = EnergyLedger()
        // The first reading is the baseline.
        #expect(ledger.add([ProcessEnergy(pid: 10, started: 100, energy: 5_000_000_000, app: chrome)], at: t0).isEmpty)
        let second = ledger.add([ProcessEnergy(pid: 10, started: 100, energy: 8_000_000_000, app: chrome),
                                 ProcessEnergy(pid: 11, started: t0.timeIntervalSince1970 + 10, energy: 2_000_000_000, app: chrome),
                                 ProcessEnergy(pid: 12, started: 50, energy: 9_000_000_000, app: xcode)], at: t0.addingTimeInterval(300))
        // pid 10: 3 J more; pid 11 started since: all 2 J; pid 12 was running before but unseen: baseline only.
        #expect(second[chrome] == 5)
        #expect(second[xcode] == nil)
        // A reused process ID is a new process.
        let third = ledger.add([ProcessEnergy(pid: 10, started: t0.timeIntervalSince1970 + 400, energy: 1_000_000_000, app: xcode),
                                ProcessEnergy(pid: 12, started: 50, energy: 9_500_000_000, app: xcode)], at: t0.addingTimeInterval(600))
        #expect(third[xcode] == 1.5)
        #expect(third[chrome] == nil)
    }

    @Test func historySplitsBatteryFromPluggedIn() {
        let chrome = EnergyApp(key: "chrome", name: "Chrome", path: nil), mail = EnergyApp(key: "mail", name: "Mail", path: nil)
        var history = EnergyHistory()
        let t0 = Calendar.current.dateInterval(of: .hour, for: Date(timeIntervalSince1970: 1_800_000_000))!.start
        history.record([:], charge: 0.9, onBattery: true, at: t0)
        history.record([chrome: 300, mail: 100], charge: 0.85, onBattery: true, at: t0.addingTimeInterval(600))
        history.record([chrome: 100], charge: 0.8, onBattery: true, at: t0.addingTimeInterval(1_200))
        history.record([mail: 500], charge: 0.82, onBattery: false, at: t0.addingTimeInterval(1_500))
        let battery = history.usage(since: t0, onBattery: true)
        #expect(battery.map(\.app.key) == ["chrome", "mail"])
        #expect(battery.first?.joules == 400)
        #expect(battery.first?.share == 0.8)
        let all = history.usage(since: t0, onBattery: false)
        #expect(all.first?.app.key == "mail")
        #expect(all.first?.joules == 600)
        #expect(history.batteryTime(since: t0) == 1_200)
        // 10% over 20 minutes on battery is too little to judge; another 20 minutes makes it 40.
        #expect(history.drainPerHour(since: t0) == nil)
        history.record([:], charge: 0.8, onBattery: true, at: t0.addingTimeInterval(1_800))
        history.record([:], charge: 0.75, onBattery: true, at: t0.addingTimeInterval(2_400))
        history.record([:], charge: 0.70, onBattery: true, at: t0.addingTimeInterval(3_000))
        #expect(history.drainPerHour(since: t0).map { ($0 * 1000).rounded() / 1000 } == 0.3)
        // A gap longer than 15 minutes (sleep, Sweep closed) isn't counted as recorded time.
        history.record([:], charge: 0.7, onBattery: false, at: t0.addingTimeInterval(3 * 3_600))
        #expect(history.recordedTime(since: t0) == 3_000)
    }

    @Test func historyKeepsThirtyDays() {
        var history = EnergyHistory()
        let app = EnergyApp(key: "a", name: "A", path: nil)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        history.record([app: 10], charge: 0.5, onBattery: true, at: start)
        history.record([app: 10], charge: 0.5, onBattery: true, at: start.addingTimeInterval(40 * 86_400))
        #expect(history.hours.count == 1)
        #expect(history.levels.count == 1)
        history.clear()
        #expect(history.hours.isEmpty && history.apps.isEmpty)
    }
}

@Suite struct KeepAwakeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func timedSessionsEndWhenTimeIsUp() {
        let session = KeepAwakeSession(duration: .minutes(30), started: start, keepsDisplayOn: true)
        #expect(session.endDate == start.addingTimeInterval(1_800))
        #expect(session.endReason(now: start.addingTimeInterval(1_799), runningBundleIDs: [], batteryPercent: nil, onBattery: false,
                                  batteryFloor: nil) == nil)
        #expect(session.endReason(now: start.addingTimeInterval(1_800), runningBundleIDs: [], batteryPercent: nil, onBattery: false,
                                  batteryFloor: nil) == .timeUp)
    }

    @Test func followingAnAppEndsWhenItQuits() {
        let session = KeepAwakeSession(duration: .whileRunning(bundleID: "com.apple.dt.Xcode", name: "Xcode"), started: start, keepsDisplayOn: false)
        #expect(session.endDate == nil)
        #expect(session.endReason(now: start, runningBundleIDs: ["com.apple.dt.Xcode"], batteryPercent: 80, onBattery: true,
                                  batteryFloor: 20) == nil)
        #expect(session.endReason(now: start, runningBundleIDs: [], batteryPercent: 80, onBattery: true, batteryFloor: 20) == .appQuit("Xcode"))
    }

    @Test func lowBatteryEndsItOnlyOnBatteryPower() {
        let session = KeepAwakeSession(duration: .indefinitely, started: start, keepsDisplayOn: true)
        #expect(session.endReason(now: start, runningBundleIDs: [], batteryPercent: 20, onBattery: true, batteryFloor: 20) == .batteryLow(20))
        #expect(session.endReason(now: start, runningBundleIDs: [], batteryPercent: 20, onBattery: false, batteryFloor: 20) == nil)
        #expect(session.endReason(now: start, runningBundleIDs: [], batteryPercent: 5, onBattery: true, batteryFloor: nil) == nil)
    }

    @Test func durationsReadNaturally() {
        #expect(KeepAwakeDuration.minutes(15).title == "15 minutes")
        #expect(KeepAwakeDuration.minutes(60).title == "1 hour")
        #expect(KeepAwakeDuration.minutes(120).title == "2 hours")
        #expect(KeepAwakeDuration.minutes(90).title == "1 h 30 min")
        #expect(KeepAwakeDuration.indefinitely.title == "Until turned off")
        #expect(KeepAwakeDuration.whileRunning(bundleID: "x", name: "Zoom").title == "While Zoom is open")
    }
}
