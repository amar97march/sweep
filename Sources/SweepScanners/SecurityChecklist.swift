import Foundation
import SweepCore

/// One security setting and whether it's as it should be.
public struct SecurityCheck: Identifiable, Sendable, Equatable {
    public enum Status: Int, Sendable, Comparable {
        case good = 0, unknown = 1, warning = 2, problem = 3
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let title: String
    public let status: Status
    public let detail: String
    /// Where to change it, when System Settings can.
    public let fix: URL?

    public init(id: String, title: String, status: Status, detail: String, fix: URL? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}

/// Reads the settings that keep a Mac safe. Every check is read-only and needs no administrator rights.
public struct SecurityChecklist: Sendable {
    public var run: PerformanceScanner.Run
    public var readPlist: @Sendable (String) -> [String: Any]?
    public var now: Date

    public init(run: @escaping PerformanceScanner.Run = Shell.quick,
                readPlist: @escaping @Sendable (String) -> [String: Any]? = { NSDictionary(contentsOfFile: $0) as? [String: Any] },
                now: Date = Date()) {
        self.run = run
        self.readPlist = readPlist
        self.now = now
    }

    static func settings(_ pane: String) -> URL? { URL(string: "x-apple.systempreferences:" + pane) }

    public func checks() -> [SecurityCheck] {
        [fileVault(), firewall(), gatekeeper(), integrityProtection(), updates(), xprotect(), screenLock(), timeMachine()]
    }

    func fileVault() -> SecurityCheck {
        let output = run("/usr/bin/fdesetup", ["status"]).output
        let fix = Self.settings("com.apple.settings.PrivacySecurity.extension")
        if output.contains("FileVault is On") {
            return SecurityCheck(id: "fileVault", title: "FileVault", status: .good, detail: "Your disk is encrypted: a lost or stolen Mac doesn't give away your files.")
        }
        if output.contains("progress") {
            return SecurityCheck(id: "fileVault", title: "FileVault", status: .warning, detail: "Encryption is still in progress.", fix: fix)
        }
        if output.contains("FileVault is Off") {
            return SecurityCheck(id: "fileVault", title: "FileVault", status: .problem,
                                 detail: "Your disk isn't encrypted. Anyone with your Mac can read your files.", fix: fix)
        }
        return SecurityCheck(id: "fileVault", title: "FileVault", status: .unknown, detail: "Couldn't read the FileVault status.", fix: fix)
    }

    func firewall() -> SecurityCheck {
        let output = run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).output.lowercased()
        let fix = Self.settings("com.apple.Network-Settings.extension")
        if output.contains("enabled") {
            return SecurityCheck(id: "firewall", title: "Firewall", status: .good, detail: "Apps you haven't allowed can't accept incoming connections.")
        }
        if output.contains("disabled") {
            return SecurityCheck(id: "firewall", title: "Firewall", status: .warning,
                                 detail: "Off. Turn it on if you use public Wi-Fi: it blocks unexpected incoming connections.", fix: fix)
        }
        return SecurityCheck(id: "firewall", title: "Firewall", status: .unknown, detail: "Couldn't read the firewall status.", fix: fix)
    }

    func gatekeeper() -> SecurityCheck {
        let output = run("/usr/sbin/spctl", ["--status"]).output
        if output.contains("assessments enabled") {
            return SecurityCheck(id: "gatekeeper", title: "Gatekeeper", status: .good, detail: "Apps are checked for a valid developer signature before they open.")
        }
        if output.contains("disabled") {
            return SecurityCheck(id: "gatekeeper", title: "Gatekeeper", status: .problem,
                                 detail: "Turned off: apps open without being checked. Turn it back on with `sudo spctl --global-enable`.")
        }
        return SecurityCheck(id: "gatekeeper", title: "Gatekeeper", status: .unknown, detail: "Couldn't read the Gatekeeper status.")
    }

    func integrityProtection() -> SecurityCheck {
        let output = run("/usr/bin/csrutil", ["status"]).output
        if output.contains("status: enabled") {
            return SecurityCheck(id: "sip", title: "System Integrity Protection", status: .good, detail: "macOS's own files can't be changed, even by an administrator.")
        }
        if output.contains("disabled") {
            return SecurityCheck(id: "sip", title: "System Integrity Protection", status: .problem,
                                 detail: "Turned off: malware with your password can change macOS itself. Turn it back on from macOS Recovery.")
        }
        return SecurityCheck(id: "sip", title: "System Integrity Protection", status: .unknown, detail: "Couldn't read its status.")
    }

    func updates() -> SecurityCheck {
        let settings = readPlist("/Library/Preferences/com.apple.SoftwareUpdate.plist") ?? [:]
        let fix = Self.settings("com.apple.Software-Update-Settings.extension")
        func flag(_ key: String, default value: Bool) -> Bool { (settings[key] as? Bool) ?? (settings[key] as? Int).map { $0 != 0 } ?? value }
        if !flag("AutomaticCheckEnabled", default: true) {
            return SecurityCheck(id: "updates", title: "Automatic updates", status: .problem,
                                 detail: "macOS doesn't check for updates by itself.", fix: fix)
        }
        if !flag("CriticalUpdateInstall", default: true) {
            return SecurityCheck(id: "updates", title: "Automatic updates", status: .problem,
                                 detail: "Security responses and system files aren't installed automatically.", fix: fix)
        }
        if !flag("AutomaticallyInstallMacOSUpdates", default: false) {
            return SecurityCheck(id: "updates", title: "Automatic updates", status: .warning,
                                 detail: "Security fixes install by themselves, but macOS updates wait for you.", fix: fix)
        }
        return SecurityCheck(id: "updates", title: "Automatic updates", status: .good, detail: "macOS and its security fixes install automatically.")
    }

    func xprotect() -> SecurityCheck {
        // "Version: 5367 Installed: 2026-10-14 08:29:19 +0000"
        let output = run("/usr/bin/xprotect", ["version"]).output
        let version = output.range(of: #"Version: (\d+)"#, options: .regularExpression).map { String(output[$0].dropFirst(9)) }
        var installed: Date?
        if let range = output.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"#, options: .regularExpression) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            installed = formatter.date(from: String(output[range]))
        }
        guard let version else {
            return SecurityCheck(id: "xprotect", title: "Malware definitions", status: .unknown, detail: "Couldn't read the XProtect version.")
        }
        guard let installed else {
            return SecurityCheck(id: "xprotect", title: "Malware definitions", status: .good, detail: "XProtect version \(version).")
        }
        let days = Int(now.timeIntervalSince(installed) / 86_400)
        let when = installed.formatted(date: .abbreviated, time: .omitted)
        if days > 60 {
            return SecurityCheck(id: "xprotect", title: "Malware definitions", status: .warning,
                                 detail: "XProtect \(version) hasn't been updated since \(when). Make sure security responses install automatically.",
                                 fix: Self.settings("com.apple.Software-Update-Settings.extension"))
        }
        return SecurityCheck(id: "xprotect", title: "Malware definitions", status: .good, detail: "XProtect \(version), updated \(when).")
    }

    func screenLock() -> SecurityCheck {
        // Printed on standard error: "screenLock delay is 300 seconds", "screenLock is immediate", "screenLock is off".
        let output = run("/usr/sbin/sysadminctl", ["-screenLock", "status"]).output
        let fix = Self.settings("com.apple.Lock-Screen-Settings.extension")
        if output.contains("screenLock is off") {
            return SecurityCheck(id: "screenLock", title: "Password after sleep", status: .problem,
                                 detail: "Your Mac doesn't ask for a password when it wakes.", fix: fix)
        }
        if output.contains("immediate") {
            return SecurityCheck(id: "screenLock", title: "Password after sleep", status: .good, detail: "Asked for as soon as the screen locks.")
        }
        if let range = output.range(of: #"delay is (\d+) seconds"#, options: .regularExpression),
           let seconds = Int(output[range].split(separator: " ")[2]) {
            let minutes = max(1, seconds / 60)
            return SecurityCheck(id: "screenLock", title: "Password after sleep",
                                 status: seconds <= 300 ? .good : .warning,
                                 detail: seconds <= 300 ? "Asked for within \(minutes) \(minutes == 1 ? "minute" : "minutes") of locking."
                                                        : "Not asked for until \(minutes) minutes after locking. Five minutes or less is safer.",
                                 fix: seconds <= 300 ? nil : fix)
        }
        return SecurityCheck(id: "screenLock", title: "Password after sleep", status: .unknown, detail: "Couldn't read the setting.", fix: fix)
    }

    func timeMachine() -> SecurityCheck {
        let fix = Self.settings("com.apple.Time-Machine-Settings.extension")
        let destinations = run("/usr/bin/tmutil", ["destinationinfo"])
        if destinations.output.contains("No destinations configured") {
            return SecurityCheck(id: "backup", title: "Backups", status: .warning,
                                 detail: "Time Machine isn't set up. If you back up another way, you can ignore this.", fix: fix)
        }
        let latest = run("/usr/bin/tmutil", ["latestbackup"])
        if let range = latest.output.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            if let date = formatter.date(from: String(latest.output[range])) {
                let days = Int(now.timeIntervalSince(date) / 86_400)
                return SecurityCheck(id: "backup", title: "Backups", status: days > 7 ? .warning : .good,
                                     detail: days == 0 ? "Last Time Machine backup today." : "Last Time Machine backup \(days) \(days == 1 ? "day" : "days") ago.",
                                     fix: days > 7 ? fix : nil)
            }
        }
        return SecurityCheck(id: "backup", title: "Backups", status: .unknown,
                             detail: "Time Machine is set up; its last backup couldn't be read (the backup disk may not be connected).", fix: fix)
    }
}
