import Darwin
import Foundation

/// How short of memory macOS is, as the kernel reports it (Activity Monitor's Memory Pressure graph).
public enum MemoryPressure: Int, Sendable, Comparable, Codable {
    case normal = 1, warning = 2, critical = 4

    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }

    public static func current() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.stride
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }
}

/// Spots apps that hog memory while macOS is short of it: one taking a large share of it, or one that keeps
/// growing (the sign of a leak).
public struct MemoryHogDetector: Sendable {
    public struct Hog: Sendable, Equatable {
        public let app: EnergyApp
        public let bytes: UInt64
        /// Bytes it grew over the readings kept, when it's growing.
        public let growth: UInt64
    }

    private var history: [String: [UInt64]] = [:]
    private var reported: Set<String> = []

    public init() {}

    public var flagged: Set<String> { reported }

    /// Adds one reading. Apps are reported once, while memory pressure isn't normal, if they use at least
    /// `share` of physical memory (and 1.5 GB), or have grown by 1 GB or a tenth of memory, whichever is more,
    /// across the last `window` readings.
    public mutating func add(_ readings: [ProcessCPU], pressure: MemoryPressure, totalMemory: UInt64, share: Double = 0.25,
                             window: Int = 10, ignoring: Set<String> = []) -> [Hog] {
        var footprints: [EnergyApp: UInt64] = [:]
        for reading in readings where reading.app != .system && !ignoring.contains(reading.app.key) {
            footprints[reading.app, default: 0] += reading.memory
        }
        for (app, bytes) in footprints {
            var list = history[app.key] ?? []
            list.append(bytes)
            if list.count > window { list.removeFirst(list.count - window) }
            history[app.key] = list
        }
        let present = Set(footprints.keys.map(\.key))
        history = history.filter { present.contains($0.key) }

        let large = max(UInt64(Double(totalMemory) * share), 1_500_000_000)
        let leak = max(1_000_000_000, totalMemory / 10)
        func growth(_ key: String) -> UInt64 {
            guard let list = history[key], list.count >= max(3, window / 2), let first = list.first, let last = list.last,
                  last > first, zip(list, list.dropFirst()).filter({ $1 < $0 }).count <= list.count / 4 else { return 0 }
            return last - first
        }
        // Calm again: below the line and not growing, or memory no longer short.
        for key in reported {
            let bytes = footprints.first { $0.key.key == key }?.value ?? 0
            if pressure == .normal || (bytes < large * 4 / 5 && growth(key) < leak) { reported.remove(key) }
        }
        guard pressure > .normal else { return [] }
        var found: [Hog] = []
        for (app, bytes) in footprints {
            let grown = growth(app.key)
            guard bytes >= large || grown >= leak, reported.insert(app.key).inserted else { continue }
            found.append(Hog(app: app, bytes: bytes, growth: grown >= leak ? grown : 0))
        }
        return found.sorted { $0.bytes > $1.bytes }
    }
}
