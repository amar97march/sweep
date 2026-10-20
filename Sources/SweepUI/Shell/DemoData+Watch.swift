import Foundation
import SweepCore
import SweepMonitor
import SweepScanners

/// Sample data for the Updater, Activity, drive health and Keep Awake screenshots. Never acted on: the screenshot
/// run uses inert engines, so no button can install, switch or record anything.
extension DemoData {
    static var updates: [AppUpdate] {
        [
            AppUpdate(appPath: "/Applications/Visual Studio Code.app", appName: "Visual Studio Code", bundleID: "com.microsoft.VSCode",
                      installedVersion: "1.104.2", newVersion: "1.105.0",
                      source: .sparkle(download: URL(string: "https://example.com/vscode.zip")!, edSignature: nil, length: nil),
                      releaseNotes: "<h2>October update</h2><ul><li>Faster search in large workspaces</li><li>Fixes for terminal rendering</li></ul>",
                      releaseNotesURL: URL(string: "https://example.com/vscode/notes")),
            AppUpdate(appPath: "/Applications/iTerm.app", appName: "iTerm", bundleID: "com.googlecode.iterm2",
                      installedVersion: "3.5.9", newVersion: "3.6.0",
                      source: .sparkle(download: URL(string: "https://example.com/iterm.zip")!, edSignature: nil, length: nil),
                      releaseNotes: "<p>Adds AI chat history search and fixes a crash when closing split panes.</p>"),
            AppUpdate(appPath: "/Applications/Firefox.app", appName: "Firefox", bundleID: "org.mozilla.firefox",
                      installedVersion: "143.0", newVersion: "144.0.1", source: .homebrew(token: "firefox"), releaseNotes: nil),
            AppUpdate(appPath: "/Applications/Pages.app", appName: "Pages", bundleID: "com.apple.iWork.Pages",
                      installedVersion: "14.4", newVersion: "14.5", source: .appStore(page: URL(string: "https://apps.apple.com/app/pages")!),
                      releaseNotes: "Stability and performance improvements."),
            AppUpdate(appPath: "/Applications/Slack.app", appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                      installedVersion: "4.46.99", newVersion: "4.47.59",
                      source: .sparkle(download: URL(string: "https://example.com/slack.zip")!, edSignature: nil, length: nil),
                      releaseNotes: nil),
        ]
    }

    static var sensorHistory: SensorHistory {
        let now = Date()
        func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3_600) }
        func use(_ sensor: Sensor, _ bundleID: String) -> SensorUse { SensorUse(sensor: sensor, bundleID: bundleID) }
        let zoomCam = use(.camera, "us.zoom.xos"), zoomMic = use(.microphone, "us.zoom.xos")
        let changes: [SensorLog.Change] = [
            .init(date: at(50), active: [use(.camera, "com.apple.FaceTime"), use(.microphone, "com.apple.FaceTime")]),
            .init(date: at(49.6), active: []),
            .init(date: at(27), active: [use(.screen, "com.apple.QuickTimePlayerX")]),
            .init(date: at(26.8), active: []),
            .init(date: at(5.2), active: [use(.microphone, "com.tinyspeck.slackmacgap")]),
            .init(date: at(4.9), active: []),
            .init(date: at(2.1), active: [zoomCam, zoomMic]),
            .init(date: at(1.4), active: [zoomMic]),
            .init(date: at(1.2), active: []),
            .init(date: at(0.15), active: [use(.camera, "com.microsoft.teams2"), use(.microphone, "com.microsoft.teams2")]),
        ]
        var history = SensorHistory()
        history.apply(changes, now: now)
        return history
    }

    static let sensorAppNames = ["us.zoom.xos": "Zoom", "com.apple.FaceTime": "FaceTime", "com.apple.QuickTimePlayerX": "QuickTime Player",
                                 "com.tinyspeck.slackmacgap": "Slack", "com.microsoft.teams2": "Microsoft Teams"]

    static var backgroundItems: (items: [WatchedItem], new: Set<String>, signers: [String: Signer], launchd: LaunchdState) {
        let now = Date()
        func item(_ name: String, _ developer: String?, _ kind: WatchedItem.Kind, plist: String? = nil, executable: String? = nil,
                  bundle: String? = nil, label: String? = nil, daysAgo: Double) -> WatchedItem {
            WatchedItem(id: "\(kind.rawValue)|\(label ?? name)|\(plist ?? bundle ?? "")", name: name, developer: developer, kind: kind,
                        enabled: true, plist: plist, executable: executable, label: label, bundlePath: bundle,
                        firstSeen: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let items = [
            item("updater-helper", nil, .agent, plist: "~/Library/LaunchAgents/com.example.updater-helper.plist",
                 executable: "/Users/demo/Library/Application Support/.helper/updater", label: "com.example.updater-helper", daysAgo: 0.1),
            item("GoogleUpdater", "Google LLC", .agent, plist: "~/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist",
                 executable: "/Users/demo/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app",
                 label: "com.google.GoogleUpdater.wake", daysAgo: 120),
            item("com.docker.vmnetd", "Docker Inc", .daemon, plist: "/Library/LaunchDaemons/com.docker.vmnetd.plist",
                 executable: "/Library/PrivilegedHelperTools/com.docker.vmnetd", label: "com.docker.vmnetd", daysAgo: 300),
            item("Zoom", "Zoom Communications, Inc.", .loginItem, bundle: "/Applications/zoom.us.app", daysAgo: 90),
            item("redis", "Homebrew", .agent, plist: "~/Library/LaunchAgents/homebrew.mxcl.redis.plist",
                 executable: "/opt/homebrew/opt/redis/bin/redis-server", label: "homebrew.mxcl.redis", daysAgo: 40),
        ]
        let signers: [String: Signer] = [
            "/Users/demo/Library/Application Support/.helper/updater": .unsigned,
            "/Users/demo/Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app":
                .developerID(name: "Google LLC", team: "EQHXZ8M8AV", notarized: true),
            "/Library/PrivilegedHelperTools/com.docker.vmnetd": .developerID(name: "Docker Inc", team: "9BNSXJN65R", notarized: true),
            "/Applications/zoom.us.app": .developerID(name: "Zoom Video Communications, Inc.", team: "BJ4HAAB9B3", notarized: true),
            "/opt/homebrew/opt/redis/bin/redis-server": .adHoc,
        ]
        return (items, [items[0].id], signers,
                LaunchdState(running: ["com.example.updater-helper", "com.docker.vmnetd", "homebrew.mxcl.redis"], disabled: []))
    }

    static var backgroundChanges: [BackgroundChange] {
        let items = backgroundItems.items
        return [BackgroundChange(kind: .added, item: items[0], date: Date().addingTimeInterval(-2 * 3_600)),
                BackgroundChange(kind: .removed, item: WatchedItem(id: "agent|com.example.old", name: "OldSync Agent", developer: "Example Corp",
                                                                   kind: .agent, enabled: true, plist: nil, executable: nil, label: nil,
                                                                   bundlePath: nil, firstSeen: Date().addingTimeInterval(-90 * 86_400)),
                                 date: Date().addingTimeInterval(-3 * 86_400))]
    }

    /// A day of five-minute readings: on battery in the morning and evening, charging around midday.
    static var energyHistory: EnergyHistory {
        let apps = [
            EnergyApp(key: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app"),
            EnergyApp(key: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app"),
            EnergyApp(key: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app"),
            .system,
            EnergyApp(key: "us.zoom.xos", name: "Zoom", path: "/Applications/zoom.us.app"),
            EnergyApp(key: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app"),
        ]
        let weights = [34.0, 22, 12, 14, 11, 4]
        var history = EnergyHistory()
        var charge = 0.96
        let start = Date().addingTimeInterval(-22 * 3_600)
        for step in 0..<(22 * 12) {
            let date = start.addingTimeInterval(Double(step) * 300)
            let hour = Double(step) / 12
            let onBattery = !(9..<12.5).contains(hour)
            charge = onBattery ? max(0.12, charge - 0.0062 - 0.002 * sin(hour)) : min(1, charge + 0.03)
            var used: [EnergyApp: Double] = [:]
            for (app, weight) in zip(apps, weights) { used[app] = weight * (1 + 0.3 * sin(hour + weight)) * 6 }
            history.record(used, charge: charge, onBattery: onBattery, at: date)
        }
        return history
    }

    static var driveWarning: DriveHealth {
        DriveHealth(name: "Sample NVMe SSD", isInternal: false, capacity: 2_000_000_000_000, percentageUsed: 84, availableSpare: 92,
                    spareThreshold: 10, warnings: [], temperatureCelsius: 48, bytesWritten: 612_000_000_000_000,
                    bytesRead: 880_000_000_000_000, powerOnHours: 21_400, powerCycles: 3_120, unsafeShutdowns: 41, mediaErrors: 3)
    }
}
