import Foundation
import Network

/// Bytes a process has sent and received, as `nettop` counts them (since the process started).
public struct ProcessTraffic: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(pid: pid_t, name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public enum NetworkReader {
    public typealias Run = @Sendable (String, [String]) -> String?

    /// One reading of every process's traffic. Read-only; needs no special permission.
    public static func read(run: Run = SensorLog.runCommand) -> [ProcessTraffic] {
        run("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]).map(parse) ?? []
    }

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out` prints ",bytes_in,bytes_out," then "name.pid,in,out," per process.
    static func parse(_ output: String) -> [ProcessTraffic] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."), let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { return nil }
            return ProcessTraffic(pid: pid, name: String(fields[0][..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }

    /// Whether the Mac is on a connection the system marks as expensive (an iPhone hotspot, a cellular modem).
    public static func isOnExpensiveNetwork(timeout: TimeInterval = 1) -> Bool {
        let monitor = NWPathMonitor()
        let found = DispatchSemaphore(value: 0)
        let result = LockedFlag()
        monitor.pathUpdateHandler = { path in
            result.set(path.status == .satisfied && path.isExpensive)
            found.signal()
        }
        monitor.start(queue: DispatchQueue(label: "sweep.network-path"))
        _ = found.wait(timeout: .now() + timeout)
        monitor.cancel()
        return result.value
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ new: Bool) { lock.withLock { flag = new } }
}

/// Turns cumulative per-process byte counts into bytes per app between readings.
public struct TrafficLedger: Sendable {
    private var previous: [pid_t: ProcessTraffic] = [:]
    private var hasBaseline = false

    public init() {}

    /// Bytes received and sent per app since the last call; the first call is the baseline. A process seen for the
    /// first time counts in full, since nettop counts from when it started.
    public mutating func add(_ readings: [ProcessTraffic], app: (pid_t) -> EnergyApp) -> [EnergyApp: (received: UInt64, sent: UInt64)] {
        defer {
            previous = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
            hasBaseline = true
        }
        guard hasBaseline else { return [:] }
        var used: [EnergyApp: (received: UInt64, sent: UInt64)] = [:]
        for reading in readings {
            // The same process ID with another name is a new process.
            let before = previous[reading.pid].flatMap { $0.name == reading.name ? $0 : nil }
            // Counters only grow while a process lives; a smaller number means its flows were reset.
            let received = reading.bytesIn >= (before?.bytesIn ?? 0) ? reading.bytesIn - (before?.bytesIn ?? 0) : reading.bytesIn
            let sent = reading.bytesOut >= (before?.bytesOut ?? 0) ? reading.bytesOut - (before?.bytesOut ?? 0) : reading.bytesOut
            guard received + sent > 0 else { continue }
            let owner = app(reading.pid)
            let total = used[owner] ?? (0, 0)
            used[owner] = (total.received + received, total.sent + sent)
        }
        return used
    }
}

/// Days of network use per app, by the hour, and what was used on expensive connections.
public struct NetworkHistory: Codable, Sendable, Equatable {
    public struct Hour: Codable, Sendable, Equatable {
        public let start: Date
        /// Bytes received and sent per app key.
        public var received: [String: UInt64] = [:]
        public var sent: [String: UInt64] = [:]
        /// Bytes used per app key while on an expensive connection (a hotspot).
        public var expensive: [String: UInt64] = [:]
    }

    public private(set) var hours: [Hour] = []
    public private(set) var apps: [String: EnergyApp] = [:]

    public init() {}

    public static let keepDays = 30.0

    public mutating func record(_ used: [EnergyApp: (received: UInt64, sent: UInt64)], expensive: Bool, at date: Date) {
        let start = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
        if hours.last?.start != start { hours.append(Hour(start: start)) }
        var hour = hours.removeLast()
        for (app, bytes) in used {
            apps[app.key] = app
            hour.received[app.key, default: 0] += bytes.received
            hour.sent[app.key, default: 0] += bytes.sent
            if expensive { hour.expensive[app.key, default: 0] += bytes.received + bytes.sent }
        }
        hours.append(hour)
        let cutoff = date.addingTimeInterval(-Self.keepDays * 86_400)
        hours.removeAll { $0.start < cutoff }
        let seen = Set(hours.flatMap { Array($0.received.keys) + Array($0.sent.keys) })
        apps = apps.filter { seen.contains($0.key) }
    }

    public mutating func clear() { self = NetworkHistory() }

    public struct Usage: Identifiable, Sendable, Equatable {
        public let app: EnergyApp
        public let received: UInt64
        public let sent: UInt64
        public var total: UInt64 { received + sent }
        public var id: String { app.key }
    }

    /// Apps by bytes used since `date`; with `expensiveOnly`, only what was used on a hotspot.
    public func usage(since date: Date, expensiveOnly: Bool = false) -> [Usage] {
        var received: [String: UInt64] = [:], sent: [String: UInt64] = [:]
        for hour in hours where hour.start.addingTimeInterval(3_600) > date {
            if expensiveOnly {
                for (key, bytes) in hour.expensive { received[key, default: 0] += bytes }
            } else {
                for (key, bytes) in hour.received { received[key, default: 0] += bytes }
                for (key, bytes) in hour.sent { sent[key, default: 0] += bytes }
            }
        }
        return Set(received.keys).union(sent.keys).compactMap { key in
            apps[key].map { Usage(app: $0, received: received[key] ?? 0, sent: sent[key] ?? 0) }
        }
        .filter { $0.total > 0 }
        .sorted { $0.total > $1.total }
    }

    /// Bytes used per hour since `date`, oldest first, for the chart.
    public func perHour(since date: Date) -> [(start: Date, bytes: UInt64)] {
        hours.filter { $0.start.addingTimeInterval(3_600) > date }.map { hour in
            (hour.start, hour.received.values.reduce(0, +) + hour.sent.values.reduce(0, +))
        }
    }
}
