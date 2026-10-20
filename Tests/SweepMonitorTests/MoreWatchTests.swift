import CoreGraphics
import Foundation
import Testing
@testable import SweepMonitor

@Suite struct NetworkUseTests {
    private let chrome = EnergyApp(key: "chrome", name: "Chrome", path: nil)
    private let mail = EnergyApp(key: "mail", name: "Mail", path: nil)

    @Test func parsesNettop() {
        let output = ",bytes_in,bytes_out,\nlaunchd.1,0,0,\nGoogle Chrome He.4512,1000,200,\nmDNSResponder.483,114955885,90789719,\ngarbage line\n"
        let readings = NetworkReader.parse(output)
        #expect(readings.map(\.pid) == [1, 4512, 483])
        #expect(readings[1] == ProcessTraffic(pid: 4512, name: "Google Chrome He", bytesIn: 1000, bytesOut: 200))
    }

    @Test func ledgerCountsBytesBetweenReadings() {
        var ledger = TrafficLedger()
        let apps: [pid_t: EnergyApp] = [10: chrome, 11: chrome, 12: mail]
        let app = { (pid: pid_t) in apps[pid] ?? .system }
        #expect(ledger.add([ProcessTraffic(pid: 10, name: "c", bytesIn: 1000, bytesOut: 100)], app: app).isEmpty, "the first reading is the baseline")
        let second = ledger.add([ProcessTraffic(pid: 10, name: "c", bytesIn: 1500, bytesOut: 150),
                                 ProcessTraffic(pid: 11, name: "c2", bytesIn: 300, bytesOut: 30)], app: app)
        #expect(second[chrome]?.received == 800, "500 more from pid 10, and all 300 of the new pid 11")
        #expect(second[chrome]?.sent == 80)
        // The same process ID under another name is a new process; a smaller count means its flows were reset.
        let third = ledger.add([ProcessTraffic(pid: 10, name: "mail", bytesIn: 40, bytesOut: 0),
                                ProcessTraffic(pid: 11, name: "c2", bytesIn: 100, bytesOut: 30)], app: app)
        #expect(third[chrome]?.received == 140)
        #expect(third[chrome]?.sent == nil || third[chrome]?.sent == 0)
    }

    @Test func historyGroupsByAppAndHotspot() {
        var history = NetworkHistory()
        let hour = Calendar.current.dateInterval(of: .hour, for: Date(timeIntervalSince1970: 1_800_000_000))!.start
        history.record([chrome: (1_000, 100), mail: (50, 50)], expensive: false, at: hour)
        history.record([chrome: (500, 0)], expensive: true, at: hour.addingTimeInterval(1_800))
        history.record([mail: (2_000, 0)], expensive: false, at: hour.addingTimeInterval(3_700))
        let usage = history.usage(since: hour)
        #expect(usage.map(\.app.key) == ["mail", "chrome"])
        #expect(usage.last?.received == 1_500)
        #expect(usage.last?.sent == 100)
        #expect(history.usage(since: hour, expensiveOnly: true).map { "\($0.app.key) \($0.total)" } == ["chrome 500"])
        #expect(history.perHour(since: hour).map(\.bytes) == [1_700, 2_000])
        history.record([:], expensive: false, at: hour.addingTimeInterval(40 * 86_400))
        #expect(history.usage(since: .distantPast).isEmpty, "kept 30 days")
    }
}

@Suite struct AccessoryTests {
    static let report = """
        {"SPBluetoothDataType": [{
          "controller_properties": {"controller_state": "attrib_on"},
          "device_connected": [
            {"AirPods Pro": {"device_minorType": "Headphones", "device_batteryLevelLeft": "72%", "device_batteryLevelRight": "70%",
                             "device_batteryLevelCase": "15%"}},
            {"Magic Mouse": {"device_minorType": "Mouse", "device_batteryLevelMain": "18 %"}},
            {"Speaker": {"device_minorType": "Speaker"}}
          ],
          "device_not_connected": [{"Old Keyboard": {"device_batteryLevelMain": "5%"}}]
        }]}
        """

    @Test func readsConnectedAccessoriesWithABattery() {
        let accessories = AccessoryReader.parse(Self.report)
        #expect(accessories.map(\.name) == ["AirPods Pro", "Magic Mouse"])
        #expect(accessories[0].levels == ["Left": 72, "Right": 70, "Case": 15])
        #expect(accessories[0].lowest == 70, "the case isn't in use")
        #expect(accessories[0].symbol == "airpods")
        #expect(accessories[1].lowest == 18)
        #expect(AccessoryReader.parse("not json").isEmpty)
    }

    @Test func warnsOnceUntilCharged() {
        var alerts = AccessoryAlerts()
        let low = Accessory(name: "Magic Mouse", kind: "Mouse", levels: ["Main": 18])
        #expect(alerts.check([low], threshold: 20).map(\.name) == ["Magic Mouse"])
        #expect(alerts.check([low], threshold: 20).isEmpty, "once")
        #expect(alerts.check([Accessory(name: "Magic Mouse", kind: "Mouse", levels: ["Main": 25])], threshold: 20).isEmpty)
        #expect(alerts.check([low], threshold: 20).isEmpty, "not charged enough to warn again")
        _ = alerts.check([Accessory(name: "Magic Mouse", kind: "Mouse", levels: ["Main": 90])], threshold: 20)
        #expect(alerts.check([low], threshold: 20).count == 1, "after charging, warns again")
    }
}

@Suite struct KeyboardWatcherTests {
    @Test func keepsOnlyKeyboardTapsOnePerProcess() {
        let raycast = EnergyApp(key: "com.raycast.macos", name: "Raycast", path: "/Applications/Raycast.app")
        let keys = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let mouse = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let watchers = KeyboardWatchers.merge([
            (pid: 10, executable: "/Applications/Raycast.app/Contents/MacOS/Raycast", mask: keys, listenOnly: true, enabled: false, app: raycast),
            (pid: 10, executable: "/Applications/Raycast.app/Contents/MacOS/Raycast", mask: keys, listenOnly: false, enabled: true, app: raycast),
            (pid: 11, executable: "/Applications/Scroll.app/Contents/MacOS/Scroll", mask: mouse, listenOnly: true, enabled: true, app: .system),
            (pid: 12, executable: "/System/Library/CoreServices/Siri.app/Contents/MacOS/Siri", mask: keys, listenOnly: true, enabled: true, app: .system),
        ])
        #expect(watchers.map(\.pid) == [10, 12], "mouse-only taps aren't listed; apps come before macOS")
        #expect(watchers[0].listenOnly == false, "any tap that can change keys counts")
        #expect(watchers[0].enabled)
        #expect(!watchers[0].isPartOfMacOS)
        #expect(watchers[1].isPartOfMacOS)
        _ = KeyboardWatchers.read()  // the real list is readable without permission
    }
}

@Suite struct RunawayTests {
    private let chrome = EnergyApp(key: "chrome", name: "Chrome", path: "/Applications/Chrome.app")

    private func reading(_ pid: pid_t, seconds: Double, app: EnergyApp, started: TimeInterval = 1) -> ProcessCPU {
        ProcessCPU(pid: pid, started: started, time: UInt64(seconds * 1_000_000_000), app: app)
    }

    @Test func reportsAppsBusyForTheWholeStretchOnce() {
        var detector = RunawayDetector()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var found: [[String]] = []
        // Chrome's two processes add up to 1.2 cores; Sweep itself and macOS are never reported.
        for minute in 0...5 {
            let date = start.addingTimeInterval(Double(minute) * 60)
            let result = detector.add([reading(10, seconds: Double(minute) * 42, app: chrome),
                                       reading(11, seconds: Double(minute) * 30, app: chrome),
                                       reading(12, seconds: Double(minute) * 60, app: EnergyApp(key: "org.sweep.Sweep", name: "Sweep", path: nil)),
                                       reading(13, seconds: Double(minute) * 60, app: .system)],
                                      at: date, threshold: 0.8, readings: 3, ignoring: ["org.sweep.Sweep"])
            found.append(result.map(\.app.key))
            if let usage = result.first?.usage { #expect(abs(usage - 1.2) < 0.01) }
        }
        #expect(found == [[], [], [], ["chrome"], [], []], "after three busy minutes, then not again")
        #expect(detector.flagged == ["chrome"])
        // Calming down clears it; busy again starts a new streak.
        _ = detector.add([reading(10, seconds: 210, app: chrome), reading(11, seconds: 150, app: chrome)],
                         at: start.addingTimeInterval(360), threshold: 0.8, readings: 3)
        #expect(detector.flagged.isEmpty)
    }

    @Test func aReusedProcessIDIsNotCountedAsBusy() {
        var detector = RunawayDetector()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = detector.add([reading(10, seconds: 500, app: chrome)], at: start, threshold: 0.5, readings: 1)
        let result = detector.add([reading(10, seconds: 900, app: chrome, started: 99)], at: start.addingTimeInterval(60), threshold: 0.5, readings: 1)
        #expect(result.isEmpty)
        _ = CPUReader.read()  // readable without permission
    }
}

@Suite struct BatteryHealthLogTests {
    @Test func recordsOncePerDayAndReportsTheChange() {
        var log = BatteryHealthLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(health: 0.90, cycles: 200, at: start)
        log.record(health: 0.89, cycles: 201, at: start.addingTimeInterval(3_600))
        #expect(log.entries.count == 1)
        #expect(log.change(since: .distantPast) == nil, "not a week of readings yet")
        log.record(health: 0.885, cycles: 230, at: start.addingTimeInterval(10 * 86_400))
        let change = log.change(since: .distantPast)
        #expect(change.map { ($0.health * 10).rounded() / 10 } == -1.5)
        #expect(change?.cycles == 30)
        #expect(change.map { Int($0.days) } == 10)
    }
}

@Suite struct DiskSpeedTests {
    static var folder: String {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = package.appendingPathComponent(".build/test-fixtures/speed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    @Test func measuresAndLeavesNothingBehind() throws {
        let folder = Self.folder
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let result = try DiskSpeed.measure(in: folder, bytes: 8 << 20, chunk: 1 << 20)
        #expect(result.write > 0)
        #expect(result.read > 0)
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder)).isEmpty)
        #expect(throws: DiskSpeed.Failure.cancelled) { try DiskSpeed.measure(in: folder, bytes: 8 << 20, chunk: 1 << 20) { true } }
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder)).isEmpty)
    }
}

@Suite struct MoreHealthScoreTests {
    private var snapshot: SystemSnapshot {
        SystemSnapshot(date: Date(), cpuUsage: 0.1, cpuCores: 8,
                       memory: .init(total: 16, used: 8, wired: 1, compressed: 1, cached: 1, swapUsed: 0, pressureLevel: 1),
                       disk: .init(total: 1_000, available: 500), battery: nil, network: nil, uptime: 100, thermalState: .nominal)
    }

    @Test func securityProblemsAndIntelAppsAreRecommended() {
        let one = HealthScore.evaluate(HealthInputs(snapshot: snapshot, securityProblems: ["FileVault"]))
        #expect(one.recommendations.contains { $0.id == "security" && $0.title == "Turn on FileVault" })
        let two = HealthScore.evaluate(HealthInputs(snapshot: snapshot, securityProblems: ["FileVault", "Gatekeeper"]))
        #expect(two.recommendations.first { $0.id == "security" }?.title == "Fix 2 security settings")
        let intel = HealthScore.evaluate(HealthInputs(snapshot: snapshot, intelOnlyApps: 2))
        #expect(intel.recommendations.first { $0.id == "intel" }?.module == "applications")
        #expect(HealthScore.evaluate(HealthInputs(snapshot: snapshot, intelOnlyApps: 0)).recommendations.allSatisfy { $0.id != "intel" })
    }
}
