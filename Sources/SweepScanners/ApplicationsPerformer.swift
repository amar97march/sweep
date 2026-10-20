import Foundation
import SweepCore

/// Builds the Updates category from the updates found.
public enum UpdateCatalog {
    public static func category(_ updates: [AppUpdate]) -> ScanCategory? {
        let sections: [(String, String, [AppUpdate])] = [
            ("App Store", "Opens the App Store page to update", updates.filter { if case .appStore = $0.source { true } else { false } }),
            ("Direct Updates", "Downloaded from the developer and verified before installing",
             updates.filter { if case .sparkle = $0.source { true } else { false } }),
            ("Homebrew", "Upgraded with brew", updates.filter { if case .homebrew = $0.source { true } else { false } }),
        ]
        let groups = sections.filter { !$0.2.isEmpty }.map { title, subtitle, updates in
            ScanGroup(id: "updates:" + title, title: title, subtitle: subtitle, icon: .symbol("arrow.down.app.fill"),
                      items: updates.map(item))
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "updates", title: "Updates", summary: "New versions of apps you have installed.",
                            symbol: "arrow.triangle.2.circlepath.circle.fill", groups: groups)
    }

    static func item(_ update: AppUpdate) -> ScanItem {
        let payload = (try? JSONEncoder().encode(update)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ScanItem(id: "update:" + update.bundleID, title: update.appName,
                        subtitle: "\(update.installedVersion) → \(update.newVersion)", size: 0, date: nil,
                        isSelectedByDefault: true, action: .custom(kind: "update", payload: [payload]))
    }

    public static func decode(_ item: ScanItem) -> AppUpdate? {
        guard case .custom("update", let payload) = item.action, let json = payload.first else { return nil }
        return try? JSONDecoder().decode(AppUpdate.self, from: Data(json.utf8))
    }
}

/// Uninstalls, resets and updates apps.
public struct ApplicationsPerformer: Sendable {
    public var remover = FileRemover()
    public var administrator: @Sendable ([[String]]) -> Result<String, Administrator.Failure> = Administrator.runBatch
    public var removeAsAdministrator: @Sendable ([String]) -> Result<Void, Administrator.Failure> = Administrator.removeItems
    public var fetch: UpdateChecker.Fetch = UpdateChecker.download
    /// Quits the app at a path; returns false if it's still running.
    public var quitApp: @Sendable (String) async -> Bool = { _ in true }
    public var openURL: @Sendable (URL) async -> Void = { _ in }
    public var brew: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile)
    public var requireCodeSignature = true
    public var trash: FileRemover.Trash = FileRemover.systemTrash

    public init() {}

    public func perform(_ items: [ScanItem], progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> [ActionRecord] {
        var records: [ActionRecord] = []
        let removals = items.filter { if case .remove = $0.action { true } else { false } }
        let receipts = items.filter { if case .custom("forgetReceipt", _) = $0.action { true } else { false } }
        let updates = items.compactMap { item in UpdateCatalog.decode(item).map { (item, $0) } }
        let total = items.count
        var done = 0

        // Quit every app whose bundle or files are about to be removed: an app that keeps running writes its
        // settings back (so a reset wouldn't stick) and may be using its files. If it won't quit, nothing of
        // it is touched.
        let apps = Set(removals.compactMap(Self.app(of:)))
        var stillRunning = Set<String>()
        for app in apps.sorted() where !(await quitApp(app)) { stillRunning.insert(app) }
        let blocked = removals.filter { item in Self.app(of: item).map(stillRunning.contains) ?? false }
        for item in blocked {
            records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: 0,
                                        outcome: .skipped("The app is still running")))
        }
        let removable = removals.filter { item in !blocked.contains(item) }
        let removeAsAdministrator = self.removeAsAdministrator
        records += CleanupPerformer.perform(removable, remover: remover, allowAdministrator: true,
                                            administrator: removeAsAdministrator) { finished, _ in
            progress(done + finished, total)
        }
        done += removals.count

        if !receipts.isEmpty {
            let ids = receipts.compactMap { if case .custom(_, let payload) = $0.action { payload.first } else { nil } }
            let result = administrator(ids.map { ["/usr/sbin/pkgutil", "--forget", $0] })
            for item in receipts {
                let outcome: ActionRecord.Outcome
                switch result {
                case .success: outcome = .done("Receipt removed")
                case .failure(.cancelled): outcome = .failed("Needs your administrator password")
                case .failure(.failed(let message)): outcome = .failed(message)
                }
                records.append(ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: 0,
                                            outcome: outcome))
            }
            done += receipts.count
            progress(done, total)
        }

        for (item, update) in updates {
            records.append(await install(update, item: item))
            done += 1
            progress(done, total)
        }
        return records
    }

    /// The app an Uninstaller item belongs to: its bundle, or the app named in a file's "<app path>|<file>" id.
    static func app(of item: ScanItem) -> String? {
        if let bundle = item.action.paths.first(where: { $0.hasSuffix(".app") }) { return bundle }
        guard let bar = item.id.firstIndex(of: "|") else { return nil }
        let app = String(item.id[..<bar])
        return app.hasSuffix(".app") ? app : nil
    }

    /// Installs one update: verified download for developer updates, `brew upgrade` for Homebrew, the App Store
    /// page for App Store apps.
    public func install(_ update: AppUpdate) async -> ActionRecord {
        await install(update, item: UpdateCatalog.item(update))
    }

    func install(_ update: AppUpdate, item: ScanItem) async -> ActionRecord {
        func record(_ outcome: ActionRecord.Outcome) -> ActionRecord {
            ActionRecord(itemID: item.id, title: update.appName, detail: "\(update.installedVersion) → \(update.newVersion)",
                         bytes: 0, outcome: outcome)
        }
        switch update.source {
        case .appStore(let page):
            await openURL(page)
            return record(.done("Opened in the App Store"))
        case .homebrew(let token):
            guard let brew else { return record(.failed("Homebrew isn't installed")) }
            do {
                try SparkleInstaller.run(brew, ["upgrade", "--cask", token])
                return record(.done("Updated to \(update.newVersion)"))
            } catch {
                return record(.failed((error as? SparkleInstaller.Failure)?.message ?? "\(error)"))
            }
        case .sparkle(let download, _, _):
            guard await quitApp(update.appPath) else { return record(.skipped("Quit \(update.appName) first")) }
            do {
                try await SparkleInstaller.install(update, fetch: fetch, requireCodeSignature: requireCodeSignature, trash: trash)
                return record(.done("Updated to \(update.newVersion)"))
            } catch let failure as SparkleInstaller.Failure {
                // Couldn't verify or install: send the user to the download instead.
                if failure == .unsigned || failure == .unsupportedArchive("pkg") { await openURL(download) }
                return record(.failed(failure.message))
            } catch {
                return record(.failed(error.localizedDescription))
            }
        }
    }
}
