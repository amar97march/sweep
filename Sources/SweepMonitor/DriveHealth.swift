import Foundation
import IOKit
import SweepNative

/// Wear and error counters an NVMe drive keeps about itself, read without administrator rights.
public struct DriveHealth: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable, Comparable {
        case good, watch, failing

        public static func < (a: Status, b: Status) -> Bool {
            let order: [Status] = [.good, .watch, .failing]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
    }

    /// Bits of the drive's own "critical warning" byte.
    public struct Warnings: OptionSet, Sendable, Codable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let spareBelowThreshold = Warnings(rawValue: 1 << 0)
        public static let temperature = Warnings(rawValue: 1 << 1)
        public static let reliabilityDegraded = Warnings(rawValue: 1 << 2)
        public static let readOnly = Warnings(rawValue: 1 << 3)
        public static let backupFailed = Warnings(rawValue: 1 << 4)
    }

    public var id: String { name + (isInternal ? "|internal" : "|external") }
    public var name: String
    public var isInternal: Bool
    public var capacity: UInt64?
    /// The drive's estimate of its rated endurance used up, 0–255 (can pass 100).
    public var percentageUsed: Int
    /// Spare blocks left, as a percentage, and the level below which the drive warns.
    public var availableSpare: Int
    public var spareThreshold: Int
    public var warnings: Warnings
    public var temperatureCelsius: Int?
    public var bytesWritten: UInt64
    public var bytesRead: UInt64
    public var powerOnHours: UInt64
    public var powerCycles: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64

    public init(name: String, isInternal: Bool, capacity: UInt64?, percentageUsed: Int, availableSpare: Int, spareThreshold: Int,
                warnings: Warnings, temperatureCelsius: Int?, bytesWritten: UInt64, bytesRead: UInt64, powerOnHours: UInt64,
                powerCycles: UInt64, unsafeShutdowns: UInt64, mediaErrors: UInt64) {
        self.name = name
        self.isInternal = isInternal
        self.capacity = capacity
        self.percentageUsed = percentageUsed
        self.availableSpare = availableSpare
        self.spareThreshold = spareThreshold
        self.warnings = warnings
        self.temperatureCelsius = temperatureCelsius
        self.bytesWritten = bytesWritten
        self.bytesRead = bytesRead
        self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
    }

    /// NVMe counts data in units of 1,000 sectors of 512 bytes.
    static let bytesPerDataUnit: UInt64 = 512_000

    init(name: String, isInternal: Bool, capacity: UInt64?, log: SweepNVMeHealth) {
        self.init(name: name, isInternal: isInternal, capacity: capacity, percentageUsed: Int(log.percentageUsed),
                  availableSpare: Int(log.availableSpare), spareThreshold: Int(log.availableSpareThreshold),
                  warnings: Warnings(rawValue: log.criticalWarning),
                  temperatureCelsius: log.temperatureKelvin > 0 ? Int(log.temperatureKelvin) - 273 : nil,
                  bytesWritten: log.dataUnitsWritten.multipliedReportingOverflow(by: Self.bytesPerDataUnit).partialValue,
                  bytesRead: log.dataUnitsRead.multipliedReportingOverflow(by: Self.bytesPerDataUnit).partialValue,
                  powerOnHours: log.powerOnHours, powerCycles: log.powerCycles,
                  unsafeShutdowns: log.unsafeShutdowns, mediaErrors: log.mediaErrors)
    }

    public var lifeLeft: Int { max(0, 100 - percentageUsed) }

    public var status: Status { problems.map(\.status).max() ?? .good }

    /// Everything worth telling the user, most serious first.
    public var problems: [(status: Status, text: String)] {
        var found: [(Status, String)] = []
        if warnings.contains(.readOnly) { found.append((.failing, "The drive has switched itself to read-only to protect your data.")) }
        if warnings.contains(.reliabilityDegraded) { found.append((.failing, "The drive reports that its reliability has degraded.")) }
        if warnings.contains(.backupFailed) { found.append((.failing, "The drive's power-loss protection has failed.")) }
        if warnings.contains(.spareBelowThreshold) || availableSpare < spareThreshold {
            found.append((.failing, "Spare blocks are below the drive's safe level (\(availableSpare)% left)."))
        }
        if percentageUsed >= 100 {
            found.append((.failing, "The drive has used up its rated endurance."))
        } else if percentageUsed >= 80 {
            found.append((.watch, "\(percentageUsed)% of the drive's rated endurance is used."))
        }
        if mediaErrors > 0 {
            found.append((.watch, "\(mediaErrors) unrecovered data \(mediaErrors == 1 ? "error" : "errors") so far."))
        }
        if warnings.contains(.temperature) { found.append((.watch, "The drive is running hotter than it should.")) }
        return found.sorted { $0.0 > $1.0 }
    }
}

public enum DriveHealthReader {
    /// Every connected drive that reports NVMe health: the internal SSD, and Thunderbolt NVMe enclosures that pass it
    /// on. USB drives rarely do, so they are left out.
    public static func read() -> [DriveHealth] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [DriveHealth] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard property(service, "NVMe SMART Capable") as? Bool == true else { continue }
            var log = SweepNVMeHealth()
            guard SweepReadNVMeHealth(service, &log) == 0 else { continue }
            let device = property(service, "Device Characteristics") as? [String: Any]
            let name = (device?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Drive"
            let location = (property(service, "Protocol Characteristics") as? [String: Any])?["Physical Interconnect Location"] as? String
            let size = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Size" as CFString, kCFAllocatorDefault,
                                                       IOOptionBits(kIORegistryIterateRecursively)) as? UInt64
            drives.append(DriveHealth(name: name.isEmpty ? "Drive" : name, isInternal: location != "External",
                                      capacity: size, log: log))
        }
        return drives.sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// Total bytes written, once a day, to tell how fast the drive is wearing now rather than over its whole life.
public struct DriveWriteLog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let date: Date
        public let bytesWritten: UInt64
    }

    public var entries: [String: [Entry]] = [:]

    public init() {}

    /// Adds a reading unless one was taken less than a day ago; keeps 120 days.
    public mutating func record(_ drive: DriveHealth, at date: Date) {
        var list = entries[drive.id] ?? []
        if let last = list.last, date.timeIntervalSince(last.date) < 86_400 { return }
        list.append(Entry(date: date, bytesWritten: drive.bytesWritten))
        entries[drive.id] = list.filter { date.timeIntervalSince($0.date) <= 120 * 86_400 }
    }

    /// Average bytes written per day between the oldest and newest readings, once they span at least a day.
    public func writtenPerDay(_ drive: DriveHealth) -> UInt64? {
        guard let list = entries[drive.id], let first = list.first, let last = list.last else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 1, last.bytesWritten >= first.bytesWritten else { return nil }
        return UInt64(Double(last.bytesWritten - first.bytesWritten) / days)
    }
}
