import Foundation
import SweepCore
import SweepMonitor
import SweepScanners

/// Sample data for the Intel-only, network, privacy, security, alerts and battery health screenshots. Never acted on.
extension DemoData {
    static var intelApps: ScanCategory {
        func app(_ name: String, _ version: String, days: Double, size: UInt64) -> ScanItem {
            ScanItem(id: "intel:/Applications/\(name).app", title: name,
                     subtitle: "Intel only · version \(version) · last opened " + Date().addingTimeInterval(-days * 86_400).formatted(date: .abbreviated, time: .omitted),
                     size: size, date: Date().addingTimeInterval(-days * 86_400), isSelectedByDefault: false,
                     action: .custom(kind: "demo", payload: []))
        }
        return ScanCategory(id: "intelApps", title: "Intel-only Apps",
                            summary: "These run through Rosetta, which macOS includes only up to macOS 27. Look for an Apple silicon version, or remove the ones you don't need.",
                            symbol: "cpu", groups: [ScanGroup(id: "intel", title: "Need Rosetta", subtitle: "3 apps", icon: .symbol("cpu"), items: [
                                app("Label Printer Utility", "2.4", days: 12, size: 186_000_000),
                                app("Classic Synth", "1.9.3", days: 140, size: 1_240_000_000),
                                app("Old Scanner Driver", "5.0", days: 400, size: 94_000_000),
                            ])])
    }

    static var networkHistory: NetworkHistory {
        let apps = [
            (EnergyApp(key: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app"), 900_000_000.0, 60_000_000.0),
            (EnergyApp(key: "com.getdropbox.dropbox", name: "Dropbox", path: "/Applications/Dropbox.app"), 120_000_000, 640_000_000),
            (EnergyApp(key: "us.zoom.xos", name: "Zoom", path: "/Applications/zoom.us.app"), 380_000_000, 310_000_000),
            (.system, 260_000_000, 40_000_000),
            (EnergyApp(key: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app"), 90_000_000, 12_000_000),
            (EnergyApp(key: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app"), 210_000_000, 4_000_000),
        ]
        var history = NetworkHistory()
        let start = Date().addingTimeInterval(-23 * 3_600)
        for hour in 0..<24 {
            let factor = hour >= 9 && hour <= 18 ? 1.0 : 0.25
            var used: [EnergyApp: (received: UInt64, sent: UInt64)] = [:]
            for (app, received, sent) in apps {
                let wave = 0.6 + 0.4 * sin(Double(hour) + received / 1e8)
                used[app] = (UInt64(received / 24 * factor * wave * 2), UInt64(sent / 24 * factor * wave * 2))
            }
            history.record(used, expensive: hour >= 20, at: start.addingTimeInterval(Double(hour) * 3_600))
        }
        return history
    }

    static var batteryHealthLog: BatteryHealthLog {
        var log = BatteryHealthLog()
        let start = Date().addingTimeInterval(-120 * 86_400)
        for day in stride(from: 0, through: 120, by: 3) {
            let health = 0.885 - Double(day) * 0.00028 - (day > 60 ? 0.004 : 0)
            log.record(health: health, cycles: 248 + day * 47 / 120, at: start.addingTimeInterval(Double(day) * 86_400))
        }
        return log
    }

    static var permissions: [TCCPermissions.Entry] {
        [("kTCCServiceSystemPolicyAllFiles", "com.googlecode.iterm2"), ("kTCCServiceSystemPolicyAllFiles", "com.apple.Terminal"),
         ("kTCCServiceAccessibility", "com.raycast.macos"), ("kTCCServiceAccessibility", "com.pilotmoon.scroll-reverser"),
         ("kTCCServiceAccessibility", "com.example.helper"), ("kTCCServiceScreenCapture", "us.zoom.xos"),
         ("kTCCServiceScreenCapture", "com.microsoft.teams2"), ("kTCCServiceListenEvent", "com.raycast.macos"),
         ("kTCCServiceListenEvent", "com.example.helper"), ("kTCCServiceAppleEvents", "com.raycast.macos")]
            .map { TCCPermissions.Entry(service: $0.0, client: $0.1) }
    }

    static let privacyAppNames = ["com.googlecode.iterm2": "iTerm", "com.apple.Terminal": "Terminal", "com.raycast.macos": "Raycast",
                                  "com.pilotmoon.scroll-reverser": "Scroll Reverser", "com.example.helper": "helper",
                                  "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams"]

    static var keyboardWatchers: (watchers: [KeyboardWatcher], signers: [String: Signer]) {
        let unknown = "/Users/demo/Library/Application Support/.sys/kbd-helper"
        let watchers = [
            KeyboardWatcher(pid: 801, executable: "/Applications/Raycast.app/Contents/MacOS/Raycast",
                            app: EnergyApp(key: "com.raycast.macos", name: "Raycast", path: "/Applications/Raycast.app"),
                            listenOnly: false, enabled: true),
            KeyboardWatcher(pid: 902, executable: unknown, app: EnergyApp(key: unknown, name: "kbd-helper", path: nil),
                            listenOnly: true, enabled: true),
            KeyboardWatcher(pid: 770, executable: "/System/Library/CoreServices/Siri.app/Contents/MacOS/Siri", app: .system,
                            listenOnly: false, enabled: true),
            KeyboardWatcher(pid: 605, executable: "/usr/sbin/universalaccessd", app: EnergyApp(key: "ua", name: "universalaccessd", path: nil),
                            listenOnly: true, enabled: true),
        ]
        return (watchers, ["/Applications/Raycast.app": .developerID(name: "Raycast Technologies Inc.", team: "SY64MV22J9", notarized: true),
                           unknown: .unsigned])
    }

    static var securityChecks: [SecurityCheck] {
        [SecurityCheck(id: "fileVault", title: "FileVault", status: .good, detail: "Your disk is encrypted: a lost or stolen Mac doesn't give away your files."),
         SecurityCheck(id: "firewall", title: "Firewall", status: .warning,
                       detail: "Off. Turn it on if you use public Wi-Fi: it blocks unexpected incoming connections.",
                       fix: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")),
         SecurityCheck(id: "gatekeeper", title: "Gatekeeper", status: .good, detail: "Apps are checked for a valid developer signature before they open."),
         SecurityCheck(id: "sip", title: "System Integrity Protection", status: .good, detail: "macOS's own files can't be changed, even by an administrator."),
         SecurityCheck(id: "updates", title: "Automatic updates", status: .good, detail: "macOS and its security fixes install automatically."),
         SecurityCheck(id: "xprotect", title: "Malware definitions", status: .good, detail: "XProtect 5367, updated Oct 14, 2026."),
         SecurityCheck(id: "screenLock", title: "Password after sleep", status: .good, detail: "Asked for within 5 minutes of locking."),
         SecurityCheck(id: "backup", title: "Backups", status: .warning, detail: "Time Machine isn't set up. If you back up another way, you can ignore this.",
                       fix: URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"))]
    }

    static var diskSpeed: DiskSpeed.Result { DiskSpeed.Result(write: 5_840_000_000, read: 6_420_000_000, date: Date().addingTimeInterval(-3_600)) }

    static var alerts: (runaways: [AlertsModel.Runaway], accessories: [Accessory], leftovers: [ScanCategory]) {
        let chrome = EnergyApp(key: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app")
        let leftovers = ScanCategory(id: "trashedLeftovers", title: "Left by Zoom",
                                     summary: "Zoom is in the Trash, but these files of it are still on your Mac.", symbol: "trash.slash.fill",
                                     groups: [ScanGroup(id: "trashed:us.zoom.xos", title: "Zoom", subtitle: "Moved to the Trash", icon: .symbol("video.fill"), items: [
                                         ScanItem(id: "t1", title: "Application Support", subtitle: "~/Library/Application Support/zoom.us",
                                                  size: 180_000_000, isSelectedByDefault: true, action: .custom(kind: "demo", payload: [])),
                                         ScanItem(id: "t2", title: "Caches", subtitle: "~/Library/Caches/us.zoom.xos",
                                                  size: 140_000_000, isSelectedByDefault: true, action: .custom(kind: "demo", payload: [])),
                                     ])])
        return ([AlertsModel.Runaway(app: chrome, usage: 1.32, since: Date().addingTimeInterval(-7 * 60))],
                [Accessory(name: "AirPods Pro", kind: "Headphones", levels: ["Left": 72, "Right": 70, "Case": 45]),
                 Accessory(name: "Magic Mouse", kind: "Mouse", levels: ["Main": 15])],
                [leftovers])
    }
}

/// Usage, heat and memory samples for screenshots.
extension DemoData {
    static var appUsage: AppUsageHistory {
        let apps = [
            (EnergyApp(key: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app"), 2.6),
            (EnergyApp(key: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app"), 1.9),
            (EnergyApp(key: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app"), 0.9),
            (EnergyApp(key: "com.apple.Terminal", name: "Terminal", path: "/System/Applications/Utilities/Terminal.app"), 0.7),
            (EnergyApp(key: "com.apple.mail", name: "Mail", path: "/System/Applications/Mail.app"), 0.4),
            (EnergyApp(key: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app"), 0.2),
        ]
        var history = AppUsageHistory()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for dayOffset in stride(from: -6, through: 0, by: 1) {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            let weekend = calendar.isDateInWeekend(day)
            var cursor = day.addingTimeInterval(9 * 3_600)
            let end = dayOffset == 0 ? min(Date(), day.addingTimeInterval(19 * 3_600)) : day.addingTimeInterval(19 * 3_600)
            var index = 0
            while cursor < end {
                let (app, weight) = apps[index % apps.count]
                let minutes = weight * (weekend ? 6 : 14) * (1 + 0.3 * sin(Double(index)))
                let stop = min(end, cursor.addingTimeInterval(minutes * 60))
                history.add(app, from: cursor, to: stop)
                cursor = stop.addingTimeInterval(weekend ? 30 * 60 : 4 * 60)
                index += 1
            }
        }
        return history
    }

    static var thermalLog: ThermalLog {
        var log = ThermalLog()
        let now = Date()
        log.record(.serious, at: now.addingTimeInterval(-3 * 86_400), busiestApp: "Xcode")
        log.record(.nominal, at: now.addingTimeInterval(-3 * 86_400 + 11 * 60))
        log.record(.critical, at: now.addingTimeInterval(-26 * 3_600), busiestApp: "Google Chrome")
        log.record(.nominal, at: now.addingTimeInterval(-26 * 3_600 + 4 * 60))
        log.record(.serious, at: now.addingTimeInterval(-6 * 60), busiestApp: "Xcode")
        return log
    }

    static var memoryHogs: [AlertsModel.MemoryHog] {
        [AlertsModel.MemoryHog(app: EnergyApp(key: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app"),
                               bytes: 7_400_000_000, growth: 2_100_000_000)]
    }
}
