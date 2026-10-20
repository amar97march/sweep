import AppKit
import SwiftUI
import SweepCore
import SweepLens
import SweepMonitor

/// Screenshot harness for checking the real UI without screen-recording permission.
///
/// Launch with `SWEEP_SNAPSHOT_DIR=/some/folder` (and optionally `SWEEP_SNAPSHOT_STEPS=cleanup,diskMap`);
/// the app walks through each screen, draws its own window into a PNG, and quits.
/// Sheets, Settings and the menu bar dashboard are drawn from their own windows.
@MainActor
public enum Snapshots {
    @MainActor
    struct Step {
        let name: String
        let group: String
        let setup: (AppState) async -> Void
        /// Window to draw: the main window unless the step opens a sheet or another window.
        var window: () -> NSWindow? = { mainWindow }
        /// Closes whatever `setup` opened, once the capture is taken.
        var teardown: (AppState) async -> Void = { _ in }
    }

    /// The main window, found when the run starts.
    static var mainWindow: NSWindow?

    public static func runIfRequested(state: AppState) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SWEEP_SNAPSHOT_DIR"] else { return }
        let groups = environment["SWEEP_SNAPSHOT_STEPS"].map { Set($0.split(separator: ",").map(String.init)) }
        // SWEEP_SNAPSHOT_SETTLE_MS shortens the wait to catch an animation part way through.
        let settle = Int(environment["SWEEP_SNAPSHOT_SETTLE_MS"] ?? "") ?? 1500
        // AppKit and SwiftUI save window frames and the Settings tab in the app's defaults as the run moves
        // windows around. Keep a copy and put it back before quitting, so the user's defaults end up unchanged.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain)
        Task {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            await waitForWindow()
            for step in steps where groups == nil || groups!.contains(step.group) {
                await step.setup(state)
                try? await Task.sleep(for: .milliseconds(settle))  // let animations settle
                if let window = step.window() {
                    capture(window, to: URL(fileURLWithPath: directory).appendingPathComponent(step.name + ".png"))
                } else {
                    FileHandle.standardError.write(Data("snapshot: no window for \(step.name)\n".utf8))
                }
                await step.teardown(state)
            }
            if let savedDefaults {
                UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            UserDefaults.standard.synchronize()
            exit(0)  // not NSApp.terminate: quitting normally could save window state again
        }
    }

    /// Screens to capture. Everything except Disk Map uses demo data, and nothing is ever performed.
    static var steps: [Step] {
        var steps: [Step] = []
        for kind in ModuleKind.allCases {
            steps.append(Step(name: "\(kind.rawValue)-intro", group: kind.rawValue) { $0.selection = kind })
        }
        for kind in [ModuleKind.cleanup, .protection, .performance, .applications, .declutter, .cloudFiles] {
            steps.append(Step(name: "\(kind.rawValue)-scanning", group: kind.rawValue) { state in
                state.selection = kind
                state.catalog(for: kind)?.setPreviewScanning(.init(
                    message: "/Users/demo/Library/Containers/com.example.VeryLongApplicationName/Data/Library/Caches/com.example.cache/fsCachedData/3F2A",
                    fraction: 0.42))
            })
            steps.append(Step(name: "\(kind.rawValue)-results", group: kind.rawValue) { state in
                state.selection = kind
                state.catalog(for: kind)?.load(DemoData.categories(for: kind))
            })
            steps.append(Step(name: "\(kind.rawValue)-review", group: kind.rawValue) { state in
                state.catalog(for: kind)?.review()
            })
            steps.append(Step(name: "\(kind.rawValue)-done", group: kind.rawValue) { state in
                state.catalog(for: kind)?.previewDone(DemoData.records(for: kind))
            })
        }
        steps.append(Step(name: "cleanup-ai-models", group: "cleanup") { state in
            state.selection = .cleanup
            state.catalog(for: .cleanup)?.load(DemoData.categories(for: .cleanup))
            state.catalog(for: .cleanup)?.review(category: "aiModels")
        })
        // The log sheet looks the same everywhere; check it with sizes (Cleanup) and with tasks (Performance).
        for kind in [ModuleKind.cleanup, .performance] {
            steps.append(Step(name: "\(kind.rawValue)-log", group: kind.rawValue, setup: { _ in
                presentSheet(ActionLogSheet(records: DemoData.logRecords(for: kind), theme: kind.theme))
            }, window: { mainWindow?.attachedSheet }, teardown: { _ in await endSheet() }))
        }
        steps += [
            Step(name: "checkup-scanning", group: "checkup") { state in
                state.selection = .checkup
                state.checkup.previewScanning()
            },
            Step(name: "checkup-results", group: "checkup") { state in
                for kind in CheckupModel.modules { state.catalog(for: kind)?.load(DemoData.categories(for: kind)) }
                state.checkup.enabled = Set(CheckupModel.modules)
                state.selection = .checkup
                state.checkup.showLoadedResults()
            },
            Step(name: "assistant-live", group: "assistant") { state in
                state.selection = .assistant
                state.assistant.refresh()
            },
            Step(name: "diskMap-explore", group: "diskMap") { state in
                state.selection = .diskMap
                state.diskMap.scan(URL(fileURLWithPath: "/Applications"))
                await waitUntil(seconds: 60) { lens(state) != nil }
            },
            // The pointer over the biggest bubble (spotlight, share ring, tooltip) and one item marked.
            Step(name: "diskMap-focus", group: "diskMap", setup: { state in
                guard let lens = lens(state) else { return }
                lens.hovered = lens.items.first?.id
                if let item = lens.items.dropFirst(4).first(where: lens.canMark) { lens.toggleMark(item) }
            }, teardown: { state in
                guard let lens = lens(state) else { return }
                lens.hovered = nil
                lens.clearMarks()
            }),
        ]
        steps += growthSteps + removalSteps + systemDataSteps + watchSteps + settingsSteps + menuBarSteps
        if ProcessInfo.processInfo.environment["SWEEP_SNAPSHOT_LIVE"] != nil { steps += liveSteps }
        return steps
    }

    // MARK: What grew

    /// Compares the /Applications scan with an earlier snapshot made from it, with a few folders shrunk and
    /// one left out (screenshots only: there is no real earlier scan in a fresh run).
    static var growthSteps: [Step] {
        [
            Step(name: "diskMap-what-grew", group: "diskMap", setup: { state in
                guard let lens = lens(state) else { return }
                let current = SizeSnapshot(of: lens.result.root, date: Date())
                var sizes = current.sizes
                let top = lens.result.root.children.prefix(6)
                for (index, child) in top.enumerated() {
                    if index == 2 { sizes[child.path] = nil } else { sizes[child.path] = UInt64(Double(child.allocatedSize) * 0.6) }
                }
                sizes[lens.result.root.path] = UInt64(Double(lens.result.root.allocatedSize) * 0.8)
                lens.baseline = SizeSnapshot(root: current.root, date: Date().addingTimeInterval(-9 * 86_400), sizes: sizes,
                                             depth: current.depth, threshold: current.threshold)
                lens.showsGrowth = true
            }, teardown: { state in
                lens(state)?.showsGrowth = false
            }),
        ]
    }

    // MARK: Updater, Activity, drive health

    /// Demo updates, activity and a worn drive. Every engine is inert in screenshot runs, so nothing is installed,
    /// switched or recorded.
    static var watchSteps: [Step] {
        [
            Step(name: "updater-checking", group: "updater") { state in
                state.selection = .updater
                state.updater.previewChecking()
            },
            Step(name: "updater-list", group: "updater") { state in
                state.updater.preview(DemoData.updates)
            },
            Step(name: "updater-updating", group: "updater") { state in
                let updates = DemoData.updates
                state.updater.preview(updates, states: [updates[0].id: .done("Updated to 1.105.0"), updates[1].id: .updating,
                                                        updates[2].id: .waiting,
                                                        updates[4].id: .failed("The update's signature doesn't match the app's key")],
                                      updating: true)
            },
            Step(name: "updater-up-to-date", group: "updater", setup: { state in
                state.updater.preview([DemoData.updates[3]])
                state.updater.ignoreApp(DemoData.updates[3])
            }, teardown: { state in
                state.updater.stopIgnoring(DemoData.updates[3])
            }),
            Step(name: "activity-sensors", group: "activity") { state in
                showDemoActivity(state)
                state.activity.tab = .sensors
                state.selection = .activity
            },
            Step(name: "activity-background", group: "activity") { state in
                state.activity.tab = .background
            },
            Step(name: "activity-battery", group: "activity") { state in
                state.activity.tab = .battery
            },
            Step(name: "activity-network", group: "activity") { state in
                state.activity.tab = .network
            },
            Step(name: "activity-usage", group: "activity") { state in
                state.activity.tab = .usage
            },
            Step(name: "activity-usage-week", group: "activity", setup: { state in
                state.activity.usageRange = .week
            }, teardown: { state in
                state.activity.usageRange = .day
            }),
            Step(name: "activity-privacy", group: "activity") { state in
                state.activity.tab = .privacy
            },
            Step(name: "applications-intel", group: "applications") { state in
                state.selection = .applications
                state.catalog(for: .applications)?.load(DemoData.categories(for: .applications) + [DemoData.intelApps])
                state.catalog(for: .applications)?.review(category: "intelApps")
            },
            Step(name: "applications-trashed-leftovers", group: "applications") { state in
                state.alerts.preview(runaways: [], accessories: [], leftovers: DemoData.alerts.leftovers)
                state.reviewTrashedLeftovers()
            },
            Step(name: "assistant-drive-warning", group: "assistant") { state in
                state.selection = .assistant
                state.assistant.refresh()
                state.assistant.previewDrives([DemoData.driveWarning])
                state.security.preview(checks: DemoData.securityChecks, speed: DemoData.diskSpeed)
            },
            Step(name: "assistant-security", group: "assistant", setup: { _ in
                // Scroll to the end, where the drive speed and the security checklist are.
                if let scroll = mainWindow?.contentView.flatMap(Self.scrollView) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }),
        ]
    }

    /// The first scroll view under `view` that scrolls vertically.
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || (scroll.documentView?.frame.height ?? 0) > scroll.frame.height {
            return scroll
        }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    static func showDemoActivity(_ state: AppState) {
        AppLookup.previewNames = DemoData.sensorAppNames.merging(DemoData.privacyAppNames) { first, _ in first }
        let watchers = DemoData.keyboardWatchers
        state.activity.preview(network: DemoData.networkHistory, onHotspot: true, batteryHealth: DemoData.batteryHealthLog,
                               permissions: DemoData.permissions, keyboardWatchers: watchers.watchers, signers: watchers.signers)
        state.activity.preview(usage: DemoData.appUsage)
        state.alerts.preview(memoryHogs: DemoData.memoryHogs, thermalLevel: .serious, thermalLog: DemoData.thermalLog)
        let background = DemoData.backgroundItems
        state.activity.preview(sensors: DemoData.sensorHistory, cameraOn: true, background: background.items,
                               changes: DemoData.backgroundChanges, unreviewed: background.new, signers: background.signers,
                               launchd: background.launchd, energy: DemoData.energyHistory)
    }

    // MARK: System Data

    /// Measures this Mac for real (read-only).
    static var systemDataSteps: [Step] {
        [
            Step(name: "diskMap-system-data", group: "diskMap", setup: { state in
                state.selection = .diskMap
                state.diskMap.explainSystemData(locations: state.settings.toolLocations)
                await waitUntil(seconds: 90) {
                    if case .systemData = state.diskMap.phase { return true }
                    return false
                }
            }),
            Step(name: "diskMap-intro-history", group: "diskMap", setup: { state in
                state.diskMap.startOver()
            }),
        ]
    }

    // MARK: Live

    /// Real, read-only scans of this Mac (SWEEP_SNAPSHOT_LIVE=1): Cleanup, Cloud Files and Assistant as they
    /// are now, to check them with real data. Nothing is performed.
    static var liveSteps: [Step] {
        var steps: [Step] = []
        for kind in [ModuleKind.cleanup, .cloudFiles] {
            steps.append(Step(name: "live-\(kind.rawValue)-results", group: "live") { state in
                state.selection = kind
                guard let catalog = state.catalog(for: kind) else { return }
                catalog.startOver()
                catalog.scan()
                await waitUntil(seconds: 240) { catalog.phase != .scanning }
            })
            steps.append(Step(name: "live-\(kind.rawValue)-review", group: "live") { state in
                state.catalog(for: kind)?.review()
            })
        }
        steps.append(Step(name: "live-cleanup-ai-models", group: "live") { state in
            state.selection = .cleanup
            state.catalog(for: .cleanup)?.focus(on: "aiModels")
        })
        steps.append(Step(name: "live-assistant", group: "live") { state in
            state.selection = .assistant
            state.assistant.refresh()
            try? await Task.sleep(for: .seconds(2))
            state.assistant.refresh()
        })
        return steps
    }

    // MARK: Disk Map removal sheet

    /// Review → removing → results over the largest apps found in /Applications, plus up to two that would
    /// be skipped (running, or protected by macOS). The session is a preview: its `start` does nothing,
    /// so no button press can remove anything.
    static var removalSteps: [Step] {
        let sheet: () -> NSWindow? = { mainWindow?.attachedSheet }
        return [
            Step(name: "diskMap-removal-review", group: "diskMap", setup: { state in
                guard let lens = lens(state) else { return }
                let all = RemovalSession(items: lens.items.filter(lens.canMark))
                let flagged = all.items.filter { all.warnings[$0.id] != nil }.prefix(2)
                // Flagged items first, so their warning rows are in view.
                let session = RemovalSession(items: Array(flagged + all.removableItems.prefix(8 - flagged.count)))
                session.preview(.review)
                lens.removal = session
            }, window: sheet),
            Step(name: "diskMap-removal-review-permanent", group: "diskMap", setup: { state in
                lens(state)?.removal?.deletesPermanently = true
            }, window: sheet),
            Step(name: "diskMap-removal-removing", group: "diskMap", setup: { state in
                guard let session = lens(state)?.removal else { return }
                session.deletesPermanently = false
                session.preview(.removing(done: 3, total: session.items.count))
            }, window: sheet),
            Step(name: "diskMap-removal-results", group: "diskMap", setup: { state in
                guard let session = lens(state)?.removal else { return }
                session.preview(.finished(DemoData.removalRecords(for: session)))
            }, window: sheet, teardown: { state in
                lens(state)?.removal = nil
                await waitUntil(seconds: 3) { mainWindow?.attachedSheet == nil }
            }),
        ]
    }

    static func lens(_ state: AppState) -> LensModel? {
        if case .exploring(let lens) = state.diskMap.phase { return lens }
        return nil
    }

    // MARK: Settings

    static var settingsSteps: [Step] {
        [
            Step(name: "settings-general", group: "settings", setup: { _ in
                openSettings()
                await waitUntil(seconds: 5) { settingsWindow != nil }
                await selectSettingsTab("General")  // it reopens on the last tab used
            }, window: { settingsWindow }),
            Step(name: "settings-protection", group: "settings", setup: { _ in
                await selectSettingsTab("Security")
            }, window: { settingsWindow }),
            Step(name: "settings-automation", group: "settings", setup: { _ in
                await selectSettingsTab("Automation")
            }, window: { settingsWindow }),
            Step(name: "settings-alerts", group: "settings", setup: { _ in
                await selectSettingsTab("Alerts")
            }, window: { settingsWindow }),
            Step(name: "settings-integrations", group: "settings", setup: { _ in
                await selectSettingsTab("Integrations")
                try? await Task.sleep(for: .seconds(4))  // tools are measured in the background
            }, window: { settingsWindow }),
            Step(name: "settings-tweaks", group: "settings", setup: { _ in
                await selectSettingsTab("Tweaks")
            }, window: { settingsWindow }, teardown: { _ in
                settingsWindow?.close()
            }),
        ]
    }

    static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
    }

    /// Chooses Settings… in the app menu, as the user would.
    static func openSettings() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        menu.performActionForItem(at: index)
    }

    /// Clicks a tab in the Settings toolbar and waits for the window to show it (its title is the tab's name).
    static func selectSettingsTab(_ label: String) async {
        for _ in 0..<10 where settingsWindow?.title != label {
            if let item = settingsWindow?.toolbar?.items.first(where: { $0.label == label }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            await waitUntil(seconds: 0.5) { settingsWindow?.title == label }
        }
    }

    // MARK: Menu bar dashboard

    /// MenuBarExtra ignores synthetic clicks on its status item, so the dashboard is drawn in a panel of its
    /// own, on the menu material and in the light system appearance: it should look the same for everyone.
    static var menuBarSteps: [Step] {
        [
            Step(name: "menuBar-dashboard", group: "menuBar", setup: { state in
                showMenuBarPanel(MenuBarDashboard(state: state))
                // CPU and network need two samples, taken two seconds apart.
                await waitUntil(seconds: 6) { state.assistant.snapshot?.cpuUsage != nil && state.assistant.snapshot?.network != nil }
                try? await Task.sleep(for: .milliseconds(300))
                fitMenuBarPanel()
            }, window: { menuBarPanel }, teardown: { _ in
                menuBarPanel?.close()
                menuBarPanel = nil
            }),
            // Keep Awake on (inert: no real power assertion), updates waiting and the camera in use.
            Step(name: "menuBar-active", group: "menuBar", setup: { state in
                showDemoActivity(state)
                let alerts = DemoData.alerts
                state.alerts.preview(runaways: alerts.runaways, accessories: alerts.accessories, leftovers: alerts.leftovers)
                state.updater.preview(DemoData.updates)
                state.keepAwake.start(.minutes(60))
                showMenuBarPanel(MenuBarDashboard(state: state))
                await waitUntil(seconds: 6) { state.assistant.snapshot?.cpuUsage != nil }
                try? await Task.sleep(for: .milliseconds(300))
                fitMenuBarPanel()
            }, window: { menuBarPanel }, teardown: { state in
                state.keepAwake.stop()
                state.alerts.preview(runaways: [], accessories: [], leftovers: [])
                state.alerts.preview(memoryHogs: [], thermalLevel: .nominal, thermalLog: ThermalLog())
                menuBarPanel?.close()
                menuBarPanel = nil
            }),
        ]
    }

    static var menuBarPanel: NSPanel?

    static func showMenuBarPanel(_ view: some View) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        let material = NSVisualEffectView(frame: panel.contentLayoutRect)
        material.material = .menu
        material.state = .active
        let host = NSHostingView(rootView: view)
        host.frame = material.bounds
        host.autoresizingMask = [.width, .height]
        material.addSubview(host)
        panel.contentView = material
        menuBarPanel = panel
        fitMenuBarPanel()
        panel.orderFrontRegardless()
    }

    /// Sizes the panel to the dashboard and pins it under the right end of the menu bar.
    static func fitMenuBarPanel() {
        guard let panel = menuBarPanel, let host = panel.contentView?.subviews.first, let screen = NSScreen.main?.visibleFrame else { return }
        let size = host.fittingSize
        panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - 6 - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Helpers

    /// Shows `view` as a sheet on the main window, the way SwiftUI's `.sheet` does.
    static func presentSheet(_ view: some View) {
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        mainWindow?.beginSheet(sheet)
    }

    static func endSheet() async {
        guard let window = mainWindow, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet)
        await waitUntil(seconds: 3) { window.attachedSheet == nil }
    }

    static func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    static func waitForWindow() async {
        await waitUntil(seconds: 10) { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }
        // SWEEP_SNAPSHOT_SIZE=1040x680 checks other window sizes (default 1280×820).
        let size = ProcessInfo.processInfo.environment["SWEEP_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        let width = size?.count == 2 ? size![0] : 1280, height = size?.count == 2 ? size![1] : 820
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {  // not a status bar window
            mainWindow = window
            window.setFrame(NSRect(x: 40, y: 40, width: width, height: height), display: true)
        }
    }

    static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
