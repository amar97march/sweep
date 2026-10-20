import CoreAudio
import CoreMediaIO
import Foundation

/// A privacy-sensitive device an app can use, as the menu bar's privacy indicator reports it.
public enum Sensor: String, Codable, Sendable, CaseIterable, Identifiable {
    case camera, microphone, screen

    public var id: String { rawValue }

    /// The prefix Control Center logs for each ("cam:com.example.App").
    init?(logPrefix: Substring) {
        switch logPrefix {
        case "cam": self = .camera
        case "mic": self = .microphone
        case "scr": self = .screen
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .screen: "Screen recording"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .screen: "rectangle.dashed.badge.record"
        }
    }
}

/// One app using one sensor.
public struct SensorUse: Hashable, Sendable, Codable {
    public let sensor: Sensor
    public let bundleID: String

    public init(sensor: Sensor, bundleID: String) {
        self.sensor = sensor
        self.bundleID = bundleID
    }
}

/// A stretch of time an app used the camera, microphone or screen recording.
public struct SensorSession: Codable, Sendable, Equatable, Identifiable {
    public let sensor: Sensor
    public let bundleID: String
    public let start: Date
    /// Nil while it's still in use.
    public var end: Date?

    public init(sensor: Sensor, bundleID: String, start: Date, end: Date?) {
        self.sensor = sensor
        self.bundleID = bundleID
        self.start = start
        self.end = end
    }

    public var id: String { "\(sensor.rawValue)|\(bundleID)|\(start.timeIntervalSince1970)" }
    public var use: SensorUse { SensorUse(sensor: sensor, bundleID: bundleID) }
    public func duration(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}

/// macOS keeps no history of camera and microphone use, but Control Center logs every change of its privacy
/// indicator ("Active activity attributions changed to ["cam:…", "mic:…"]") with the apps' bundle IDs. The log
/// keeps a few days of these; Sweep imports them as they come and keeps its own history.
public enum SensorLog {
    /// What was in use from `date` on.
    public struct Change: Equatable, Sendable {
        public let date: Date
        public let active: Set<SensorUse>

        public init(date: Date, active: Set<SensorUse>) {
            self.date = date
            self.active = active
        }
    }

    static let predicate = #"subsystem == "com.apple.controlcenter" AND category == "sensor-indicators" AND eventMessage BEGINSWITH "Active activity attributions changed to""#

    /// The uses listed in one log message, or nil if it isn't an attribution change.
    public static func uses(inMessage message: String) -> Set<SensorUse>? {
        guard let open = message.firstIndex(of: "["), message.hasPrefix("Active activity attributions changed to"),
              let close = message.lastIndex(of: "]"), open < close else { return nil }
        var uses = Set<SensorUse>()
        for entry in message[message.index(after: open)..<close].split(separator: ",") {
            let text = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).replacingOccurrences(of: "\\\"", with: "")
            guard let colon = text.firstIndex(of: ":"), let sensor = Sensor(logPrefix: text[..<colon]) else { continue }
            let bundleID = String(text[text.index(after: colon)...])
            if !bundleID.isEmpty { uses.insert(SensorUse(sensor: sensor, bundleID: bundleID)) }
        }
        return uses
    }

    /// Changes in `log show --style ndjson` output, oldest first.
    public static func changes(fromNDJSON output: String) -> [Change] {
        var changes: [Change] = []
        for line in output.split(separator: "\n") where line.hasPrefix("{") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = json["eventMessage"] as? String, let uses = uses(inMessage: message),
                  let stamp = json["timestamp"] as? String, let date = date(fromLogTimestamp: stamp) else { continue }
            changes.append(Change(date: date, active: uses))
        }
        return changes.sorted { $0.date < $1.date }
    }

    /// "2026-10-19 23:37:01.599584+0530"
    static func date(fromLogTimestamp text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter.date(from: text)
    }

    public typealias Run = @Sendable (String, [String]) -> String?

    /// Reads the changes logged after `since` (or in the last week), or nil if the log couldn't be read.
    /// Read-only; needs no special permission.
    public static func read(since: Date?, run: Run = SensorLog.runCommand) -> [Change]? {
        var arguments = ["show", "--style", "ndjson", "--predicate", predicate]
        if let since {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            arguments += ["--start", formatter.string(from: since)]
        } else {
            arguments += ["--last", "7d"]
        }
        return run("/usr/bin/log", arguments).map(changes(fromNDJSON:))
    }

    public static let runCommand: Run = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Every camera, microphone and screen recording session Sweep has seen.
public struct SensorHistory: Codable, Sendable, Equatable {
    public private(set) var sessions: [SensorSession] = []
    /// The newest change imported, so the next import starts there.
    public private(set) var readThrough: Date?

    public init(sessions: [SensorSession] = [], readThrough: Date? = nil) {
        self.sessions = sessions
        self.readThrough = readThrough
    }

    /// History is kept this long.
    public static let keepDays = 90.0

    /// Turns indicator changes into sessions. A use that stops and starts again within two seconds (an app
    /// reopening the camera) stays one session. A session still open from before the Mac last started is closed
    /// at the restart.
    public mutating func apply(_ changes: [SensorLog.Change], bootTime: Date? = nil, now: Date = Date()) {
        if let bootTime {
            for index in sessions.indices where sessions[index].end == nil && sessions[index].start < bootTime {
                sessions[index].end = bootTime
            }
        }
        for change in changes.sorted(by: { $0.date < $1.date }) where readThrough.map({ change.date > $0 }) ?? true {
            for index in sessions.indices where sessions[index].end == nil && !change.active.contains(sessions[index].use) {
                sessions[index].end = change.date
            }
            let open = Set(sessions.filter { $0.end == nil }.map(\.use))
            for use in change.active.subtracting(open).sorted(by: { ($0.sensor.rawValue, $0.bundleID) < ($1.sensor.rawValue, $1.bundleID) }) {
                if let index = sessions.lastIndex(where: { $0.use == use }), let end = sessions[index].end,
                   change.date.timeIntervalSince(end) <= 2 {
                    sessions[index].end = nil
                } else {
                    sessions.append(SensorSession(sensor: use.sensor, bundleID: use.bundleID, start: change.date, end: nil))
                }
            }
            readThrough = change.date
        }
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86_400)
        sessions.removeAll { ($0.end ?? now) < cutoff }
        sessions.sort { $0.start < $1.start }
    }

    public mutating func clear() {
        sessions = []
    }

    public var inUse: [SensorSession] { sessions.filter { $0.end == nil } }

    /// Per app and sensor since `date`: how often, for how long, and when last.
    public struct Summary: Identifiable, Sendable, Equatable {
        public let use: SensorUse
        public let sessions: Int
        public let duration: TimeInterval
        public let lastUsed: Date
        public let inUse: Bool
        public var id: String { use.sensor.rawValue + "|" + use.bundleID }
    }

    public func summary(since date: Date, now: Date = Date()) -> [Summary] {
        let recent = sessions.filter { ($0.end ?? now) >= date }
        return Dictionary(grouping: recent, by: \.use).map { use, sessions in
            Summary(use: use, sessions: sessions.count,
                    duration: sessions.reduce(0) { $0 + $1.duration(now: now) - max(0, date.timeIntervalSince($1.start)) },
                    lastUsed: sessions.map { $0.end ?? now }.max() ?? now, inUse: sessions.contains { $0.end == nil })
        }
        .sorted { ($0.inUse ? 1 : 0, $0.lastUsed) > ($1.inUse ? 1 : 0, $1.lastUsed) }
    }
}

/// What's using the camera and microphone this moment, straight from the audio and video systems.
public enum SensorLive {
    /// Bundle IDs of the apps recording from a microphone right now (macOS 14.2 and later).
    public static func microphoneUsers() -> Set<String> {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        var users = Set<String>()
        for object in objects {
            var running: UInt32 = 0
            guard read(object, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            var bundleID: Unmanaged<CFString>?
            if read(object, kAudioProcessPropertyBundleID, &bundleID), let value = bundleID?.takeRetainedValue() as String?, !value.isEmpty {
                users.insert(value)
            }
        }
        return users
    }

    /// Whether any camera is on (which app is using it comes from the indicator log).
    public static func cameraIsOn() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        return devices.contains { device in
            var running: UInt32 = 0
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var length: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &length, &running) == noErr
                && running != 0
        }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}

/// When this Mac last started.
public enum BootTime {
    public static var current: Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
