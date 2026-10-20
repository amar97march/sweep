import AppKit
import Foundation
import Observation
import SweepCore
import SweepScanners

/// Everything the main window shows, kept alive while the user switches modules.
@MainActor
@Observable
public final class AppState {
    public var selection: ModuleKind = .checkup
    public let diskMap = DiskMapModel()
    public let checkup = CheckupModel()
    public let assistant = AssistantModel()
    public let automation = AutomationModel()
    public let updater = UpdaterModel()
    public let activity = ActivityModel()
    public let keepAwake = KeepAwakeModel()
    public let alerts = AlertsModel()
    public let security = SecurityModel()
    public let tweaks = TweaksModel()
    public let settings = AppSettings.shared
    /// Checked again each time Sweep comes to the front, so granting it in System Settings shows up at once.
    public private(set) var hasFullDiskAccess = PrivacyAccess.hasFullDiskAccess
    @ObservationIgnored private var catalogs: [ModuleKind: CatalogModuleModel] = [:]
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    public init() {
        catalogs[.cleanup] = CatalogModuleModel(kind: .cleanup, engine: Engines.cleanup())
        catalogs[.declutter] = CatalogModuleModel(kind: .declutter, engine: Engines.declutter())
        catalogs[.applications] = CatalogModuleModel(kind: .applications, engine: Engines.applications())
        catalogs[.performance] = CatalogModuleModel(kind: .performance, engine: Engines.performance())
        catalogs[.protection] = CatalogModuleModel(kind: .protection, engine: Engines.protection())
        catalogs[.cloudFiles] = CatalogModuleModel(kind: .cloudFiles, engine: Engines.cloudFiles())
        checkup.state = self
        assistant.state = self
        automation.state = self
        automation.start()
        activity.start()
        alerts.start()
        startDailyChecks()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    /// Re-reads permissions and approvals the user may have changed in System Settings.
    public func refreshPermissions() {
        let access = PrivacyAccess.hasFullDiskAccess
        if access != hasFullDiskAccess { hasFullDiskAccess = access }
        automation.refreshLoginItem()
    }

    public func catalog(for kind: ModuleKind) -> CatalogModuleModel? { catalogs[kind] }

    /// Shows the files left by apps just moved to the Trash, in Applications' review, unless it's busy.
    public func reviewTrashedLeftovers() {
        guard let applications = catalog(for: .applications), ![.scanning, .working].contains(applications.phase) else {
            selection = .applications
            return
        }
        let categories = alerts.takeLeftovers()
        guard !categories.isEmpty else { return }
        applications.load(categories)
        applications.review(category: categories[0].id)
        selection = .applications
    }

    /// App updates once a day and drive health every few hours, while Sweep runs. Never in tests or screenshots.
    private func startDailyChecks() {
        guard !Preferences.isThrowaway else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))  // let launch finish first
            while !Task.isCancelled {
                await self?.updater.checkInBackgroundIfDue(now: Date())
                await self?.assistant.refreshDrivesIfDue()
                await self?.security.refreshIfDue()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// Takes the user to where they can act on part of System Data.
    public func open(_ destination: SystemDataReport.Part.Destination) {
        switch destination {
        case .cleanup(let category):
            selection = .cleanup
            catalog(for: .cleanup)?.focus(on: category)
        case .performance:
            selection = .performance
            catalog(for: .performance)?.focus(on: "maintenance", item: "task:thinSnapshots")
        case .diskMap(let path):
            diskMap.scan(URL(fileURLWithPath: path))
        case .openApp(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case .none:
            break
        }
    }

    /// Size found by the module's last scan, for the sidebar badge.
    public func badge(for kind: ModuleKind) -> String? {
        if kind == .assistant, let report = assistant.report { return "\(report.score)" }
        if kind == .updater { return updater.hasChecked && !updater.outstanding.isEmpty ? "\(updater.outstanding.count)" : nil }
        if kind == .activity { return activity.unreviewed.isEmpty ? nil : "\(activity.unreviewed.count) new" }
        if kind == .applications, let model = catalog(for: kind), [.results, .review].contains(model.phase) {
            let updates = model.categories.first { $0.id == "updates" }?.itemCount ?? 0
            return updates > 0 ? "\(updates)" : nil
        }
        if let catalog = catalog(for: kind), catalog.selectableCount > 0,
           [.results, .review].contains(catalog.phase) {
            return catalog.engine.measuresSize && catalog.totalSize > 0
                ? ByteFormat.short(catalog.totalSize) : "\(catalog.selectableCount)"
        }
        return nil
    }
}

/// User preferences shared by the modules.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    /// Move cleaned junk to the Trash instead of deleting it.
    public var cleanupUsesTrash: Bool {
        didSet { Preferences.set(cleanupUsesTrash, forKey: "cleanupUsesTrash") }
    }

    /// Scan the whole home folder and Applications for malware, not just the usual hiding places.
    public var protectionDeepScan: Bool {
        didSet { Preferences.set(protectionDeepScan, forKey: "protectionDeepScan") }
    }

    /// Folders and programs chosen in Settings → Integrations, overriding what Sweep finds by itself.
    public var toolLocations: ToolLocations {
        didSet { Preferences.set(try? JSONEncoder().encode(toolLocations), forKey: "toolLocations") }
    }

    private init() {
        cleanupUsesTrash = Preferences.object(forKey: "cleanupUsesTrash") as? Bool ?? false
        protectionDeepScan = Preferences.object(forKey: "protectionDeepScan") as? Bool ?? false
        toolLocations = (Preferences.object(forKey: "toolLocations") as? Data)
            .flatMap { try? JSONDecoder().decode(ToolLocations.self, from: $0) } ?? ToolLocations()
    }
}
