import Darwin
import Foundation

/// CPU time a process has used since it started.
public struct ProcessCPU: Sendable, Equatable {
    public let pid: pid_t
    public let started: TimeInterval
    /// Nanoseconds of CPU time.
    public let time: UInt64
    public let app: EnergyApp
    /// Memory the process takes now (its footprint, as Activity Monitor's Memory column shows it).
    public let memory: UInt64

    public init(pid: pid_t, started: TimeInterval, time: UInt64, app: EnergyApp, memory: UInt64 = 0) {
        self.pid = pid
        self.started = started
        self.time = time
        self.app = app
        self.memory = memory
    }
}

public enum CPUReader {
    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, max(info.denom, 1))
    }()

    /// CPU time of every process this user can see (root daemons aren't readable).
    public static func read() -> [ProcessCPU] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var cache: [String: EnergyApp] = [:]
        var readings: [ProcessCPU] = []
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            let nanos = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(timebase.denom)
            var info = proc_bsdinfo()
            let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
                ? TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000 : 0
            readings.append(ProcessCPU(pid: pid, started: started, time: nanos, app: EnergyReader.app(forPID: pid, cache: &cache),
                                       memory: usage.ri_phys_footprint))
        }
        return readings
    }
}

/// Spots apps that keep a CPU core busy for minutes on end.
public struct RunawayDetector: Sendable {
    private var previous: [pid_t: (started: TimeInterval, time: UInt64)] = [:]
    private var lastReading: Date?
    /// Consecutive readings each app has been above the threshold.
    private var streaks: [String: Int] = [:]
    private var reported: Set<String> = []
    /// The app that used the most processor time in the last interval (macOS services included).
    public private(set) var busiest: (app: EnergyApp, usage: Double)?

    public init() {}

    /// Apps averaging at least `threshold` of one core (0.8 = 80%) over the last `readings` readings, each reported
    /// once until it calms down. Apps in `ignoring` (Sweep itself) and macOS services are never reported.
    public mutating func add(_ readings: [ProcessCPU], at date: Date, threshold: Double, readings needed: Int,
                             ignoring: Set<String> = []) -> [(app: EnergyApp, usage: Double)] {
        defer {
            previous = Dictionary(readings.map { ($0.pid, ($0.started, $0.time)) }, uniquingKeysWith: { _, last in last })
            lastReading = date
        }
        guard let lastReading, date.timeIntervalSince(lastReading) > 0 else { return [] }
        let interval = date.timeIntervalSince(lastReading)
        var busy: [EnergyApp: Double] = [:]
        for reading in readings {
            guard let before = previous[reading.pid], before.started == reading.started, reading.time >= before.time else { continue }
            busy[reading.app, default: 0] += Double(reading.time - before.time) / 1_000_000_000 / interval
        }
        busiest = busy.max { $0.value < $1.value }.map { ($0.key, $0.value) }
        var found: [(app: EnergyApp, usage: Double)] = []
        let busyKeys = Set(busy.filter { $0.value >= threshold }.keys.map(\.key))
        for key in streaks.keys where !busyKeys.contains(key) {
            streaks[key] = nil
            reported.remove(key)
        }
        for (app, usage) in busy where usage >= threshold && app != .system && !ignoring.contains(app.key) {
            streaks[app.key, default: 0] += 1
            if streaks[app.key]! >= needed, reported.insert(app.key).inserted { found.append((app, usage)) }
        }
        return found.sorted { $0.usage > $1.usage }
    }

    /// Apps currently over the threshold that have been reported, for the menu bar.
    public var flagged: Set<String> { reported }
}
