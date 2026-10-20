import AppKit
import Foundation
import SweepCore
import SweepScanners

/// Connects each list-style module to its scanner and performer.
enum Engines {
    static func cleanup() -> ModuleEngine {
        ModuleEngine(actionVerb: "Clean", workingMessage: "Cleaning up…", doneTitle: "Junk cleaned") { sink in
            let running = await RunningApps.bundleIDs()
            let environment = ScanEnvironment.live(runningBundleIDs: running)
            // The Trash preference is applied when cleaning (see perform), so it can change after a scan.
            var categories = CleanupScanner(environment: environment, mode: .deletePermanently)
                .scan(progress: { sink.report($0) }, isCancelled: { sink.isCancelled })
            guard !sink.isCancelled else { return categories }
            // Developer tools that keep big downloads: local AI models and Docker.
            let finder = ToolFinder(environment: environment, overrides: await AppSettings.shared.toolLocations)
            if let models = AIModelScanner(finder: finder).scan(progress: { sink.report($0) }) { categories.append(models) }
            guard !sink.isCancelled else { return categories }
            if let docker = DockerScanner(finder: finder).scan(progress: { sink.report($0) }).category { categories.append(docker) }
            return categories
        } perform: { items, sink in
            let docker = items.filter(DockerPerformer.handles)
            let files = CleanupPerformer.applyingTrashPreference(items.filter { !DockerPerformer.handles($0) },
                                                                 usesTrash: await AppSettings.shared.cleanupUsesTrash)
            let report = { (done: Int) in
                sink.report("Removing \(done) of \(items.count)", fraction: Double(done) / Double(max(items.count, 1)))
            }
            let records = CleanupPerformer.perform(files, remover: FileRemover(), allowAdministrator: true,
                                                   progress: { done, _ in report(done) })
                + DockerPerformer().perform(docker, progress: { done, _ in report(files.count + done) })
            let byItem = Dictionary(records.compactMap { record in record.itemID.map { ($0, record) } }, uniquingKeysWith: { a, _ in a })
            return items.compactMap { byItem[$0.id] }
        }
    }
}

extension Engines {
    static func declutter() -> ModuleEngine {
        ModuleEngine(actionVerb: "Move to Trash", workingMessage: "Moving to Trash…", doneTitle: "Clutter cleared") { sink in
            ClutterScanner(environment: .live()).scan(progress: { sink.report($0) }, isCancelled: { sink.isCancelled })
        } perform: { items, sink in
            CleanupPerformer.perform(items, remover: FileRemover(), allowAdministrator: false, progress: { done, total in
                sink.report("Moving \(done) of \(total) to the Trash", fraction: Double(done) / Double(max(total, 1)))
            })
        }
    }
}

extension Engines {
    static func applications() -> ModuleEngine {
        var engine = ModuleEngine(actionVerb: "Apply", workingMessage: "Working on your apps…", doneTitle: "Apps updated") { sink in
            let running = await RunningApps.bundleIDs()
            let environment = ScanEnvironment.live(runningBundleIDs: running)
            var categories = ApplicationsScanner(environment: environment)
                .scan(progress: { sink.report($0) }, isCancelled: { sink.isCancelled })
            guard !sink.isCancelled else { return categories }
            sink.report("Checking for updates")
            let updates = await UpdateChecker().check(AppCatalog.installed(in: environment))
            // Apps and versions ignored in Updater stay hidden here and in Checkup too.
            let ignored = await UpdaterModel.savedIgnoreList()
            if let category = UpdateCatalog.category(ignored.filter(updates)) { categories.insert(category, at: 0) }
            return categories
        } perform: { items, sink in
            var performer = ApplicationsPerformer()
            performer.quitApp = { path in await RunningApps.quit(path) }
            performer.openURL = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
            return await performer.perform(items) { done, total in
                sink.report("\(done) of \(total) done", fraction: Double(done) / Double(max(total, 1)))
            }
        }
        engine.verb = { items in
            if !items.isEmpty, items.allSatisfy({ UpdateCatalog.decode($0) != nil }) { return "Update" }
            if items.contains(where: { $0.action.paths.contains { $0.hasSuffix(".app") } }) { return "Uninstall" }
            return "Remove"
        }
        return engine
    }
}

extension Engines {
    static func performance() -> ModuleEngine {
        ModuleEngine(actionVerb: "Run", workingMessage: "Running tasks…", doneTitle: "Your Mac is tuned up",
                     measuresSize: false) { sink in
            PerformanceScanner(environment: .live(), recentlyRun: TaskHistory.recentlyRun())
                .scan(progress: { sink.report($0) })
        } perform: { items, sink in
            var performer = PerformancePerformer(environment: .live())
            performer.quitMail = { await RunningApps.quit(bundleID: "com.apple.mail") }
            performer.openLoginItemsSettings = {
                await MainActor.run {
                    _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            }
            let records = await performer.perform(items) { done, total in
                sink.report("\(done) of \(total) done", fraction: Double(done) / Double(max(total, 1)))
            }
            TaskHistory.record(records.filter(\.succeeded).compactMap(\.itemID))
            return records
        }
    }
}

extension Engines {
    static func protection() -> ModuleEngine {
        ModuleEngine(actionVerb: "Remove", workingMessage: "Securing your Mac…", doneTitle: "Your Mac is protected",
                     measuresSize: false) { sink in
            let running = await RunningApps.bundleIDs()
            let deep = await AppSettings.shared.protectionDeepScan
            return ProtectionScanner(environment: .live(runningBundleIDs: running), depth: deep ? .deep : .quick)
                .scan(progress: { sink.report($0) }, isCancelled: { sink.isCancelled })
        } perform: { items, sink in
            var performer = ProtectionPerformer(environment: .live())
            performer.quitApp = { bundleID in await RunningApps.quit(bundleID: bundleID) }
            return await performer.perform(items) { done, total in
                sink.report("\(done) of \(total) done", fraction: Double(done) / Double(max(total, 1)))
            }
        }
    }
}

extension Engines {
    static func cloudFiles() -> ModuleEngine {
        ModuleEngine(actionVerb: "Free Up", workingMessage: "Freeing up space…", doneTitle: "Cloud files tidied") { sink in
            CloudScanner(environment: .live()).scan(progress: { sink.report($0) }, isCancelled: { sink.isCancelled })
        } perform: { items, sink in
            CloudPerformer().perform(items) { done, total in
                sink.report("\(done) of \(total) done", fraction: Double(done) / Double(max(total, 1)))
            }
        }
    }
}

/// When maintenance tasks last ran, so they aren't recommended again too soon.
enum TaskHistory {
    static let key = "maintenanceTaskHistory"

    static func recentlyRun(within days: Double = 7) -> Set<String> {
        let history = Preferences.object(forKey: key) as? [String: Date] ?? [:]
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        return Set(history.filter { $0.value > cutoff }.keys)
    }

    static func record(_ itemIDs: [String]) {
        var history = Preferences.object(forKey: key) as? [String: Date] ?? [:]
        for id in itemIDs where id.hasPrefix("task:") { history[String(id.dropFirst(5))] = Date() }
        Preferences.set(history, forKey: key)
    }
}

enum RunningApps {
    /// Quits every running app with this bundle identifier and waits up to five seconds.
    @MainActor static func quit(bundleID: String) async -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        for _ in 0..<50 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return apps.allSatisfy(\.isTerminated)
    }

    @MainActor static func bundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Asks the app at `path` to quit and waits up to five seconds.
    @MainActor static func quit(_ path: String) async -> Bool {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
        guard !apps.isEmpty else { return true }
        apps.forEach { $0.terminate() }
        for _ in 0..<50 {
            if apps.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return apps.allSatisfy(\.isTerminated)
    }
}
