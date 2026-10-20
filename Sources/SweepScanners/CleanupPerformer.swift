import Foundation
import SweepCore

/// Removes selected items. Files the user can't remove are retried together with administrator rights,
/// so there is at most one password prompt per run.
public enum CleanupPerformer {
    public static func perform(
        _ items: [ScanItem],
        remover: FileRemover,
        allowAdministrator: Bool,
        administrator: ([String]) -> Result<Void, Administrator.Failure> = Administrator.removeItems,
        progress: (Int, Int) -> Void = { _, _ in }
    ) -> [ActionRecord] {
        var records: [String: ActionRecord] = [:]
        var denied: [(item: ScanItem, paths: [String], freed: UInt64)] = []

        for (index, item) in items.enumerated() {
            defer { progress(index + 1, items.count) }
            guard case .remove(let paths, let mode) = item.action, !paths.isEmpty else { continue }
            let share = item.size / UInt64(paths.count)
            let results = remover.remove(paths.map { RemovalRequest(path: $0, bytes: share) }, mode: mode)
            let deniedPaths = results.filter { $0.outcome == .failed(reason: "Permission denied") }.map(\.path)
            let freed = results.filter(\.succeeded).reduce(0) { $0 + $1.bytes }

            // Root-owned items can only be deleted as root, never moved to the user's Trash, so the administrator
            // retry is only for items the user chose to delete permanently. Paths that pass through a symlink are
            // never handed to root: the link could have been changed to point somewhere else.
            if !deniedPaths.isEmpty, allowAdministrator, mode == .deletePermanently, deniedPaths.allSatisfy(Self.isPlainPath) {
                denied.append((item, deniedPaths, freed))
            } else if !deniedPaths.isEmpty, mode == .moveToTrash {
                records[item.id] = ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? deniedPaths[0],
                                                bytes: freed, outcome: .failed("Needs administrator permission, so it can't go to your Trash"))
            } else {
                records[item.id] = record(for: item, results: results, freed: freed, mode: mode)
            }
        }

        if !denied.isEmpty {
            let outcome = administrator(denied.flatMap(\.paths))
            for entry in denied {
                let remaining = entry.paths.filter { FileManager.default.fileExists(atPath: $0) }
                if remaining.isEmpty {
                    records[entry.item.id] = ActionRecord(itemID: entry.item.id, title: entry.item.title,
                                                          detail: entry.item.subtitle ?? entry.paths[0],
                                                          bytes: entry.item.size,
                                                          outcome: .done("Removed with administrator permission"))
                } else {
                    let reason: String
                    switch outcome {
                    case .failure(.cancelled): reason = "Needs your administrator password"
                    case .failure(.failed(let message)): reason = message
                    case .success: reason = "Could not be removed"
                    }
                    records[entry.item.id] = ActionRecord(itemID: entry.item.id, title: entry.item.title,
                                                          detail: entry.item.subtitle ?? entry.paths[0],
                                                          bytes: entry.freed, outcome: .failed(reason))
                }
            }
        }
        return items.compactMap { records[$0.id] }
    }

    /// True when no part of `path` is a symlink, so root would delete exactly what was checked.
    static func isPlainPath(_ path: String) -> Bool {
        guard let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        return String(cString: resolved) == path
    }

    /// Applies "Move cleaned items to the Trash" when the clean runs, not when the scan ran, so changing the
    /// setting after a scan takes effect. Items already in a Trash are always deleted for good.
    public static func applyingTrashPreference(_ items: [ScanItem], usesTrash: Bool) -> [ScanItem] {
        guard usesTrash else { return items }
        return items.map { item in
            guard case .remove(let paths, .deletePermanently) = item.action,
                  !paths.contains(where: { $0.contains("/.Trash/") || $0.contains("/.Trashes/") }) else { return item }
            return ScanItem(id: item.id, title: item.title, subtitle: item.subtitle, size: item.size, date: item.date,
                            isSelectedByDefault: item.isSelectedByDefault, action: .remove(paths: paths, mode: .moveToTrash),
                            note: item.note)
        }
    }

    private static func record(for item: ScanItem, results: [RemovalRecord], freed: UInt64,
                               mode: RemovalMode) -> ActionRecord {
        let failures = results.filter { !$0.succeeded }
        let detail = item.subtitle ?? results.first?.path ?? ""
        if failures.isEmpty {
            return ActionRecord(itemID: item.id, title: item.title, detail: detail, bytes: item.size,
                                outcome: .done(mode == .moveToTrash ? "Moved to Trash" : "Removed"))
        }
        if failures.count == results.count, let first = failures.first {
            return ActionRecord(first, title: item.title, itemID: item.id)
        }
        return ActionRecord(itemID: item.id, title: item.title, detail: detail, bytes: freed,
                            outcome: .failed("\(failures.count) of \(results.count) files could not be removed"))
    }
}
