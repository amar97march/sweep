import Foundation

/// How long each app was in front while you were using the Mac, by day and hour.
public struct AppUsageHistory: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable {
        public let start: Date
        /// Seconds per app key.
        public var apps: [String: Double] = [:]
        /// Seconds of use per hour of the day (0–23).
        public var hours: [Int: Double] = [:]
    }

    public private(set) var days: [Day] = []
    public private(set) var apps: [String: EnergyApp] = [:]

    public init() {}

    public static let keepDays = 90.0

    /// Adds the time `app` was in front, split across hours and days.
    public mutating func add(_ app: EnergyApp, from start: Date, to end: Date, calendar: Calendar = .current) {
        guard end > start else { return }
        apps[app.key] = app
        var cursor = start
        while cursor < end {
            let hour = calendar.dateInterval(of: .hour, for: cursor) ?? DateInterval(start: cursor, duration: 3_600)
            let stop = min(end, hour.end)
            let seconds = stop.timeIntervalSince(cursor)
            let dayStart = calendar.startOfDay(for: cursor)
            if days.last?.start != dayStart {
                if let index = days.firstIndex(where: { $0.start == dayStart }) {
                    let day = days.remove(at: index)
                    days.append(day)
                } else {
                    days.append(Day(start: dayStart))
                }
            }
            days[days.count - 1].apps[app.key, default: 0] += seconds
            days[days.count - 1].hours[calendar.component(.hour, from: cursor), default: 0] += seconds
            cursor = stop
        }
        days.sort { $0.start < $1.start }
        let cutoff = end.addingTimeInterval(-Self.keepDays * 86_400)
        days.removeAll { $0.start < calendar.startOfDay(for: cutoff) }
        let used = Set(days.flatMap { $0.apps.keys })
        apps = apps.filter { used.contains($0.key) }
    }

    public mutating func clear() { self = AppUsageHistory() }

    public struct Usage: Identifiable, Sendable, Equatable {
        public let app: EnergyApp
        public let seconds: Double
        public let share: Double
        public var id: String { app.key }
    }

    /// Apps by time in front since `date` (whole days).
    public func usage(since date: Date, calendar: Calendar = .current) -> [Usage] {
        var totals: [String: Double] = [:]
        for day in days where day.start >= calendar.startOfDay(for: date) {
            for (key, seconds) in day.apps { totals[key, default: 0] += seconds }
        }
        let sum = totals.values.reduce(0, +)
        return totals.compactMap { key, seconds in apps[key].map { Usage(app: $0, seconds: seconds, share: sum > 0 ? seconds / sum : 0) } }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Seconds of use per day since `date`, oldest first, including days without use.
    public func perDay(since date: Date, until now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, seconds: Double)] {
        var result: [(Date, Double)] = []
        var day = calendar.startOfDay(for: date)
        let last = calendar.startOfDay(for: now)
        while day <= last {
            result.append((day, days.first { $0.start == day }?.apps.values.reduce(0, +) ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Seconds of use in each hour of `day`.
    public func perHour(of day: Date, calendar: Calendar = .current) -> [(hour: Int, seconds: Double)] {
        let start = calendar.startOfDay(for: day)
        let hours = days.first { $0.start == start }?.hours ?? [:]
        return (0..<24).map { ($0, hours[$0] ?? 0) }
    }
}

/// Follows which app is in front and turns it into intervals. Time while the Mac is asleep, locked or idle isn't
/// counted.
public struct UsageRecorder: Sendable {
    public private(set) var current: (app: EnergyApp, since: Date)?

    public init() {}

    /// A new app came to the front (or use resumed with it in front). Returns the interval that just ended.
    public mutating func activate(_ app: EnergyApp?, at date: Date) -> (app: EnergyApp, start: Date, end: Date)? {
        let ended = stop(at: date)
        if let app { current = (app, date) }
        return ended
    }

    /// Use paused (sleep, lock, or idle since `date`). Returns the interval that ended.
    public mutating func stop(at date: Date) -> (app: EnergyApp, start: Date, end: Date)? {
        defer { current = nil }
        guard let current, date > current.since else { return nil }
        return (current.app, current.since, date)
    }

    /// Ends the running interval at `date` and starts the same app again, so long sessions are saved as they go.
    public mutating func checkpoint(at date: Date) -> (app: EnergyApp, start: Date, end: Date)? {
        guard let running = current?.app else { return nil }
        return activate(running, at: date)
    }
}
