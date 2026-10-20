import Foundation

/// How hot the Mac is running, as macOS reports it to apps. From `serious` on, it slows the processor down to cool.
public enum ThermalLevel: Int, Codable, Sendable, Comparable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }

    public var isThrottling: Bool { self >= .serious }

    public var title: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot: slowed down"
        case .critical: "Very hot: slowed down a lot"
        }
    }
}

/// Stretches of time the Mac slowed itself down because of heat.
public struct ThermalLog: Codable, Sendable, Equatable {
    public struct Episode: Codable, Sendable, Equatable, Identifiable {
        public let start: Date
        public var end: Date?
        public var peak: ThermalLevel
        /// The app using the most processor time when it started, if known.
        public var busiestApp: String?
        public var id: Date { start }
        public func duration(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
    }

    public private(set) var episodes: [Episode] = []

    public init() {}

    public static let keepDays = 30.0

    public var current: Episode? { episodes.last.flatMap { $0.end == nil ? $0 : nil } }

    /// Records the level at `date`. Returns true when a new hot spell begins (one that ended less than two minutes
    /// earlier is continued instead).
    @discardableResult
    public mutating func record(_ level: ThermalLevel, at date: Date, busiestApp: String? = nil) -> Bool {
        defer { episodes.removeAll { ($0.end ?? date) < date.addingTimeInterval(-Self.keepDays * 86_400) } }
        if level.isThrottling {
            if var last = episodes.last, last.end == nil {
                last.peak = max(last.peak, level)
                episodes[episodes.count - 1] = last
                return false
            }
            if var last = episodes.last, let end = last.end, date.timeIntervalSince(end) < 120 {
                last.end = nil
                last.peak = max(last.peak, level)
                episodes[episodes.count - 1] = last
                return false
            }
            episodes.append(Episode(start: date, end: nil, peak: level, busiestApp: busiestApp))
            return true
        }
        if var last = episodes.last, last.end == nil {
            last.end = date
            episodes[episodes.count - 1] = last
        }
        return false
    }

    /// How often and how long the Mac was slowed down since `date`.
    public func summary(since date: Date, now: Date = Date()) -> (count: Int, total: TimeInterval, longest: TimeInterval) {
        let recent = episodes.filter { ($0.end ?? now) >= date }
        let durations = recent.map { $0.duration(now: now) }
        return (recent.count, durations.reduce(0, +), durations.max() ?? 0)
    }

    public mutating func clear() { episodes = [] }
}
