import Foundation
import Observation
import SweepCore

/// One thing shown in Disk Map: a folder, a file, or the "other items" bucket for small entries.
public struct LensItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        /// Small entries folded together so the chart stays readable.
        case other(count: Int)
    }

    public let id: String
    public let name: String
    public let size: UInt64
    public let kind: Kind
    public let path: String?
    /// The scanned folder, for `.directory` items.
    public let directory: DirectoryNode?
    /// The folder this item is listed in.
    public let container: DirectoryNode?

    public static func == (lhs: LensItem, rhs: LensItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var isOpenable: Bool {
        guard let directory else { return false }
        return directory.status == .scanned || { if case .partial = directory.status { true } else { false } }()
    }

    public var statusNote: String? {
        switch directory?.status {
        case .inaccessible?: "No access"
        case .partial?: "Partly read"
        case .skippedMountPoint?: "Other volume"
        case .skippedExcluded?: "Excluded"
        default: nil
        }
    }

    /// Children and files of `node`, largest first. Items past `limit`, or smaller than `minimumFraction`
    /// of the folder, are folded into one "other items" entry.
    public static func items(of node: DirectoryNode, limit: Int, minimumFraction: Double) -> [LensItem] {
        let threshold = UInt64(Double(node.allocatedSize) * minimumFraction)
        var result: [LensItem] = []
        var otherSize: UInt64 = 0
        var otherCount = 0

        // Children and files are each sorted already; merge them.
        var childIndex = 0, fileIndex = 0
        while childIndex < node.children.count || fileIndex < node.files.count {
            let takeChild: Bool
            if childIndex == node.children.count {
                takeChild = false
            } else if fileIndex == node.files.count {
                takeChild = true
            } else {
                takeChild = node.children[childIndex].allocatedSize >= node.files[fileIndex].allocatedSize
            }
            let item: LensItem
            if takeChild {
                let child = node.children[childIndex]
                childIndex += 1
                item = LensItem(id: child.path, name: child.name, size: child.allocatedSize,
                                kind: .directory, path: child.path, directory: child, container: node)
            } else {
                let file = node.files[fileIndex]
                fileIndex += 1
                let path = (node.path == "/" ? "" : node.path) + "/" + file.name
                item = LensItem(id: path, name: file.name, size: file.allocatedSize,
                                kind: .file, path: path, directory: nil, container: node)
            }
            if result.count < limit && (item.size >= threshold || item.statusNote != nil) {
                result.append(item)
            } else {
                otherSize += item.size
                otherCount += 1
            }
        }
        if otherCount > 0 {
            result.append(LensItem(id: node.path + "\u{0}other", name: "\(otherCount) smaller items",
                                   size: otherSize, kind: .other(count: otherCount), path: nil,
                                   directory: nil, container: node))
        }
        return result
    }
}

/// Navigation, selection and removal state for one Disk Map result.
@MainActor
@Observable
public final class LensModel {
    public let result: ScanResult
    public private(set) var current: DirectoryNode
    /// Highlighted item (click).
    public var selection: LensItem.ID?
    public var hovered: LensItem.ID?
    /// Show every entry instead of folding small ones.
    public private(set) var showsAllItems = false
    /// Items marked for removal, by path. A marked folder covers everything inside it.
    public private(set) var marked: [String: LensItem] = [:]
    /// The review / removal sheet, when open.
    public var removal: RemovalSession?
    /// Bumped when the tree changes, so views recompute.
    public private(set) var revision = 0
    /// An earlier scan of the same place, for "What Grew".
    public var baseline: SizeSnapshot? {
        didSet { growthCache = nil }
    }
    /// Dates of every earlier scan that can be picked as the baseline, newest first.
    public var baselineDates: [Date] = []
    /// Loads the snapshot taken at one of `baselineDates`.
    @ObservationIgnored public var loadBaseline: ((Date) -> SizeSnapshot?)?
    /// Shows the "What Grew" list in place of the folder list.
    public var showsGrowth = false

    public static let itemLimit = 60
    public static let minimumFraction = 0.002

    @ObservationIgnored private var backStack: [DirectoryNode] = []
    @ObservationIgnored private var forwardStack: [DirectoryNode] = []
    @ObservationIgnored private var layoutCache: (key: String, bubbles: [Bubble])?
    @ObservationIgnored private var growthCache: (revision: Int, growth: [Growth])?

    public init(result: ScanResult, baseline: SizeSnapshot? = nil) {
        self.result = result
        self.baseline = baseline
        current = result.root
    }

    // MARK: What grew

    /// Where the space grew since `baseline`, biggest first.
    public var growth: [Growth] {
        _ = revision
        guard let baseline else { return [] }
        if let cache = growthCache, cache.revision == revision { return cache.growth }
        let growth = baseline.growth(of: result.root)
        growthCache = (revision, growth)
        return growth
    }

    /// Change in the root folder since `baseline`.
    public var totalChange: Int64? {
        guard let baseline, let before = baseline.sizes[result.root.path] else { return nil }
        return Int64(result.root.allocatedSize) - Int64(before)
    }

    /// How much `item` changed since `baseline`: a byte difference, or nil when Sweep can't tell.
    /// Items that weren't recorded but whose folder was count as new (or under the snapshot's threshold).
    public func change(for item: LensItem) -> ItemChange? {
        guard let baseline, let path = item.path else { return nil }
        if case .other = item.kind { return nil }
        switch baseline.previous(path) {
        case .size(let before): return .changed(Int64(item.size) - Int64(before))
        case .belowThreshold: return item.size >= baseline.threshold ? .new : nil
        case .unknown: return nil
        }
    }

    public enum ItemChange: Equatable, Sendable {
        case changed(Int64)
        case new
    }

    public func useBaseline(from date: Date) {
        if let snapshot = loadBaseline?(date) { baseline = snapshot }
    }

    /// Opens the folder at `path` (or the folder containing the file there).
    public func reveal(_ path: String) {
        var node = result.root
        let relative = path.dropFirst(result.root.path == "/" ? 1 : result.root.path.count + 1)
        for name in relative.split(separator: "/").map(String.init) {
            guard let child = node.children.first(where: { $0.name == name }) else { break }
            node = child
        }
        navigate(to: node)
        selection = node.path == path ? nil : path
    }

    public var items: [LensItem] {
        _ = revision
        return LensItem.items(of: current,
                              limit: showsAllItems ? .max : Self.itemLimit,
                              minimumFraction: showsAllItems ? 0 : Self.minimumFraction)
    }

    public var breadcrumb: [DirectoryNode] { current.ancestry }
    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
    public var canGoUp: Bool { current.parent != nil }

    public func item(withID id: LensItem.ID?) -> LensItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: Navigation

    /// Opens a folder, or expands the "other items" bucket.
    public func open(_ item: LensItem) {
        if case .other = item.kind {
            showsAllItems = true
        } else if item.isOpenable, let directory = item.directory {
            navigate(to: directory)
        }
    }

    public func navigate(to node: DirectoryNode) {
        guard node !== current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        show(node)
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        show(previous)
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        show(next)
    }

    public func goUp() {
        if let parent = current.parent { navigate(to: parent) }
    }

    // MARK: Marking for removal

    public func canMark(_ item: LensItem) -> Bool {
        guard item.path != nil, item.container != nil else { return false }
        if case .other = item.kind { return false }
        return item.directory?.status != .skippedMountPoint
    }

    public func isMarked(_ item: LensItem) -> Bool { marked[item.id] != nil }

    /// True when a folder containing this item is marked.
    public func isCoveredByMarkedFolder(_ item: LensItem) -> Bool {
        guard let path = item.path else { return false }
        return marked.keys.contains { path.hasPrefix($0 + "/") }
    }

    public func toggleMark(_ item: LensItem) {
        if marked.removeValue(forKey: item.id) != nil { return }
        guard canMark(item), !isCoveredByMarkedFolder(item) else { return }
        // Marking a folder replaces marks on anything inside it, so nothing is counted twice.
        marked = marked.filter { !$0.key.hasPrefix(item.id + "/") }
        marked[item.id] = item
    }

    public func clearMarks() { marked.removeAll() }

    public var markedItems: [LensItem] { marked.values.sorted { $0.size > $1.size } }
    public var markedSize: UInt64 { marked.values.reduce(0) { $0 + $1.size } }

    public func reviewMarkedItems() {
        guard !marked.isEmpty else { return }
        removal = RemovalSession(items: markedItems)
    }

    /// Removes successfully deleted or trashed items from the tree and from the marks.
    public func applyRemoval(_ records: [RemovalRecord]) {
        var removedPaths = Set<String>()
        for record in records where record.succeeded {
            guard let item = marked[record.path], let container = item.container else { continue }
            if container.removeEntry(named: item.name) { removedPaths.insert(record.path) }
            marked.removeValue(forKey: record.path)
        }
        guard !removedPaths.isEmpty else { return }

        // If the folder being viewed (or one above it) went away, step out to what still exists.
        if let gone = current.ancestry.first(where: { removedPaths.contains($0.path) }), let parent = gone.parent {
            current = parent
        }
        backStack.removeAll()
        forwardStack.removeAll()
        selection = nil
        hovered = nil
        layoutCache = nil
        revision += 1
    }

    // MARK: Layout

    /// Bubble layout for the current folder, cached per folder, revision and size.
    public func bubbles(in size: CGSize) -> [Bubble] {
        let key = "\(current.path)|\(showsAllItems)|\(revision)|\(Int(size.width))x\(Int(size.height))"
        if let cache = layoutCache, cache.key == key { return cache.bubbles }
        let bubbles = BubbleLayout.layout(items: items, in: size)
        layoutCache = (key, bubbles)
        return bubbles
    }

    private func show(_ node: DirectoryNode) {
        current = node
        selection = nil
        hovered = nil
        showsAllItems = false
    }
}
