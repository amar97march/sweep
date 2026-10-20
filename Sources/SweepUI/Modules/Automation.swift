import AppKit
import ServiceManagement
import SweepCore
import SweepScanners

/// When scheduled Checkup runs and what it does.
public struct CheckupSchedule: Codable, Sendable, Equatable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case never, daily, weekly, monthly
    }

    public enum Action: String, Codable, CaseIterable, Sendable {
        /// Scan, then tell the user what was found.
        case notify
        /// Scan, then remove the junk Cleanup selects by default.
        case cleanJunk
    }

    public var frequency = Frequency.never
    /// Calendar numbering: 1 is Sunday.
    public var weekday = 1
    /// 1–28, so every month has the day.
    public var dayOfMonth = 1
    public var hour = 10
    public var minute = 0
    public var action = Action.notify

    public init() {}

    /// The first scheduled time after `date`, or nil when the schedule is off.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents(hour: hour, minute: minute)
        switch frequency {
        case .never: return nil
        case .daily: break
        case .weekly: components.weekday = weekday
        case .monthly: components.day = min(max(dayOfMonth, 1), 28)
        }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
}

/// One thing automation did, for Settings → Automation → Recent Activity.
public struct AutomationActivity: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public let date: Date
    public let title: String
    public let detail: String
    public let symbol: String
}

/// Scheduled Checkup and auto-tidy rules. Runs while Sweep is open (in the menu bar after the window
/// closes); "Open at Login" keeps it open. Never runs during tests or screenshot runs.
@MainActor
@Observable
public final class AutomationModel {
    public var schedule: CheckupSchedule {
        didSet {
            guard schedule != oldValue else { return }
            scheduledSince = Date()
            save()
            if schedule.frequency != .never { requestNotificationPermission() }
        }
    }
    public var rules: [TidyRule] {
        didSet {
            guard rules != oldValue else { return }
            // Each rule waits a day from when it's switched on, so the user can preview it; switching one on
            // doesn't hold back the others.
            let stamped = Self.stampingActivation(rules, previous: oldValue, now: Date())
            if stamped != rules { rules = stamped }
            if rules.contains(where: { rule in rule.isEnabled && !(oldValue.first { $0.kind == rule.kind }?.isEnabled ?? false) }) {
                requestNotificationPermission()
            }
            save()
        }
    }

    /// Records when each rule was switched on, and forgets it when switched off.
    nonisolated static func stampingActivation(_ rules: [TidyRule], previous: [TidyRule], now: Date) -> [TidyRule] {
        rules.map { rule in
            var rule = rule
            let wasOn = previous.first { $0.kind == rule.kind }?.isEnabled ?? false
            if rule.isEnabled && (!wasOn || rule.activeFrom == nil) { rule.activeFrom = wasOn ? .distantPast : now }
            if !rule.isEnabled { rule.activeFrom = nil }
            return rule
        }
    }
    public private(set) var activity: [AutomationActivity] = []
    public private(set) var lastRun: Date?
    public private(set) var lastTidy: Date?
    public private(set) var isRunning = false
    public private(set) var loginItemEnabled = false
    @ObservationIgnored weak var state: AppState?
    @ObservationIgnored private var scheduledSince: Date
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init() {
        schedule = Self.load(CheckupSchedule.self, "automation.schedule") ?? CheckupSchedule()
        rules = Self.load([TidyRule].self, "automation.rules") ?? TidyRule.defaults
        activity = Self.load([AutomationActivity].self, "automation.activity") ?? []
        lastRun = Preferences.object(forKey: "automation.lastRun") as? Date
        lastTidy = Preferences.object(forKey: "automation.lastTidy") as? Date
        scheduledSince = Preferences.object(forKey: "automation.scheduledSince") as? Date ?? Date()
        loginItemEnabled = Self.canOpenAtLogin && SMAppService.mainApp.status == .enabled
    }

    public var nextRun: Date? { schedule.nextRun(after: max(lastRun ?? .distantPast, scheduledSince)) }
    public var enabledRules: [TidyRule] { rules.filter(\.isEnabled) }
    /// The next daily tidy: a day after the last one, for the rules that have waited their day.
    public var nextTidy: Date? {
        let daily = (lastTidy ?? scheduledSince).addingTimeInterval(86_400)
        return enabledRules.map { max(daily, ($0.activeFrom ?? .distantPast).addingTimeInterval(86_400)) }.min()
    }

    // MARK: Scheduler

    /// Checks every minute whether anything is due; a run missed while the Mac slept happens on wake.
    public func start() {
        guard timer == nil, !Preferences.isThrowaway else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.runDueWork(now: Date())
            }
        }
    }

    func runDueWork(now: Date) {
        guard !isRunning else { return }
        if let next = nextRun, now >= next {
            Task { await runCheckup() }
        } else if let next = nextTidy, now >= next {
            let due = rules.filter { $0.isDue(at: now) }
            if !due.isEmpty { Task { await tidy(due, scheduled: true) } }
        }
    }

    // MARK: Scheduled Checkup

    /// Scans with every module Checkup uses, without disturbing what's on screen, then reports.
    public func runCheckup() async {
        guard let state, !isRunning, !Preferences.isThrowaway else { return }
        isRunning = true
        lastRun = Date()
        save()
        defer { isRunning = false }

        var found: [ModuleKind: [ScanCategory]] = [:]
        for kind in CheckupModel.modules where state.checkup.enabled.contains(kind) {
            guard let engine = state.catalog(for: kind)?.engine else { continue }
            found[kind] = (try? await engine.scan(ProgressSink { _ in })) ?? []
        }
        let junk = (found[.cleanup] ?? []).flatMap { $0.groups.flatMap(\.items) }.filter(\.isSelectedByDefault)
        let junkBytes = junk.reduce(UInt64(0)) { $0 + $1.size }
        let threats = (found[.protection] ?? []).first { $0.id == "threats" }?.itemCount ?? 0
        let updates = (found[.applications] ?? []).first { $0.id == "updates" }?.itemCount ?? 0

        var cleaned: UInt64 = 0
        let unattended = Self.unattendedJunk(found[.cleanup] ?? [], home: NSHomeDirectory())
        // Never while the user is cleaning in the window: both would work on the same files.
        if schedule.action == .cleanJunk, !unattended.isEmpty, state.catalog(for: .cleanup)?.phase != .working {
            let records = await Task.detached(priority: .utility) {
                CleanupPerformer.perform(unattended, remover: FileRemover(), allowAdministrator: false)
            }.value
            cleaned = records.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
            found[.cleanup] = nil
        }
        // Results wait in the app, replacing ones that are finished with, unless the user is in the middle of
        // something there (reviewing results, or an action running).
        for (kind, categories) in found where [.intro, .done].contains(state.catalog(for: kind)?.phase) {
            state.catalog(for: kind)?.load(categories)
        }
        if [.intro, .done].contains(state.checkup.phase), !found.isEmpty { state.checkup.showLoadedResults() }

        let extras = [threats > 0 ? "\(threats) \(threats == 1 ? "threat" : "threats")" : nil,
                      updates > 0 ? "\(updates) app \(updates == 1 ? "update" : "updates")" : nil].compactMap { $0 }
        let title = cleaned > 0 ? "Checkup cleaned \(ByteFormat.string(cleaned))"
            : junkBytes > 0 ? "Checkup found \(ByteFormat.string(junkBytes)) of junk" : "Checkup: your Mac looks good"
        let detail = (extras.isEmpty ? "" : "Also found " + extras.joined(separator: " and ") + ". ")
            + (cleaned > 0 || junkBytes == 0 ? "Open Sweep for details." : "Open Sweep to review and clean.")
        record(AutomationActivity(date: Date(), title: title, detail: detail, symbol: "sparkles"))
        notify(title: title, body: detail)
    }

    /// What a scheduled run may clean with nobody watching: preselected caches and logs in the home folder,
    /// moved to the Trash. Nothing that needs the administrator password, and never the Trash itself.
    nonisolated static func unattendedJunk(_ categories: [ScanCategory], home: String) -> [ScanItem] {
        categories.filter { ["userCaches", "logs"].contains($0.id) }
            .flatMap { $0.groups.flatMap(\.items) }
            .compactMap { item in
                guard item.isSelectedByDefault, item.note == nil, case .remove(let paths, _) = item.action,
                      !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix(home + "/") }) else { return nil }
                return ScanItem(id: item.id, title: item.title, subtitle: item.subtitle, size: item.size, date: item.date,
                                isSelectedByDefault: true, action: .remove(paths: paths, mode: .moveToTrash))
            }
    }

    // MARK: Auto-tidy

    /// What `rule` would move to the Trash right now.
    public func preview(_ rule: TidyRule) async -> [ScanItem] {
        await Task.detached(priority: .userInitiated) {
            AutoTidy(environment: .live()).candidates(for: rule)
        }.value
    }

    /// Moves everything `rules` pick to the Trash and records what happened.
    @discardableResult
    public func tidy(_ rules: [TidyRule], scheduled: Bool = false) async -> [ActionRecord] {
        // Tests and screenshot runs must never move the user's files.
        guard !rules.isEmpty, !isRunning, !Preferences.isThrowaway else { return [] }
        isRunning = true
        defer { isRunning = false }
        if scheduled {
            lastTidy = Date()
            save()
        }
        let records = await Task.detached(priority: .utility) { () -> [ActionRecord] in
            let tidy = AutoTidy(environment: .live())
            var seen = Set<String>()
            let items = rules.flatMap(tidy.candidates).filter { seen.insert($0.id).inserted }
            return CleanupPerformer.perform(items, remover: FileRemover(), allowAdministrator: false)
        }.value
        let moved = records.filter(\.succeeded)
        guard !moved.isEmpty else { return records }
        let bytes = moved.reduce(UInt64(0)) { $0 + $1.bytes }
        let title = "Moved \(moved.count) \(moved.count == 1 ? "item" : "items") to the Trash"
        let detail = rules.map(\.title).joined(separator: ", ") + " · \(ByteFormat.string(bytes))"
        record(AutomationActivity(date: Date(), title: title, detail: detail, symbol: "wand.and.stars"))
        notify(title: "Auto-tidy: " + title.lowercased(), body: detail + ". You can put them back from the Trash.")
        return records
    }

    // MARK: Open at login

    /// Login items need the app bundle; `swift run` builds can't register one.
    public nonisolated static var canOpenAtLogin: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    /// Picks up an approval given in System Settings → General → Login Items.
    public func refreshLoginItem() {
        let enabled = Self.canOpenAtLogin && SMAppService.mainApp.status == .enabled
        if enabled != loginItemEnabled { loginItemEnabled = enabled }
    }

    public func setOpensAtLogin(_ enabled: Bool) -> String? {
        guard Self.canOpenAtLogin else { return "Available when Sweep runs as an app." }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            return error.localizedDescription
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        return SMAppService.mainApp.status == .requiresApproval ? "Allow Sweep in System Settings → General → Login Items." : nil
    }

    // MARK: Notifications

    private func requestNotificationPermission() { Notifier.requestPermission() }

    private func notify(title: String, body: String) { Notifier.post(title: title, body: body) }

    // MARK: Storage

    private func record(_ entry: AutomationActivity) {
        activity = Array(([entry] + activity).prefix(20))
        save()
    }

    private func save() {
        Preferences.set(try? JSONEncoder().encode(schedule), forKey: "automation.schedule")
        Preferences.set(try? JSONEncoder().encode(rules), forKey: "automation.rules")
        Preferences.set(try? JSONEncoder().encode(activity), forKey: "automation.activity")
        Preferences.set(lastRun, forKey: "automation.lastRun")
        Preferences.set(lastTidy, forKey: "automation.lastTidy")
        Preferences.set(scheduledSince, forKey: "automation.scheduledSince")
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        (Preferences.object(forKey: key) as? Data).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
