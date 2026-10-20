import Foundation
import Testing
@testable import SweepMonitor

@Suite struct MemoryHogTests {
    private let chrome = EnergyApp(key: "chrome", name: "Chrome", path: "/Applications/Chrome.app")
    private let gigabyte: UInt64 = 1_000_000_000

    private func reading(_ bytes: UInt64, app: EnergyApp? = nil, pid: pid_t = 5) -> ProcessCPU {
        ProcessCPU(pid: pid, started: 1, time: 0, app: app ?? chrome, memory: bytes)
    }

    @Test func aLargeAppIsReportedOnlyWhileMemoryIsShort() {
        var detector = MemoryHogDetector()
        let total = 16 * gigabyte
        let calm = detector.add([reading(6 * gigabyte)], pressure: .normal, totalMemory: total)
        #expect(calm.isEmpty, "plenty of memory: nothing to say")
        let found = detector.add([reading(3 * gigabyte), reading(3 * gigabyte, pid: 6)], pressure: .warning, totalMemory: total)
        #expect(found.map(\.app) == [chrome], "helpers add up to the app")
        #expect(found.first?.bytes == 6 * gigabyte)
        #expect(found.first?.growth == 0)
        let repeated = detector.add([reading(6 * gigabyte)], pressure: .warning, totalMemory: total)
        #expect(repeated.isEmpty, "once")
        _ = detector.add([reading(6 * gigabyte)], pressure: .normal, totalMemory: total)
        #expect(detector.flagged.isEmpty, "pressure eased")
        let system = detector.add([reading(2 * gigabyte, app: .system)], pressure: .critical, totalMemory: 4 * gigabyte)
        #expect(system.isEmpty, "never macOS itself")
    }

    @Test func aGrowingAppIsReportedAsALeak() {
        var detector = MemoryHogDetector()
        let total = 64 * gigabyte
        var found: [MemoryHogDetector.Hog] = []
        for step in 0..<6 {
            found += detector.add([reading(UInt64(step) * 1_400_000_000 + gigabyte)], pressure: .warning, totalMemory: total, window: 6)
        }
        #expect(found.count == 1)
        #expect(found.first?.growth ?? 0 >= 6 * gigabyte, "grew from 1 GB past 6 GB")
        #expect(found.first?.bytes ?? 0 < 16 * gigabyte, "small against 64 GB: reported for growing, not size")
    }
}

@Suite struct ThermalLogTests {
    @Test func hotSpellsAreRecordedAndMerged() {
        var log = ThermalLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let warm = log.record(.fair, at: start)
        #expect(!warm, "warm isn't throttling")
        let hot = log.record(.serious, at: start.addingTimeInterval(60), busiestApp: "Xcode")
        #expect(hot)
        let hotter = log.record(.critical, at: start.addingTimeInterval(120))
        #expect(!hotter)
        #expect(log.current?.peak == .critical)
        log.record(.nominal, at: start.addingTimeInterval(600))
        #expect(log.current == nil)
        let again = log.record(.serious, at: start.addingTimeInterval(660))
        #expect(!again, "back within two minutes: the same spell")
        log.record(.fair, at: start.addingTimeInterval(900))
        #expect(log.episodes.count == 1)
        #expect(log.episodes[0].busiestApp == "Xcode")
        #expect(log.episodes[0].duration(now: start) == 840)
        let later = log.record(.serious, at: start.addingTimeInterval(3_600))
        #expect(later, "a new spell later")
        let summary = log.summary(since: start, now: start.addingTimeInterval(3_660))
        #expect(summary.count == 2)
        #expect(summary.total == 900)
        #expect(summary.longest == 840)
        log.record(.nominal, at: start.addingTimeInterval(3_700))
        log.record(.nominal, at: start.addingTimeInterval(40 * 86_400))
        #expect(log.episodes.isEmpty, "kept 30 days")
        #expect(ThermalLevel(ProcessInfo.ThermalState.serious).isThrottling)
        #expect(!ThermalLevel(ProcessInfo.ThermalState.fair).isThrottling)
    }
}

@Suite struct AppUsageTests {
    private let xcode = EnergyApp(key: "xcode", name: "Xcode", path: nil)
    private let mail = EnergyApp(key: "mail", name: "Mail", path: nil)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func timeIsSplitAcrossHoursAndDays() {
        var history = AppUsageHistory()
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        // 23:30 to 00:45 the next day.
        history.add(xcode, from: midnight.addingTimeInterval(-1_800), to: midnight.addingTimeInterval(2_700), calendar: calendar)
        history.add(mail, from: midnight.addingTimeInterval(3_600), to: midnight.addingTimeInterval(3_900), calendar: calendar)
        #expect(history.days.count == 2)
        #expect(history.days[0].apps["xcode"] == 1_800)
        #expect(history.days[0].hours[23] == 1_800)
        #expect(history.days[1].apps["xcode"] == 2_700)
        #expect(history.days[1].hours[0] == 2_700)
        let today = history.usage(since: midnight, calendar: calendar)
        #expect(today.map(\.app.key) == ["xcode", "mail"])
        #expect(today.first?.share == 2_700.0 / 3_000)
        #expect(history.perHour(of: midnight, calendar: calendar)[1].seconds == 300)
        let days = history.perDay(since: midnight.addingTimeInterval(-86_400 * 2), until: midnight, calendar: calendar)
        #expect(days.map(\.seconds) == [0, 1_800, 3_000], "days without use are included")
        history.add(mail, from: midnight.addingTimeInterval(100 * 86_400), to: midnight.addingTimeInterval(100 * 86_400 + 60), calendar: calendar)
        #expect(history.days.count == 1, "kept 90 days")
        #expect(history.apps.keys.sorted() == ["mail"])
    }

    @Test func theRecorderTurnsSwitchesIntoIntervals() {
        var recorder = UsageRecorder()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let none = recorder.activate(xcode, at: start)
        #expect(none == nil)
        let first = recorder.activate(mail, at: start.addingTimeInterval(600))
        #expect(first?.app == xcode)
        #expect(first?.end.timeIntervalSince(first!.start) == 600)
        let saved = recorder.checkpoint(at: start.addingTimeInterval(700))
        #expect(saved?.app == mail)
        #expect(recorder.current?.app == mail, "keeps counting after a checkpoint")
        let stopped = recorder.stop(at: start.addingTimeInterval(800))
        #expect(stopped?.start == start.addingTimeInterval(700))
        #expect(recorder.current == nil)
        let nothing = recorder.stop(at: start.addingTimeInterval(900))
        #expect(nothing == nil)
        let noCheckpoint = recorder.checkpoint(at: start.addingTimeInterval(900))
        #expect(noCheckpoint == nil)
    }
}
