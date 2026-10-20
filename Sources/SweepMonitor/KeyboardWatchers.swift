import CoreGraphics
import Foundation

/// A process that receives keystrokes through a keyboard event tap: what keyloggers use, and also legitimate
/// tools (text expanders, shortcut and accessibility apps).
public struct KeyboardWatcher: Sendable, Equatable, Identifiable {
    public let pid: pid_t
    public let executable: String
    public let app: EnergyApp
    /// Only reads keystrokes (can't change or block them).
    public let listenOnly: Bool
    public let enabled: Bool

    public init(pid: pid_t, executable: String, app: EnergyApp, listenOnly: Bool, enabled: Bool) {
        self.pid = pid
        self.executable = executable
        self.app = app
        self.listenOnly = listenOnly
        self.enabled = enabled
    }

    public var id: String { "\(pid)|\(executable)" }
    /// Part of macOS (Siri, accessibility, the input system).
    public var isPartOfMacOS: Bool { ["/System/", "/usr/", "/Library/Apple/"].contains(where: executable.hasPrefix) }
}

public enum KeyboardWatchers {
    static let keyEvents: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    /// Every process with a keyboard tap right now, one entry per process (public API; no permission needed).
    public static func read() -> [KeyboardWatcher] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        var cache: [String: EnergyApp] = [:]
        return merge(taps.prefix(Int(count)).map { tap in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let path = proc_pidpath(tap.tappingProcess, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            return (pid: tap.tappingProcess, executable: path, mask: tap.eventsOfInterest, listenOnly: tap.options == .listenOnly,
                    enabled: tap.enabled, app: EnergyReader.app(forPID: tap.tappingProcess, cache: &cache))
        })
    }

    /// Keeps taps that see keys, merged per process: active and able to change keys if any of its taps is.
    static func merge(_ taps: [(pid: pid_t, executable: String, mask: CGEventMask, listenOnly: Bool, enabled: Bool, app: EnergyApp)])
        -> [KeyboardWatcher] {
        var byProcess: [pid_t: KeyboardWatcher] = [:]
        for tap in taps where tap.mask & keyEvents != 0 {
            let existing = byProcess[tap.pid]
            byProcess[tap.pid] = KeyboardWatcher(pid: tap.pid, executable: tap.executable, app: tap.app,
                                                 listenOnly: (existing?.listenOnly ?? true) && tap.listenOnly,
                                                 enabled: (existing?.enabled ?? false) || tap.enabled)
        }
        return byProcess.values.sorted { ($0.isPartOfMacOS ? 1 : 0, $0.app.name) < ($1.isPartOfMacOS ? 1 : 0, $1.app.name) }
    }
}
