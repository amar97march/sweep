import Foundation
import Testing
@testable import SweepCore
@testable import SweepUI
import SweepScanners
import SweepLens

/// Model logic only: no files are touched, engines are fakes.
/// Sample results and a fake engine, usable from any isolation.
enum Fixtures {
    static func item(_ id: String, size: UInt64, selected: Bool, note: String? = nil, date: Date? = nil) -> ScanItem {
        ScanItem(id: id, title: id, subtitle: "/fake/\(id)", size: size, date: date, isSelectedByDefault: selected,
                 action: .custom(kind: "fake", payload: [id]), note: note)
    }

    static let sample: [ScanCategory] = [
        ScanCategory(id: "caches", title: "Caches", summary: "", symbol: "archivebox", groups: [
            ScanGroup(id: "g1", title: "App One", icon: .symbol("app"), items: [item("a", size: 100, selected: true), item("b", size: 300, selected: false)]),
            ScanGroup(id: "g2", title: "App Two", icon: .symbol("app"), items: [item("c", size: 50, selected: true),
                                                                               item("locked", size: 999, selected: true, note: "In use")]),
        ]),
        ScanCategory(id: "logs", title: "Logs", summary: "", symbol: "doc", groups: [
            ScanGroup(id: "g3", title: "Logs", icon: .symbol("doc"), items: [item("d", size: 10, selected: false, date: .distantPast),
                                                                            item("e", size: 20, selected: false, date: Date())]),
        ]),
    ]

    /// An engine whose action succeeds for every item except "b".
    static func engine(measuresSize: Bool = true) -> ModuleEngine {
        ModuleEngine(actionVerb: "Clean", workingMessage: "…", doneTitle: "Done", measuresSize: measuresSize) { _ in
            sample
        } perform: { items, _ in
            items.map { item in
                ActionRecord(itemID: item.id, title: item.title, detail: "", bytes: item.size,
                             outcome: item.id == "b" ? .failed("nope") : .done("Removed"))
            }
        }
    }

}

@MainActor
@Suite struct CatalogModuleModelTests {
    static let sample = Fixtures.sample
    static func engine(measuresSize: Bool = true) -> ModuleEngine { Fixtures.engine(measuresSize: measuresSize) }

    @Test func smartSelectionUsesScannerDefaultsAndSkipsLockedItems() {
        let model = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        model.load(Self.sample)
        #expect(model.phase == .results)
        #expect(model.selected == ["a", "c"])
        #expect(model.selectedSize == 150)
        // The locked item can't be acted on, so it isn't part of what Sweep found to free.
        #expect(model.totalSize == 480)
        #expect(model.selectableCount == 5)
    }

    @Test func anActionThatStartedAlwaysFinishes() async throws {
        let slow = ModuleEngine(actionVerb: "Clean", workingMessage: "…", doneTitle: "Done") { _ in
            Fixtures.sample
        } perform: { items, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return items.map { ActionRecord(itemID: $0.id, title: $0.title, detail: "", bytes: $0.size, outcome: .done("Removed")) }
        }
        let model = CatalogModuleModel(kind: .cleanup, engine: slow)
        model.load(Self.sample)
        model.run()
        #expect(model.phase == .working)
        // Checkup's Stop and Scan, and Start Over, must not throw the running action's results away.
        model.stop()
        model.scan()
        model.startOver()
        model.run()
        #expect(model.phase == .working)
        let deadline = Date().addingTimeInterval(5)
        while model.phase == .working && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.phase == .done)
        #expect(Set(model.records.compactMap(\.itemID)) == ["a", "c"])
    }

    @Test func anItemListedTwiceCountsOnce() {
        let shared = Fixtures.item("shared", size: 500, selected: true)
        let unsuggested = Fixtures.item("shared", size: 500, selected: false)
        let categories = [
            ScanCategory(id: "dupes", title: "Duplicates", summary: "", symbol: "x", groups: [
                ScanGroup(id: "g", title: "g", icon: .symbol("x"), items: [shared, Fixtures.item("only", size: 10, selected: true)])]),
            ScanCategory(id: "large", title: "Large", summary: "", symbol: "x", groups: [
                ScanGroup(id: "h", title: "h", icon: .symbol("x"), items: [unsuggested])]),
        ]
        let model = CatalogModuleModel(kind: .declutter, engine: Self.engine())
        model.load(categories)
        // One listing doesn't suggest it, so it isn't preselected.
        #expect(model.selected == ["only"])
        #expect(model.totalSize == 510)
        #expect(model.selectableCount == 2)
        model.selectAll()
        #expect(model.selectedItems.map(\.id) == ["shared", "only"])
        #expect(model.selectedSize == 510)
    }

    @Test func focusingOnOneItemSelectsOnlyIt() {
        let model = CatalogModuleModel(kind: .performance, engine: Self.engine(measuresSize: false))
        model.load([ScanCategory(id: "maintenance", title: "Maintenance", summary: "", symbol: "x", groups: [
            ScanGroup(id: "recommended", title: "Recommended", icon: .symbol("x"), items: [Fixtures.item("task:flushDNS", size: 0, selected: true)]),
            ScanGroup(id: "other", title: "Other", icon: .symbol("x"), items: [Fixtures.item("task:thinSnapshots", size: 0, selected: false)]),
        ])])
        #expect(model.selected == ["task:flushDNS"])
        model.focus(on: "maintenance", item: "task:thinSnapshots")
        #expect(model.phase == .review)
        #expect(model.selected == ["task:thinSnapshots"])
        #expect(model.focusedGroup == "other")
    }

    @Test func triStateSelectionOnGroupsAndCategories() {
        let model = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        model.load(Self.sample)
        let caches = Self.sample[0]
        #expect(model.state(of: caches) == .some)
        #expect(model.state(of: caches.groups[1]) == .all)  // the locked item doesn't count
        model.toggle(caches.groups.flatMap(\.items))
        #expect(model.state(of: caches) == .all)
        #expect(!model.selected.contains("locked"))
        model.toggle(caches.groups.flatMap(\.items))
        #expect(model.state(of: caches) == .none)
        model.toggle(item: Self.sample[1].groups[0].items[0])
        #expect(model.state(of: Self.sample[1]) == .some)
    }

    @Test func searchAndSort() {
        let model = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        model.load(Self.sample)
        let logs = Self.sample[1].groups[0]
        model.sortOrder = .size
        #expect(model.visibleItems(of: logs).map(\.id) == ["e", "d"])
        model.sortOrder = .date
        #expect(model.visibleItems(of: logs).map(\.id) == ["e", "d"])
        model.sortOrder = .name
        #expect(model.visibleItems(of: logs).map(\.id) == ["d", "e"])
        model.searchText = "fake/e"  // matches the subtitle of "e" only
        #expect(model.visibleItems(of: logs).map(\.id) == ["e"])
    }

    @Test func runKeepsFailedItemsForAnotherTry() async throws {
        let model = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        model.load(Self.sample)
        model.selectAll()
        model.run()
        let deadline = Date().addingTimeInterval(5)
        while model.phase != .done && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.phase == .done)
        #expect(model.records.count == 5)
        #expect(model.records.filter { !$0.succeeded }.map(\.itemID) == ["b"])
        // Only the failed item and the locked one remain.
        #expect(Set(model.allItems.map(\.id)) == ["b", "locked"])
        #expect(model.selected.isEmpty || model.selected == ["b"])
    }

    @Test func countsInsteadOfBytesForTaskModules() {
        let model = CatalogModuleModel(kind: .performance, engine: Self.engine(measuresSize: false))
        model.load(Self.sample)
        #expect(model.amount(bytes: 12345, count: 1) == "1 item")
        #expect(model.amount(bytes: 12345, count: 3) == "3 items")
        let sized = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        #expect(sized.amount(bytes: 1_000_000, count: 3) == ByteFormat.string(1_000_000))
    }

    @Test func testsKeepPreferencesInMemory() {
        // Scans record their date; under tests that must stay out of the user's real defaults.
        #expect(Preferences.isThrowaway)
    }

    @Test func scanningLoadsResults() async throws {
        let model = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        model.scan()
        #expect(model.phase == .scanning)
        let deadline = Date().addingTimeInterval(5)
        while model.phase == .scanning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.phase == .results)
        #expect(model.categories.count == 2)
        #expect(model.lastScanDate != nil)
    }

    @Test func checkupSummaries() {
        let checkup = CheckupModel()
        let cleanup = CatalogModuleModel(kind: .cleanup, engine: Self.engine())
        cleanup.load(Self.sample)
        #expect(checkup.summary(cleanup) == .found("\(ByteFormat.string(150)) of junk"))
        let protection = CatalogModuleModel(kind: .protection, engine: Self.engine(measuresSize: false))
        protection.load(Self.sample)
        #expect(checkup.summary(protection) == .found("2 threats to remove"))
        let empty = CatalogModuleModel(kind: .performance, engine: Self.engine(measuresSize: false))
        empty.load([])
        #expect(checkup.summary(empty) == .clean)
        // A module with no finished scan never claims to be clean.
        let unscanned = CatalogModuleModel(kind: .protection, engine: Self.engine(measuresSize: false))
        #expect(checkup.summary(unscanned) == .notScanned)

        // Applications: only items in "updates" are updates; preselected leftovers are space to remove.
        let applications = CatalogModuleModel(kind: .applications, engine: Self.engine())
        let update = { (id: String) in Fixtures.item(id, size: 0, selected: true) }
        applications.load([
            ScanCategory(id: "updates", title: "Updates", summary: "", symbol: "x", groups: [
                ScanGroup(id: "direct", title: "Direct", icon: .symbol("x"), items: [update("u1"), update("u2")])]),
            ScanCategory(id: "leftovers", title: "Leftovers", summary: "", symbol: "x", groups: [
                ScanGroup(id: "old", title: "Old", icon: .symbol("x"), items: [Fixtures.item("cache", size: 320_000_000, selected: true)])]),
        ])
        #expect(checkup.summary(applications) == .found("2 updates\n\(ByteFormat.string(320_000_000)) to remove"))
        applications.selected = ["u1"]
        #expect(checkup.summary(applications) == .found("1 update"))
        applications.selected = ["cache"]
        #expect(checkup.summary(applications) == .found("\(ByteFormat.string(320_000_000)) to remove"))

        unscanned.load(Self.sample)
        unscanned.previewDone([])
        #expect(checkup.summary(unscanned) == .notScanned)
    }
}

@Suite struct AutomationScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func nextRunFollowsTheFrequency() {
        var schedule = CheckupSchedule()
        let monday = date("2026-10-19T12:00:00Z")
        #expect(schedule.nextRun(after: monday, calendar: calendar) == nil)

        schedule.frequency = .daily
        schedule.hour = 9
        #expect(schedule.nextRun(after: monday, calendar: calendar) == date("2026-10-20T09:00:00Z"))

        schedule.frequency = .weekly
        schedule.weekday = 1  // Sunday
        #expect(schedule.nextRun(after: monday, calendar: calendar) == date("2026-10-25T09:00:00Z"))

        schedule.frequency = .monthly
        schedule.dayOfMonth = 31  // clamped to the 28th so every month has it
        #expect(schedule.nextRun(after: monday, calendar: calendar) == date("2026-10-28T09:00:00Z"))
    }

    @Test func unattendedCleaningOnlyTakesHomeCachesAndLogsToTheTrash() {
        func remove(_ path: String, selected: Bool = true, mode: RemovalMode = .deletePermanently) -> ScanItem {
            ScanItem(id: path, title: path, size: 10, isSelectedByDefault: selected, action: .remove(paths: [path], mode: mode))
        }
        func category(_ id: String, _ items: [ScanItem]) -> ScanCategory {
            ScanCategory(id: id, title: id, summary: "", symbol: "x", groups: [ScanGroup(id: id, title: id, icon: .symbol("x"), items: items)])
        }
        let categories = [
            category("userCaches", [remove("/Users/me/Library/Caches/app"), remove("/Users/me/Library/Caches/kept", selected: false)]),
            category("systemCaches", [remove("/Library/Caches/com.vendor")]),
            category("logs", [remove("/Users/me/Library/Logs/app.log"), remove("/private/var/log/system.log.0.gz")]),
            category("trash", [remove("/Users/me/.Trash/old.zip")]),
            category("deviceBackups", [remove("/Users/me/Library/Application Support/MobileSync/Backup/X")]),
        ]
        let junk = AutomationModel.unattendedJunk(categories, home: "/Users/me")
        #expect(junk.map(\.id) == ["/Users/me/Library/Caches/app", "/Users/me/Library/Logs/app.log"])
        #expect(junk.allSatisfy { if case .remove(_, .moveToTrash) = $0.action { true } else { false } })
    }

    @Test func eachTidyRuleWaitsADayFromWhenItWasSwitchedOn() {
        let monday = Date(timeIntervalSince1970: 1_000_000)
        let rules = [TidyRule(kind: .oldInstallers, isEnabled: true, days: 7, activeFrom: monday.addingTimeInterval(-5 * 86_400)),
                     TidyRule(kind: .desktopScreenshots, isEnabled: false, days: 14)]
        var switchedOn = rules
        switchedOn[1].isEnabled = true
        let stamped = AutomationModel.stampingActivation(switchedOn, previous: rules, now: monday)
        // The new rule waits a day; the one already on keeps its own date and stays due.
        #expect(stamped[1].activeFrom == monday)
        #expect(stamped[0].activeFrom == rules[0].activeFrom)
        #expect(stamped[0].isDue(at: monday))
        #expect(!stamped[1].isDue(at: monday.addingTimeInterval(3_600)))
        #expect(stamped[1].isDue(at: monday.addingTimeInterval(86_400)))
        var off = stamped
        off[0].isEnabled = false
        #expect(AutomationModel.stampingActivation(off, previous: stamped, now: monday)[0].activeFrom == nil)
    }

    @MainActor
    @Test func automationNeverRunsDuringTests() async {
        let automation = AutomationModel()
        automation.rules = TidyRule.defaults.map { TidyRule(kind: $0.kind, isEnabled: true, days: 0) }
        #expect(await automation.tidy(automation.rules).isEmpty)
        automation.runDueWork(now: Date().addingTimeInterval(400 * 86_400))
        #expect(!automation.isRunning)
    }
}


@MainActor
@Suite struct AssistantSamplingTests {
    @Test func samplingRunsOnlyWhileSomeoneIsLooking() {
        let model = AssistantModel()
        model.start(for: "assistant")
        model.start(for: "menuBar")
        model.stop(for: "assistant")
        #expect(model.isSampling)
        model.stop(for: "menuBar")
        #expect(!model.isSampling)
    }
}


@MainActor
@Suite struct DiskMapRetryTests {
    @Test func tryAgainScansTheSameFolderAgain() async throws {
        let model = DiskMapModel(history: SizeHistory(folder: nil))
        let missing = URL(fileURLWithPath: "/no/such/folder-\(UUID().uuidString)")
        model.scan(missing)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .failed = model.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed(let message) = model.phase else { Issue.record("scan didn't fail"); return }
        #expect(message.contains("No such file or directory"))
        #expect(!message.contains("unreadable("))
        model.retry()
        guard case .scanning(let path, _) = model.phase else { Issue.record("retry didn't scan"); return }
        #expect(path == missing.path)
    }

    @Test func aPrivacyRefusalSaysHowToFixIt() {
        let refused = DiskMapModel.message(for: ScanError.unreadable("/Users/me/Library/Mail", errno: EPERM))
        #expect(refused.hasPrefix("Can't read “/Users/me/Library/Mail”: Operation not permitted."))
        #expect(refused.contains("Full Disk Access"))
        let locked = DiskMapModel.message(for: ScanError.unreadable("/private/x", errno: EACCES))
        #expect(!locked.contains("Full Disk Access"))
        #expect(DiskMapModel.message(for: ScanError.notADirectory("/etc/hosts")) == "“/etc/hosts” isn't a folder.")
    }
}
