import Foundation
import SweepCore

/// Apps dragged to the Trash leave their settings, caches and support files behind. This finds those files for an
/// app that's just been trashed, so they can go too.
public enum TrashedApps {
    /// App bundles directly in the Trash (needs Full Disk Access to list it).
    public static func apps(inTrash folder: String) -> [InstalledApp] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { $0.hasSuffix(".app") }
            .compactMap { InstalledApp(path: folder + "/" + $0) }
    }

    /// The trashed app's files as a category to review, or nil when there are none, or when another copy of the
    /// app is still installed (its files are still in use).
    public static func leftovers(of app: InstalledApp, environment: ScanEnvironment) -> ScanCategory? {
        let installed = AppCatalog.installed(in: environment)
        guard !installed.contains(where: { $0.bundleID == app.bundleID }) else { return nil }
        let index = LibraryIndex(environment: environment)
        let identity = AppIdentity(app)
        // Files shared with the vendor's other apps (an Office group container) belong to no single app: compare
        // claims the way the Uninstaller does, and keep only what's this app's alone.
        let vendor = AppIdentity.vendor(app.bundleID.lowercased())
        let siblings = installed.filter { vendor != nil && AppIdentity.vendor($0.bundleID.lowercased()) == vendor }.map(AppIdentity.init)
        let claims = [(identity, index.resources(of: identity, appPath: app.path))]
            + siblings.map { ($0, index.resources(of: $0, appPath: $0.path)) }
        let files = ApplicationsScanner.assignShared(claims).first ?? []
        guard !files.isEmpty else { return nil }
        let items = files.map { leftover in
            ScanItem(id: "trashed:" + leftover.path, title: leftover.kind.title, subtitle: leftover.path,
                     size: Measure.size(leftover.path), isSelectedByDefault: true, action: leftover.action)
        }
        return ScanCategory(id: "trashedLeftovers", title: "Left by \(app.name)",
                            summary: "\(app.name) is in the Trash, but these files of it are still on your Mac.",
                            symbol: "trash.slash.fill",
                            groups: [ScanGroup(id: "trashed:" + app.bundleID, title: app.name, subtitle: "Moved to the Trash",
                                               icon: .file(app.path), items: items)])
    }
}
