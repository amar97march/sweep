import Foundation
import Testing
@testable import SweepCore
@testable import SweepUI
@testable import SweepMonitor

@MainActor
@Suite struct UsageModelTests {
    private final class Inputs: @unchecked Sendable {
        let lock = NSLock()
        var idle: TimeInterval = 0
    }

    @Test func usageCountsWhileActiveAndStopsWhenIdle() {
        let inputs = Inputs()
        let xcode = EnergyApp(key: "xcode", name: "Xcode", path: nil)
        var engine = ActivityModel.Engine.inert
        engine.frontmostApp = { xcode }
        engine.idleSeconds = { inputs.lock.withLock { inputs.idle } }
        let activity = ActivityModel(engine: engine, storagePrefix: "test.\(UUID().uuidString).")
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3_600)
        activity.appActivated(xcode, at: start)
        activity.usageTick(now: start.addingTimeInterval(60))
        // Seven minutes without input: the last five don't count.
        inputs.lock.withLock { inputs.idle = 7 * 60 }
        activity.usageTick(now: start.addingTimeInterval(8 * 60))
        #expect(activity.usage.usage(since: start).first?.seconds == 60)
        // Back at the keyboard: counting resumes with the app in front.
        inputs.lock.withLock { inputs.idle = 2 }
        activity.usageTick(now: start.addingTimeInterval(10 * 60))
        activity.usagePaused(at: start.addingTimeInterval(12 * 60))
        #expect(activity.usage.usage(since: start).first?.seconds == 180)

        activity.recordsUsage = false
        activity.appActivated(xcode, at: start.addingTimeInterval(20 * 60))
        activity.usageTick(now: start.addingTimeInterval(30 * 60))
        #expect(activity.usage.usage(since: start).first?.seconds == 180, "switched off: nothing more counts")
        activity.clearUsageHistory()
        #expect(activity.usage.days.isEmpty)
    }
}

@MainActor
@Suite struct HeatAndMemoryAlertTests {
    private final class Readings: @unchecked Sendable {
        let lock = NSLock()
        var level = ThermalLevel.nominal
        var pressure = MemoryPressure.normal
        var cpu: [ProcessCPU] = []
        var quit: [String] = []
    }

    private func model(_ readings: Readings) -> AlertsModel {
        var engine = AlertsModel.Engine.inert
        engine.thermalLevel = { readings.lock.withLock { readings.level } }
        engine.memoryPressure = { readings.lock.withLock { readings.pressure } }
        engine.readCPU = { readings.lock.withLock { readings.cpu } }
        engine.totalMemory = 8_000_000_000
        engine.quit = { app in readings.lock.withLock { readings.quit.append(app.key) } }
        return AlertsModel(engine: engine, keyPrefix: "test.alerts.\(UUID().uuidString).")
    }

    @Test func hotSpellsAreLoggedWithTheBusiestApp() async {
        let readings = Readings()
        let alerts = model(readings)
        let xcode = EnergyApp(key: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
        let start = Date()
        readings.cpu = [ProcessCPU(pid: 4, started: 1, time: 0, app: xcode)]
        await alerts.checkCPU(at: start)
        readings.lock.withLock { readings.cpu = [ProcessCPU(pid: 4, started: 1, time: 50_000_000_000, app: xcode)] }
        await alerts.checkCPU(at: start.addingTimeInterval(60))
        readings.lock.withLock { readings.level = .serious }
        alerts.checkHeat(at: start.addingTimeInterval(61))
        #expect(alerts.thermalLevel == .serious)
        #expect(alerts.thermalLog.current?.busiestApp == "Xcode")
        readings.lock.withLock { readings.level = .nominal }
        alerts.checkHeat(at: start.addingTimeInterval(400))
        #expect(alerts.thermalLog.current == nil)
        #expect(alerts.thermalLog.episodes.count == 1)
        alerts.clearThermalLog()
        #expect(alerts.thermalLog.episodes.isEmpty)
    }

    @Test func memoryHogsCanBeQuit() async {
        let readings = Readings()
        let alerts = model(readings)
        let chrome = EnergyApp(key: "com.google.Chrome", name: "Chrome", path: "/Applications/Chrome.app")
        readings.cpu = [ProcessCPU(pid: 4, started: 1, time: 0, app: chrome, memory: 3_000_000_000)]
        readings.pressure = .warning
        await alerts.checkCPU(at: Date())
        #expect(alerts.memoryHogs.map(\.app.key) == ["com.google.Chrome"])
        alerts.quit(alerts.memoryHogs[0])
        #expect(readings.lock.withLock { readings.quit } == ["com.google.Chrome"])
        #expect(alerts.memoryHogs.isEmpty)

        alerts.warnsAboutMemory = false
        readings.lock.withLock { readings.cpu = [ProcessCPU(pid: 5, started: 1, time: 0, app: EnergyApp(key: "b", name: "B", path: nil), memory: 4_000_000_000)] }
        await alerts.checkCPU(at: Date())
        #expect(alerts.memoryHogs.isEmpty, "switched off")
    }
}
