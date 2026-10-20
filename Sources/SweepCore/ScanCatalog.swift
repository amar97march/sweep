import Foundation

/// Results shared by every list-style module: categories → groups → items, each item with a size,
/// a default selection, and what to do with it.
public struct ScanCategory: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    /// Shown above the groups in the review screen.
    public let summary: String
    public let symbol: String
    public var groups: [ScanGroup]

    public init(id: String, title: String, summary: String, symbol: String, groups: [ScanGroup]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.groups = groups
    }

    public var size: UInt64 { groups.reduce(0) { $0 + $1.size } }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
}

public struct ScanGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: ItemIcon
    public var items: [ScanItem]

    public init(id: String, title: String, subtitle: String? = nil, icon: ItemIcon, items: [ScanItem]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.items = items
    }

    public var size: UInt64 { items.reduce(0) { $0 + $1.size } }
}

public enum ItemIcon: Sendable, Hashable {
    /// SF Symbol name.
    case symbol(String)
    /// Use Finder's icon for this file or app.
    case file(String)
}

public struct ScanItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let size: UInt64
    public let date: Date?
    public let isSelectedByDefault: Bool
    public let action: ItemAction
    /// Shown instead of a checkbox when the item can't be acted on.
    public let note: String?

    public init(
        id: String, title: String, subtitle: String? = nil, size: UInt64, date: Date? = nil,
        isSelectedByDefault: Bool, action: ItemAction, note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.size = size
        self.date = date
        self.isSelectedByDefault = isSelectedByDefault
        self.action = action
        self.note = note
    }

    public static func == (lhs: ScanItem, rhs: ScanItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum ItemAction: Sendable, Hashable {
    /// Remove these paths.
    case remove(paths: [String], mode: RemovalMode)
    /// Run a named task (maintenance scripts, etc.); the module knows how.
    case task(String)
    /// Module-specific action with a payload.
    case custom(kind: String, payload: [String])
    /// Informational only.
    case none

    public var paths: [String] {
        if case .remove(let paths, _) = self { return paths }
        return []
    }
}

/// What happened to one item when the module acted on it.
public struct ActionRecord: Identifiable, Sendable, Codable, Equatable {
    public enum Outcome: Sendable, Codable, Equatable {
        case done(String)
        case skipped(String)
        case failed(String)
    }

    public var id = UUID()
    /// The `ScanItem` this record is about, when there is one.
    public var itemID: String?
    public let title: String
    public let detail: String
    public let bytes: UInt64
    public let outcome: Outcome

    public init(itemID: String? = nil, title: String, detail: String, bytes: UInt64, outcome: Outcome) {
        self.itemID = itemID
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.outcome = outcome
    }

    public var succeeded: Bool {
        if case .done = outcome { return true }
        return false
    }

    public init(_ removal: RemovalRecord, title: String, itemID: String? = nil) {
        let outcome: Outcome
        switch removal.outcome {
        case .trashed: outcome = .done("Moved to Trash")
        case .deleted: outcome = .done("Removed")
        case .skipped(let reason): outcome = .skipped(reason)
        case .failed(let reason): outcome = .failed(reason)
        }
        self.init(itemID: itemID, title: title, detail: removal.path, bytes: removal.bytes, outcome: outcome)
    }
}

public extension FileRemover {
    /// Removes the paths of every `.remove` item and reports one record per item.
    func perform(_ items: [ScanItem], progress: (@Sendable (Int, Int) -> Void)? = nil) -> [ActionRecord] {
        var records: [ActionRecord] = []
        for (index, item) in items.enumerated() {
            guard case .remove(let paths, let mode) = item.action, !paths.isEmpty else { continue }
            let share = item.size / UInt64(paths.count)
            let results = remove(paths.map { RemovalRequest(path: $0, bytes: share) }, mode: mode)
            let failures = results.filter { !$0.succeeded }
            if failures.isEmpty {
                let verb = mode == .moveToTrash ? "Moved to Trash" : "Removed"
                records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? paths[0],
                                            bytes: item.size, outcome: .done(verb)))
            } else if failures.count == results.count, let first = failures.first {
                records.append(ActionRecord(first, title: item.title, itemID: item.id))
            } else {
                let freed = results.filter(\.succeeded).reduce(0) { $0 + $1.bytes }
                records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? paths[0], bytes: freed,
                                            outcome: .failed("\(failures.count) of \(results.count) files could not be removed")))
            }
            progress?(index + 1, items.count)
        }
        return records
    }
}
