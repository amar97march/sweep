import Foundation
import IOKit.pwr_mgt

/// A power assertion that keeps the Mac (and optionally its display) from sleeping while it's held.
public struct PowerAssertions: Sendable {
    /// Takes an assertion and returns its ID, or nil if macOS refused.
    public var take: @Sendable (_ keepDisplayOn: Bool, _ reason: String) -> UInt32?
    public var release: @Sendable (UInt32) -> Void

    public init(take: @escaping @Sendable (Bool, String) -> UInt32?, release: @escaping @Sendable (UInt32) -> Void) {
        self.take = take
        self.release = release
    }

    /// The real thing: what `caffeinate` and similar tools use. Shows up in `pmset -g assertions` under Sweep.
    public static let system = PowerAssertions(take: { keepDisplayOn, reason in
        var id: IOPMAssertionID = 0
        let type = keepDisplayOn ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }, release: { id in
        IOPMAssertionRelease(id)
    })
}

/// How long to stay awake.
public enum KeepAwakeDuration: Codable, Sendable, Equatable, Hashable {
    case indefinitely
    case minutes(Int)
    /// Until the app with this bundle ID quits.
    case whileRunning(bundleID: String, name: String)

    public static let presets: [KeepAwakeDuration] = [.minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(300), .indefinitely]

    public var title: String {
        switch self {
        case .indefinitely: "Until turned off"
        case .minutes(let minutes) where minutes < 60: "\(minutes) minutes"
        case .minutes(let minutes) where minutes == 60: "1 hour"
        case .minutes(let minutes): minutes % 60 == 0 ? "\(minutes / 60) hours" : "\(minutes / 60) h \(minutes % 60) min"
        case .whileRunning(_, let name): "While \(name) is open"
        }
    }
}

/// What a keep-awake session is waiting for before it ends by itself.
public struct KeepAwakeSession: Sendable, Equatable {
    public let duration: KeepAwakeDuration
    public let started: Date
    public let keepsDisplayOn: Bool

    public init(duration: KeepAwakeDuration, started: Date, keepsDisplayOn: Bool) {
        self.duration = duration
        self.started = started
        self.keepsDisplayOn = keepsDisplayOn
    }

    public var endDate: Date? {
        if case .minutes(let minutes) = duration { return started.addingTimeInterval(TimeInterval(minutes) * 60) }
        return nil
    }

    public enum EndReason: Equatable, Sendable {
        case timeUp
        case appQuit(String)
        case batteryLow(Int)
    }

    /// Whether the session should end now: its time is up, the app it follows is gone, or the battery is below
    /// `batteryFloor` (a percentage) while not charging.
    public func endReason(now: Date, runningBundleIDs: Set<String>, batteryPercent: Int?, onBattery: Bool,
                          batteryFloor: Int?) -> EndReason? {
        if let end = endDate, now >= end { return .timeUp }
        if case .whileRunning(let bundleID, let name) = duration, !runningBundleIDs.contains(bundleID) { return .appQuit(name) }
        if let floor = batteryFloor, onBattery, let percent = batteryPercent, percent <= floor { return .batteryLow(floor) }
        return nil
    }
}
