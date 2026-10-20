import Foundation

/// The battery's capacity and cycle count, once a day, to show how it ages.
public struct BatteryHealthLog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let date: Date
        /// Maximum capacity relative to design (0.85 = 85%).
        public let health: Double
        public let cycles: Int?
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Adds a reading unless one was taken less than a day ago. Keeps three years.
    public mutating func record(health: Double, cycles: Int?, at date: Date) {
        if let last = entries.last, date.timeIntervalSince(last.date) < 86_400 { return }
        entries.append(Entry(date: date, health: health, cycles: cycles))
        entries.removeAll { date.timeIntervalSince($0.date) > 3 * 365 * 86_400 }
    }

    /// Change in health (percentage points) and cycles over the readings since `date`, once they span a week.
    public func change(since date: Date) -> (health: Double, cycles: Int?, days: Double)? {
        let recent = entries.filter { $0.date >= date }
        guard let first = recent.first, let last = recent.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 7 else { return nil }
        let cycles: Int? = if let before = first.cycles, let after = last.cycles { after - before } else { nil }
        return ((last.health - first.health) * 100, cycles, days)
    }
}
