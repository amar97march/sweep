import Foundation
import Observation
import SweepCore

/// Progress reported by a scan or an action, plus a stop flag the work can poll.
public final class ProgressSink: Sendable {
    public struct Update: Sendable, Equatable {
        public var message: String
        public var fraction: Double?
        public init(message: String = "", fraction: Double? = nil) {
            self.message = message
            self.fraction = fraction
        }
    }

    private let handler: @Sendable (Update) -> Void
    private let stopped = LockedFlag()

    public init(handler: @escaping @Sendable (Update) -> Void) { self.handler = handler }

    public func report(_ message: String, fraction: Double? = nil) {
        handler(Update(message: message, fraction: fraction))
    }

    public var isCancelled: Bool { stopped.value }
    func cancel() { stopped.set() }
}

final class LockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// How a list-style module finds things and acts on them.
public struct ModuleEngine: Sendable {
    public var scan: @Sendable (ProgressSink) async throws -> [ScanCategory]
    public var perform: @Sendable ([ScanItem], ProgressSink) async -> [ActionRecord]
    /// Verb on the main button, e.g. "Clean" or "Remove".
    public var actionVerb: String
    public var workingMessage: String
    public var doneTitle: String
    /// False for modules whose items have no size (tasks, login items): screens show counts instead.
    public var measuresSize: Bool
    /// Button title for the current selection; defaults to `actionVerb`.
    public var verb: (@Sendable ([ScanItem]) -> String)?

    public init(
        actionVerb: String, workingMessage: String, doneTitle: String, measuresSize: Bool = true,
        scan: @escaping @Sendable (ProgressSink) async throws -> [ScanCategory],
        perform: @escaping @Sendable ([ScanItem], ProgressSink) async -> [ActionRecord]
    ) {
        self.scan = scan
        self.perform = perform
        self.actionVerb = actionVerb
        self.workingMessage = workingMessage
        self.doneTitle = doneTitle
        self.measuresSize = measuresSize
    }
}

/// State of one list-style module: intro → scanning → results → review → working → done.
@MainActor
@Observable
public final class CatalogModuleModel {
    public enum Phase: Equatable {
        case intro, scanning, results, review, working, done
        case failed(String)
    }

    public enum SortOrder: String, CaseIterable, Sendable {
        case size = "Size", name = "Name", date = "Date"
    }

    public let kind: ModuleKind
    public let engine: ModuleEngine
    public private(set) var phase = Phase.intro
    public private(set) var progress = ProgressSink.Update()
    public private(set) var categories: [ScanCategory] = []
    public private(set) var records: [ActionRecord] = []
    public var selected: Set<ScanItem.ID> = []
    public var focusedCategory: ScanCategory.ID?
    public var focusedGroup: ScanGroup.ID?
    public var searchText = ""
    public var sortOrder = SortOrder.size
    public private(set) var lastScanDate: Date?

    @ObservationIgnored private var sink: ProgressSink?
    /// Identifies the scan or action whose progress is on screen, so a stopped one can't write over it.
    @ObservationIgnored private var runToken = UUID()
    /// A category to open as soon as a scan finishes (set when another screen sends the user here).
    @ObservationIgnored private var pendingFocus: ScanCategory.ID?
    /// With `pendingFocus`: the one item to select there (System Data's "Thin Snapshots" means only that task).
    @ObservationIgnored private var pendingItem: ScanItem.ID?

    public init(kind: ModuleKind, engine: ModuleEngine) {
        self.kind = kind
        self.engine = engine
    }

    public var theme: ModuleTheme { kind.theme }

    // MARK: Flow

    /// Starts a scan. Ignored while an action is running: its results must not be thrown away.
    public func scan() {
        guard phase != .working else { return }
        sink?.cancel()
        let token = UUID()
        runToken = token
        let sink = ProgressSink { [weak self] update in
            Task { @MainActor in self?.progressChanged(update, token: token) }
        }
        self.sink = sink
        progress = .init(message: "Starting…")
        phase = .scanning
        let engine = engine
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let found = try await engine.scan(sink)
                await self?.scanFinished(found, sink: sink)
            } catch {
                await self?.scanFailed(error, sink: sink)
            }
        }
    }

    /// Stops a scan. An action that has started always runs to the end, so its results are recorded.
    public func stop() {
        guard phase == .scanning else { return }
        sink?.cancel()
        sink = nil
        pendingFocus = nil
        pendingItem = nil
        phase = categories.isEmpty ? .intro : .results
    }

    public func review(category: ScanCategory.ID? = nil) {
        focusedCategory = category ?? focusedCategory ?? categories.first?.id
        focusedGroup = nil
        phase = .review
    }

    public func showResults() { phase = .results }

    /// Opens `category`'s review, scanning first when there are no results to show. With `item`, only that
    /// item ends up selected, so running the review does just what the user came for.
    public func focus(on category: ScanCategory.ID, item: ScanItem.ID? = nil) {
        switch phase {
        case .results, .review, .done:
            // Already scanned: open the category if the scan found anything there.
            if categories.contains(where: { $0.id == category }) { review(category: category, selectingOnly: item) }
        case .scanning:
            pendingFocus = category
            pendingItem = item
        case .working:
            break
        case .intro, .failed:
            pendingFocus = category
            pendingItem = item
            scan()
        }
    }

    private func review(category: ScanCategory.ID, selectingOnly item: ScanItem.ID?) {
        review(category: category)
        guard let item, let group = categories.first(where: { $0.id == category })?.groups.first(where: { $0.items.contains { $0.id == item } })
        else { return }
        selected = [item]
        focusedGroup = group.id
    }

    /// Acts on every selected item.
    public func run() {
        let items = selectedItems
        guard !items.isEmpty, phase == .results || phase == .review else { return }
        let token = UUID()
        runToken = token
        let sink = ProgressSink { [weak self] update in
            Task { @MainActor in self?.progressChanged(update, token: token) }
        }
        self.sink = sink
        progress = .init(message: engine.workingMessage, fraction: 0)
        phase = .working
        let engine = engine
        Task.detached(priority: .userInitiated) { [weak self] in
            let records = await engine.perform(items, sink)
            await self?.runFinished(records, sink: sink)
        }
    }

    public func startOver() {
        guard phase != .working else { return }
        pendingFocus = nil
        sink?.cancel()
        sink = nil
        categories = []
        records = []
        selected = []
        phase = .intro
    }

    /// Loads results directly (used by Checkup and for previews).
    public func load(_ categories: [ScanCategory]) {
        scanFinished(categories, sink: nil)
    }

    // MARK: Selection

    public var allItems: [ScanItem] { categories.flatMap { $0.groups.flatMap(\.items) } }
    /// Each item once. The same file can show up in two categories (a big file that is also a duplicate);
    /// it is one item for selecting, counting and acting on.
    public var uniqueItems: [ScanItem] {
        var seen = Set<ScanItem.ID>()
        return allItems.filter { seen.insert($0.id).inserted }
    }
    public var selectedItems: [ScanItem] { uniqueItems.filter { selected.contains($0.id) } }
    public var selectedSize: UInt64 { selectedItems.reduce(0) { $0 + $1.size } }
    /// Bytes of everything that can be acted on; items shown for information don't count.
    public var totalSize: UInt64 { uniqueItems.filter(isSelectable).reduce(0) { $0 + $1.size } }
    public var selectableCount: Int { uniqueItems.filter(isSelectable).count }

    /// "3.4 GB" for size-based modules, "5 items" otherwise (or when there are no bytes to show).
    public func amount(bytes: UInt64, count: Int) -> String {
        engine.measuresSize && bytes > 0 ? ByteFormat.string(bytes) : "\(count.formatted()) \(count == 1 ? "item" : "items")"
    }

    public var actionVerb: String { engine.verb?(selectedItems) ?? engine.actionVerb }

    public func isSelectable(_ item: ScanItem) -> Bool {
        item.note == nil && item.action != .none
    }

    public func state(of items: [ScanItem]) -> SelectionState {
        let selectable = items.filter(isSelectable)
        let count = selectable.filter { selected.contains($0.id) }.count
        if count == 0 { return .none }
        return count == selectable.count ? .all : .some
    }

    /// False when every item is shown for information only, so there's nothing to tick.
    public func canSelect(_ items: [ScanItem]) -> Bool { items.contains(where: isSelectable) }

    public func state(of category: ScanCategory) -> SelectionState { state(of: category.groups.flatMap(\.items)) }
    public func state(of group: ScanGroup) -> SelectionState { state(of: group.items) }

    public func toggle(_ items: [ScanItem]) {
        let selectable = items.filter(isSelectable)
        if state(of: selectable) == .all {
            selected.subtract(selectable.map(\.id))
        } else {
            selected.formUnion(selectable.map(\.id))
        }
    }

    public func toggle(item: ScanItem) {
        guard isSelectable(item) else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    /// Select what the scanners recommend.
    /// Preselects what the scanners suggest. An item listed in several places is preselected only if every
    /// listing suggests it.
    public func smartSelect() {
        let notSuggested = Set(allItems.filter { !$0.isSelectedByDefault }.map(\.id))
        selected = Set(uniqueItems.filter { $0.isSelectedByDefault && isSelectable($0) && !notSuggested.contains($0.id) }.map(\.id))
    }

    public func selectAll() { selected = Set(uniqueItems.filter(isSelectable).map(\.id)) }
    public func deselectAll() { selected = [] }

    // MARK: Review helpers

    public var currentCategory: ScanCategory? {
        categories.first { $0.id == focusedCategory } ?? categories.first
    }

    public var currentGroup: ScanGroup? {
        guard let category = currentCategory else { return nil }
        return category.groups.first { $0.id == focusedGroup } ?? category.groups.first
    }

    public func visibleItems(of group: ScanGroup) -> [ScanItem] {
        var items = group.items
        if !searchText.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || ($0.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        switch sortOrder {
        case .size: items.sort { $0.size > $1.size }
        case .name: items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date: items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return items
    }

    /// Screenshots only: show the scanning screen without scanning.
    func setPreviewScanning(_ update: ProgressSink.Update) {
        progress = update
        phase = .scanning
    }

    /// Screenshots only: show the done screen without acting on anything.
    func setPreview(records: [ActionRecord]) {
        self.records = records
        phase = .done
    }

    // MARK: Private

    private func progressChanged(_ update: ProgressSink.Update, token: UUID) {
        guard token == runToken, phase == .scanning || phase == .working else { return }
        progress = update
    }

    private func scanFinished(_ found: [ScanCategory], sink: ProgressSink?) {
        if let sink, sink !== self.sink || sink.isCancelled { return }
        categories = found.filter { !$0.groups.isEmpty }
        smartSelect()
        focusedCategory = categories.first?.id
        focusedGroup = nil
        lastScanDate = Date()
        ScanHistory.record(kind)
        phase = .results
        if let pending = pendingFocus {
            let item = pendingItem
            pendingFocus = nil
            pendingItem = nil
            if categories.contains(where: { $0.id == pending }) { review(category: pending, selectingOnly: item) }
        }
    }

    private func scanFailed(_ error: Error, sink: ProgressSink) {
        guard sink === self.sink, !sink.isCancelled else { return }
        phase = .failed("\(error.localizedDescription)")
    }

    private func runFinished(_ records: [ActionRecord], sink: ProgressSink) {
        guard sink === self.sink else { return }
        self.records = records
        // Drop finished items from the results; failed ones stay so the user can see and retry them.
        let attempted = Set(selectedItems.map(\.id))
        let identified = records.contains { $0.itemID != nil }
        let handled = identified ? Set(records.filter(\.succeeded).compactMap(\.itemID)) : attempted
        categories = categories.compactMap { category in
            var category = category
            category.groups = category.groups.compactMap { group in
                var group = group
                group.items.removeAll { handled.contains($0.id) }
                return group.items.isEmpty ? nil : group
            }
            return category.groups.isEmpty ? nil : category
        }
        selected.subtract(handled)
        phase = .done
    }
}
