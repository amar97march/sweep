import AppKit
import Foundation
import Observation
import SweepCore

/// One review → remove → results pass over the items marked in Disk Map.
@MainActor
@Observable
public final class RemovalSession: Identifiable {
    public enum Phase {
        case review
        case removing(done: Int, total: Int)
        case finished([RemovalRecord])
    }

    public let id = UUID()
    public let items: [LensItem]
    public private(set) var phase = Phase.review
    /// Off by default: items go to the Trash and can be put back.
    public var deletesPermanently = false
    /// Why an item will be skipped, found before anything is touched.
    public private(set) var warnings: [LensItem.ID: String] = [:]

    @ObservationIgnored private let remover: FileRemover
    @ObservationIgnored private var isPreview = false

    public init(items: [LensItem], remover: FileRemover = FileRemover()) {
        self.items = items
        self.remover = remover
        refreshWarnings()
    }

    public var mode: RemovalMode { deletesPermanently ? .deletePermanently : .moveToTrash }
    public var removableItems: [LensItem] { items.filter { warnings[$0.id] == nil } }
    public var removableSize: UInt64 { removableItems.reduce(0) { $0 + $1.size } }

    public func refreshWarnings() {
        var warnings: [LensItem.ID: String] = [:]
        let paths = items.compactMap(\.path)
        let running = RunningApplications.blocking(paths)
        for item in items {
            guard let path = item.path else { continue }
            if let reason = remover.policy.refusal(for: path) {
                warnings[item.id] = reason
            } else if let app = running[path] {
                warnings[item.id] = "Quit \(app) first"
            }
        }
        self.warnings = warnings
    }

    /// Removes every item without a warning, then updates `model`'s tree.
    public func start(updating model: LensModel) {
        guard !isPreview, case .review = phase else { return }
        // Only what the review showed as removable is removed. An item that was going to be skipped stays
        // skipped even if, say, its app has quit since: the user never saw it in the list of things to remove.
        let approved = Set(removableItems.map(\.id))
        refreshWarnings()
        let requests = removableItems.filter { approved.contains($0.id) }.compactMap { item in
            item.path.map { RemovalRequest(path: $0, bytes: item.size) }
        }
        let skipped = items.compactMap { item -> RemovalRecord? in
            guard let path = item.path else { return nil }
            let reason = warnings[item.id] ?? (approved.contains(item.id) ? nil : "Wasn't ready when you reviewed it; review it again to remove it")
            return reason.map { RemovalRecord(date: Date(), path: path, bytes: item.size, mode: mode, outcome: .skipped(reason: $0)) }
        }
        // Skipped items belong in the removal history too, next to what was removed.
        if let log = remover.logURL, !skipped.isEmpty { try? RemovalLog.append(skipped, to: log) }
        let mode = self.mode
        let remover = self.remover
        phase = .removing(done: 0, total: requests.count)

        Task.detached(priority: .userInitiated) { [weak self] in
            let records = remover.remove(requests, mode: mode) { done, total in
                Task { @MainActor in self?.progress(done, total) }
            }
            await MainActor.run {
                model.applyRemoval(records)
                self?.phase = .finished(records + skipped)
            }
        }
    }

    /// Screenshots only: shows `phase` without removing anything. After this, `start` does nothing.
    public func preview(_ phase: Phase) {
        isPreview = true
        self.phase = phase
    }

    private func progress(_ done: Int, _ total: Int) {
        if case .removing = phase { phase = .removing(done: done, total: total) }
    }
}

enum RunningApplications {
    /// Maps each path to the name of a running app that lives at or inside it, or that it is inside.
    @MainActor static func blocking(_ paths: [String]) -> [String: String] {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (bundle: String, name: String)? in
            guard let bundle = app.bundleURL?.path else { return nil }
            return (bundle, app.localizedName ?? (bundle as NSString).lastPathComponent)
        }
        return blocking(paths, running: apps)
    }

    static func blocking(_ paths: [String], running apps: [(bundle: String, name: String)]) -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            // The app is inside what's marked, or what's marked is inside a running app.
            if let match = apps.first(where: { $0.bundle == path || $0.bundle.hasPrefix(path + "/") || path.hasPrefix($0.bundle + "/") }) {
                result[path] = match.name
            }
        }
        return result
    }
}
