import Darwin
import Foundation

/// Which app a process counts toward: an app bundle, or macOS itself for system services.
public struct EnergyApp: Hashable, Sendable, Codable {
    /// Bundle ID, or "system" for macOS services, or an executable's name.
    public let key: String
    public let name: String
    /// The app bundle, for its icon.
    public let path: String?

    public init(key: String, name: String, path: String?) {
        self.key = key
        self.name = name
        self.path = path
    }

    public static let system = EnergyApp(key: "system", name: "macOS & system services", path: nil)

    /// The outermost app bundle in `executable`'s path ("…/Google Chrome.app/…/Helper.app/…" → Google Chrome).
    public static func owning(executable: String, bundleID: (String) -> String? = EnergyApp.bundleID(ofApp:)) -> EnergyApp {
        let app: String? = executable.range(of: ".app/").map { String(executable[..<$0.upperBound].dropLast()) }
            ?? (executable.hasSuffix(".app") ? executable : nil)
        if let path = app {
            // Background parts of macOS live in app bundles too (Finder, Control Center); they count as macOS.
            if path.hasPrefix("/System/Library/") || path.contains("/Cryptexes/") && !path.contains("/Applications/") { return .system }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return EnergyApp(key: bundleID(path) ?? path, name: name, path: path)
        }
        if executable.isEmpty || ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/"].contains(where: executable.hasPrefix) {
            return .system
        }
        let name = (executable as NSString).lastPathComponent
        return EnergyApp(key: executable, name: name, path: nil)
    }

    public static func bundleID(ofApp path: String) -> String? {
        (NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String)
    }
}

/// One process's energy use since it started, as the kernel accounts it.
public struct ProcessEnergy: Sendable, Equatable {
    public let pid: pid_t
    /// When the process started (seconds since 1970), to tell a reused process ID from the same process.
    public let started: TimeInterval
    /// Nanojoules since the process started.
    public let energy: UInt64
    public let app: EnergyApp

    public init(pid: pid_t, started: TimeInterval, energy: UInt64, app: EnergyApp) {
        self.pid = pid
        self.started = started
        self.energy = energy
        self.app = app
    }
}

public enum EnergyReader {
    /// Energy of every process this user can see (the user's own apps and helpers; root daemons aren't readable
    /// and count toward nothing). Helpers are counted toward the app responsible for them: a browser's web content
    /// processes toward the browser.
    public static func read() -> [ProcessEnergy] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var paths: [pid_t: String] = [:]
        func path(_ pid: pid_t) -> String {
            if let cached = paths[pid] { return cached }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let found = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            paths[pid] = found
            return found
        }
        var apps: [String: EnergyApp] = [:]
        var readings: [ProcessEnergy] = []
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var usage = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard status == 0, usage.ri_energy_nj > 0 else { continue }
            var info = proc_bsdinfo()
            let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
                ? TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000 : 0
            let owner = responsiblePID(pid) ?? pid
            let executable = path(owner).isEmpty ? path(pid) : path(owner)
            let app = apps[executable] ?? EnergyApp.owning(executable: executable)
            apps[executable] = app
            readings.append(ProcessEnergy(pid: pid, started: started, energy: usage.ri_energy_nj, app: app))
        }
        return readings
    }

    /// The app `pid` counts toward: its responsible process's enclosing app, or macOS for system services.
    public static func app(forPID pid: pid_t, cache: inout [String: EnergyApp]) -> EnergyApp {
        func path(_ pid: pid_t) -> String {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        }
        let owner = responsiblePID(pid) ?? pid
        let executable = path(owner).isEmpty ? path(pid) : path(owner)
        if let known = cache[executable] { return known }
        let app = EnergyApp.owning(executable: executable)
        cache[executable] = app
        return app
    }

    /// The process macOS holds responsible for `pid` (an app for its XPC helpers). Looked up at run time because
    /// the function isn't in the SDK headers; without it, helpers count toward the app whose bundle they're in.
    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let owner = function(pid)
        return owner > 0 ? owner : nil
    }
}

/// Turns cumulative per-process energy readings into energy per app between readings.
public struct EnergyLedger: Sendable {
    private var previous: [pid_t: (started: TimeInterval, energy: UInt64)] = [:]
    private var lastReading: Date?

    public init() {}

    /// Energy per app (joules) since the last call. A process seen for the first time counts only if it started
    /// after the last reading; older ones become the baseline, so the first call returns nothing.
    public mutating func add(_ readings: [ProcessEnergy], at date: Date) -> [EnergyApp: Double] {
        var used: [EnergyApp: Double] = [:]
        var next: [pid_t: (started: TimeInterval, energy: UInt64)] = [:]
        for reading in readings {
            next[reading.pid] = (reading.started, reading.energy)
            let delta: UInt64
            if let before = previous[reading.pid], before.started == reading.started {
                delta = reading.energy >= before.energy ? reading.energy - before.energy : 0
            } else if let lastReading, reading.started >= lastReading.timeIntervalSince1970 {
                delta = reading.energy
            } else {
                delta = 0
            }
            if delta > 0 { used[reading.app, default: 0] += Double(delta) / 1_000_000_000 }
        }
        previous = next
        lastReading = date
        return used
    }
}

/// Days of energy use per app, split into on-battery and plugged-in, with the battery level over time.
public struct EnergyHistory: Codable, Sendable, Equatable {
    public struct Hour: Codable, Sendable, Equatable {
        public let start: Date
        /// Seconds of this hour spent on battery while Sweep was recording.
        public var batterySeconds: Double = 0
        public var recordedSeconds: Double = 0
        /// Joules per app key, on battery and in total.
        public var battery: [String: Double] = [:]
        public var total: [String: Double] = [:]
    }

    public struct Level: Codable, Sendable, Equatable {
        public let date: Date
        public let charge: Double
        public let onBattery: Bool
    }

    public private(set) var hours: [Hour] = []
    public private(set) var levels: [Level] = []
    public private(set) var apps: [String: EnergyApp] = [:]
    private var lastSample: Date?

    public init() {}

    public static let keepDays = 30.0
    /// A gap longer than this between readings (sleep, Sweep not running) isn't counted as time recorded.
    static let longestInterval: TimeInterval = 15 * 60

    /// Adds one reading's energy and the battery state at `date`.
    public mutating func record(_ used: [EnergyApp: Double], charge: Double?, onBattery: Bool, at date: Date) {
        let interval = lastSample.map { date.timeIntervalSince($0) } ?? 0
        lastSample = date
        let start = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
        if hours.last?.start != start { hours.append(Hour(start: start)) }
        var hour = hours.removeLast()
        if interval > 0 && interval <= Self.longestInterval {
            hour.recordedSeconds += interval
            if onBattery { hour.batterySeconds += interval }
        }
        for (app, joules) in used where joules > 0 {
            apps[app.key] = app
            hour.total[app.key, default: 0] += joules
            if onBattery { hour.battery[app.key, default: 0] += joules }
        }
        hours.append(hour)
        if let charge, levels.last.map({ date.timeIntervalSince($0.date) >= 5 * 60 || $0.onBattery != onBattery }) ?? true {
            levels.append(Level(date: date, charge: charge, onBattery: onBattery))
        }
        let cutoff = date.addingTimeInterval(-Self.keepDays * 86_400)
        hours.removeAll { $0.start < cutoff }
        levels.removeAll { $0.date < cutoff }
        let used = Set(hours.flatMap { $0.total.keys })
        apps = apps.filter { used.contains($0.key) }
    }

    public mutating func clear() { self = EnergyHistory() }

    /// An app's share of the energy used in a period.
    public struct Usage: Identifiable, Sendable, Equatable {
        public let app: EnergyApp
        public let joules: Double
        public let share: Double
        public var id: String { app.key }
    }

    /// Apps by energy used since `date`, on battery only or in total.
    public func usage(since date: Date, onBattery: Bool) -> [Usage] {
        var totals: [String: Double] = [:]
        for hour in hours where hour.start.addingTimeInterval(3_600) > date {
            for (key, joules) in onBattery ? hour.battery : hour.total { totals[key, default: 0] += joules }
        }
        let sum = totals.values.reduce(0, +)
        return totals.compactMap { key, joules in
            apps[key].map { Usage(app: $0, joules: joules, share: sum > 0 ? joules / sum : 0) }
        }
        .sorted { $0.joules > $1.joules }
    }

    /// Time on battery while recording since `date`.
    public func batteryTime(since date: Date) -> TimeInterval {
        hours.filter { $0.start.addingTimeInterval(3_600) > date }.reduce(0) { $0 + $1.batterySeconds }
    }

    public func recordedTime(since date: Date) -> TimeInterval {
        hours.filter { $0.start.addingTimeInterval(3_600) > date }.reduce(0) { $0 + $1.recordedSeconds }
    }

    /// Average battery used per hour on battery since `date`, from the level readings (0.1 = 10% an hour).
    public func drainPerHour(since date: Date) -> Double? {
        var drained = 0.0, seconds = 0.0
        let recent = levels.filter { $0.date >= date }
        for (before, after) in zip(recent, recent.dropFirst()) where before.onBattery && after.onBattery {
            let interval = after.date.timeIntervalSince(before.date)
            guard interval > 0, interval <= Self.longestInterval, after.charge <= before.charge else { continue }
            drained += before.charge - after.charge
            seconds += interval
        }
        return seconds >= 30 * 60 ? drained / (seconds / 3_600) : nil
    }
}
