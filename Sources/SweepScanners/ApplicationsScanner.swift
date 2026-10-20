import CoreServices
import Foundation
import Security
import SweepCore

/// Finds installed apps with every file they spread around the system, files left behind by apps that are
/// already gone, unused apps, and leftover installers.
public struct ApplicationsScanner: Sendable {
    public let environment: ScanEnvironment
    /// Apps not opened for this long are "unused".
    public var unusedAge: TimeInterval = 180 * 86_400
    /// Our own bundle, never offered for removal.
    public var ownBundleID = "org.sweep.Sweep"

    public init(environment: ScanEnvironment) {
        self.environment = environment
    }

    public func scan(progress: (String) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [ScanCategory] {
        progress("Finding applications")
        let apps = AppCatalog.installed(in: environment).filter(isRemovable)
        progress("Looking for app files")
        let index = LibraryIndex(environment: environment)
        let identities = apps.map(AppIdentity.init)
        var categories: [ScanCategory] = []
        guard !isCancelled() else { return [] }

        progress("Measuring \(apps.count) apps")
        let resources = Self.assignShared(zip(apps, identities).map { app, identity in
            (identity, index.resources(of: identity, appPath: app.path))
        })
        let groups = zip(apps, resources).map { app, resources in appGroup(app, resources: resources) }
        if !groups.isEmpty {
            categories.append(ScanCategory(
                id: "uninstaller", title: "Uninstaller",
                summary: "Select an app to remove it with all its files, or select only its files to reset it.",
                symbol: "xmark.bin.fill", groups: groups.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }))
        }

        let cutoff = environment.now.addingTimeInterval(-unusedAge)
        let unused = zip(apps, groups).filter { app, _ in (app.lastUsed ?? .distantFuture) < cutoff }.map(\.1)
        if !unused.isEmpty {
            categories.append(ScanCategory(
                id: "unused", title: "Unused Apps", summary: "Apps you haven't opened in more than six months.",
                symbol: "moon.zzz.fill", groups: unused.map { ScanGroup(id: "unused:" + $0.id, title: $0.title,
                                                                         subtitle: $0.subtitle, icon: $0.icon, items: $0.items) }))
        }

        progress("Checking which apps need Rosetta")
        if let intel = intelOnlyApps(AppCatalog.installed(in: environment).filter { $0.bundleID != ownBundleID }) {
            categories.append(intel)
        }

        guard !isCancelled() else { return categories }
        progress("Looking for leftovers of removed apps")
        if let leftovers = orphanedLeftovers(index: index, identities: identities) { categories.append(leftovers) }
        progress("Looking for installers")
        if let installers = installers() { categories.append(installers) }
        return categories
    }

    // MARK: Uninstaller

    func isRemovable(_ app: InstalledApp) -> Bool {
        if app.bundleID == ownBundleID { return false }
        if app.bundleID.hasPrefix("com.apple.") && !app.isAppStore { return false }  // Safari, Xcode-installed tools…
        return true
    }

    func appGroup(_ app: InstalledApp, resources: [Leftover]) -> ScanGroup {
        let bundleItem = ScanItem(id: app.path, title: "\(app.name).app", subtitle: app.path,
                                  size: Measure.size(app.path), date: app.lastUsed, isSelectedByDefault: false,
                                  action: .remove(paths: [app.path], mode: .moveToTrash))
        let resourceItems = resources.map { leftover in
            ScanItem(id: app.path + "|" + leftover.path, title: leftover.kind.title,
                     subtitle: leftover.path, size: Measure.size(leftover.path), date: nil, isSelectedByDefault: false,
                     action: leftover.action)
        }
        var subtitle = app.shortVersion.map { "Version \($0)" } ?? ""
        if let used = app.lastUsed {
            subtitle += (subtitle.isEmpty ? "" : " · ") + "Last opened " + used.formatted(date: .abbreviated, time: .omitted)
        }
        if app.isAppStore { subtitle += " · App Store" }
        return ScanGroup(id: "app:" + app.path, title: app.name, subtitle: subtitle, icon: .file(app.path),
                         items: [bundleItem] + resourceItems)
    }

    /// A file two installed apps both match goes to the one it names most specifically (Chrome Canary's
    /// caches belong to Canary, not Chrome). If no app matches better, it's shared (like Office's group
    /// container used by Word, Excel and Outlook) and left out of every app's files.
    static func assignShared(_ claims: [(identity: AppIdentity, resources: [Leftover])]) -> [[Leftover]] {
        var claimants: [String: [(app: Int, strength: Int)]] = [:]
        for (index, claim) in claims.enumerated() {
            for leftover in claim.resources {
                let name = (leftover.path as NSString).lastPathComponent
                claimants[leftover.path, default: []].append((index, claim.identity.matchStrength(name)))
            }
        }
        return claims.enumerated().map { index, claim in
            claim.resources.filter { leftover in
                guard let rivals = claimants[leftover.path], rivals.count > 1 else { return true }
                let best = rivals.map(\.strength).max() ?? 0
                return rivals.filter { $0.strength == best }.map(\.app) == [index]
            }
        }
    }

    // MARK: Orphaned leftovers

    func orphanedLeftovers(index: LibraryIndex, identities: [AppIdentity]) -> ScanCategory? {
        let ownedIDs = Set(identities.flatMap(\.bundleIDs))
        let vendors = Set(ownedIDs.compactMap(AppIdentity.vendor))
        let runningVendors = Set(environment.runningBundleIDs.map { $0.lowercased() }.compactMap(AppIdentity.vendor))
        var byOwner: [String: [ScanItem]] = [:]
        for entry in index.entries where entry.location.orphanCandidate {
            guard let owner = AppIdentity.bundleIDLike(entry.name, kind: entry.location.kind) else { continue }
            if owner.hasPrefix("com.apple.") || Exclusions.systemBundlePrefixes.contains(where: owner.hasPrefix) { continue }
            if ownedIDs.contains(where: { owner == $0 || owner.hasPrefix($0 + ".") }) { continue }
            if let vendor = AppIdentity.vendor(owner), vendors.contains(vendor) || runningVendors.contains(vendor) { continue }
            let safe = entry.location.kind.isSafeToPreselect
            byOwner[owner, default: []].append(ScanItem(
                id: "orphan:" + entry.path, title: entry.location.kind.title, subtitle: entry.path,
                size: Measure.size(entry.path), isSelectedByDefault: safe,
                action: .remove(paths: [entry.path], mode: .moveToTrash)))
        }
        let groups = byOwner.keys.sorted().map { owner in
            ScanGroup(id: "orphan:" + owner, title: owner, subtitle: "App no longer installed", icon: .symbol("questionmark.app.fill"),
                      items: byOwner[owner]!)
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "leftovers", title: "Leftovers",
                            summary: "Files left by apps that were deleted without an uninstaller.",
                            symbol: "puzzlepiece.extension.fill", groups: groups.sorted { $0.size > $1.size })
    }

    // MARK: Installers

    func installers() -> ScanCategory? {
        var paths = Set<String>()
        for folder in ["Downloads", "Desktop", "Documents"].map(environment.user) {
            paths.formUnion(Self.findInstallers(under: folder, depth: 3))
        }
        if environment.systemRoot.isEmpty { paths.formUnion(Spotlight.installers(in: environment.home)) }
        let items = paths.sorted().map { path in
            ScanItem(id: "installer:" + path, title: (path as NSString).lastPathComponent, subtitle: path,
                     size: Measure.size(path), date: Measure.modificationDate(path), isSelectedByDefault: false,
                     action: .remove(paths: [path], mode: .moveToTrash))
        }
        guard !items.isEmpty else { return nil }
        return ScanCategory(id: "installers", title: "Installers",
                            summary: "Disk images and packages you may not need now that the apps are installed.",
                            symbol: "shippingbox.and.arrow.backward.fill",
                            groups: [ScanGroup(id: "installers", title: "Installation files", icon: .symbol("opticaldiscdrive.fill"),
                                               items: items.sorted { $0.size > $1.size })])
    }

    static func findInstallers(under folder: String, depth: Int) -> [String] {
        guard depth >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var found: [String] = []
        for name in names where !name.hasPrefix(".") {
            let path = folder + "/" + name
            let ext = (name as NSString).pathExtension.lowercased()
            if ["dmg", "pkg", "mpkg"].contains(ext) {
                found.append(path)
            } else if ext.isEmpty, AppCatalog.isDirectory(path) {
                found += findInstallers(under: path, depth: depth - 1)
            }
        }
        return found
    }
}

/// Everything that identifies an app's files: its bundle IDs (app, helpers, extensions), name words,
/// app groups and privileged helper labels.
public struct AppIdentity: Sendable {
    public let path: String
    public let name: String
    public let bundleIDs: [String]
    public let nameWords: [String]
    public let groups: Set<String>
    public let helperLabels: Set<String>

    public init(_ app: InstalledApp) {
        path = app.path
        name = app.name
        var ids = [app.bundleID.lowercased()]
        ids += Self.embeddedBundleIDs(in: app.path).map { $0.lowercased() }
        bundleIDs = Array(Set(ids)).sorted()
        nameWords = Self.words(app.name)
        groups = Set(Self.applicationGroups(app.path).map { $0.lowercased() })
        let plist = NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist")
        helperLabels = Set(((plist?["SMPrivilegedExecutables"] as? [String: Any])?.keys).map { Array($0) } ?? [])
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Helper apps, extensions and XPC services shipped inside the bundle.
    static func embeddedBundleIDs(in path: String) -> [String] {
        let places = ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/XPCServices",
                      "Contents/Library/LaunchServices", "Contents/Helpers", "Contents/Library/SystemExtensions"]
        var ids: [String] = []
        for place in places {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path + "/" + place)) ?? [] {
                let info = NSDictionary(contentsOfFile: path + "/" + place + "/" + name + "/Contents/Info.plist")
                if let id = info?["CFBundleIdentifier"] as? String { ids.append(id) }
            }
        }
        return ids
    }

    /// `com.apple.security.application-groups` from the app's code signature.
    static func applicationGroups(_ path: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// "com.vendor.app" → "com.vendor"
    static func vendor(_ bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        return parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : nil
    }

    /// The reverse-DNS identifier an entry is named after, or nil if it isn't named that way.
    static func bundleIDLike(_ name: String, kind: Leftover.Kind) -> String? {
        var base = name.lowercased()
        for suffix in [".plist", ".savedstate", ".binarycookies"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if kind == .preferences {
            // ByHost files: <id>.<hardware UUID>
            base = base.replacingOccurrences(of: #"\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                                             with: "", options: .regularExpression)
        }
        guard base.range(of: #"^[a-z][a-z0-9-]*(\.[a-z0-9_-]+){2,}$"#, options: .regularExpression) != nil else { return nil }
        return base
    }

    /// Whether a Library entry belongs to this app.
    func owns(_ name: String, kind: Leftover.Kind, path entryPath: String) -> Bool {
        let lower = name.lowercased()
        var base = lower
        for suffix in [".plist", ".savedstate", ".binarycookies", ".bom"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        let byID = bundleIDs.contains { base == $0 || base.hasPrefix($0 + ".") }

        switch kind {
        case .groupContainers:
            return groups.contains(lower) || bundleIDs.contains { lower.hasSuffix("." + $0) && lower.count - $0.count <= 11 }
        case .helperTools:
            return helperLabels.map { $0.lowercased() }.contains(lower) || byID
        case .launchAgents, .launchDaemons:
            if byID { return true }
            if let program = LaunchItem.program(ofPlistAt: entryPath, home: NSHomeDirectory()) {
                return program.hasPrefix(path + "/")
            }
            return false
        case .applicationSupport, .caches, .logs, .plugins:
            return byID || matchesName(name)
        default:
            return byID
        }
    }

    /// How specifically a Library entry names this app: the length of the longest bundle identifier it is
    /// named after, or 0 when it only matched by app group, name or helper.
    func matchStrength(_ name: String) -> Int {
        var base = name.lowercased()
        for suffix in [".plist", ".savedstate", ".binarycookies", ".bom"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return bundleIDs.filter { base == $0 || base.hasPrefix($0 + ".") }.map(\.count).max() ?? 0
    }

    /// Every word of the app's name appears in `candidate` — but "AppName 2024" belongs to another edition.
    func matchesName(_ candidate: String) -> Bool {
        guard !nameWords.isEmpty else { return false }
        let lower = candidate.lowercased()
        let appName = name.lowercased()
        if lower.hasPrefix(appName), lower.dropFirst(appName.count).range(of: #"^\s*\d+"#, options: .regularExpression) != nil {
            return false
        }
        let candidateWords = Set(Self.words(candidate))
        // One-word names must match exactly, otherwise "Notes" would claim every folder with "notes" in it.
        if nameWords.count == 1 { return lower == appName || candidateWords == [nameWords[0]] }
        return nameWords.allSatisfy(candidateWords.contains)
    }
}

/// A file or folder that belongs to an app.
public struct Leftover: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case applicationSupport, caches, preferences, containers, groupContainers, savedState, logs, cookies,
             webKit, httpStorages, launchAgents, launchDaemons, helperTools, plugins, scripts, receipts

        var title: String {
            switch self {
            case .applicationSupport: "Application Support"
            case .caches: "Caches"
            case .preferences: "Preferences"
            case .containers: "Container"
            case .groupContainers: "Group Container"
            case .savedState: "Saved State"
            case .logs: "Logs"
            case .cookies: "Cookies"
            case .webKit: "WebKit Data"
            case .httpStorages: "HTTP Storage"
            case .launchAgents: "Launch Agent"
            case .launchDaemons: "Launch Daemon"
            case .helperTools: "Privileged Helper"
            case .plugins: "Plug-in"
            case .scripts: "Application Scripts"
            case .receipts: "Installer Receipt"
            }
        }

        /// Kinds that only hold rebuildable data, safe to preselect for orphans.
        var isSafeToPreselect: Bool { [.caches, .savedState, .httpStorages, .webKit, .cookies, .logs].contains(self) }
    }

    public let kind: Kind
    public let path: String
    public var action: ItemAction {
        if kind == .receipts {
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return .custom(kind: "forgetReceipt", payload: [id])
        }
        return .remove(paths: [path], mode: .moveToTrash)
    }
}

/// One listing of every Library folder apps write to, shared by all apps (each folder is read once).
public struct LibraryIndex: Sendable {
    public struct Location: Sendable, Hashable {
        let path: String
        let kind: Leftover.Kind
        /// Whether entries here are considered for "leftovers of removed apps".
        let orphanCandidate: Bool
    }

    public struct Entry: Sendable, Hashable {
        let location: Location
        let name: String
        let path: String
    }

    let entries: [Entry]

    init(environment: ScanEnvironment) {
        let user = environment.user
        let system = environment.system
        var locations: [Location] = [
            .init(path: user("Library/Application Support"), kind: .applicationSupport, orphanCandidate: true),
            .init(path: user("Library/Caches"), kind: .caches, orphanCandidate: true),
            .init(path: user("Library/Preferences"), kind: .preferences, orphanCandidate: true),
            .init(path: user("Library/Preferences/ByHost"), kind: .preferences, orphanCandidate: true),
            .init(path: user("Library/Containers"), kind: .containers, orphanCandidate: true),
            .init(path: user("Library/Group Containers"), kind: .groupContainers, orphanCandidate: false),
            .init(path: user("Library/Saved Application State"), kind: .savedState, orphanCandidate: true),
            .init(path: user("Library/Logs"), kind: .logs, orphanCandidate: true),
            .init(path: user("Library/Cookies"), kind: .cookies, orphanCandidate: true),
            .init(path: user("Library/WebKit"), kind: .webKit, orphanCandidate: true),
            .init(path: user("Library/HTTPStorages"), kind: .httpStorages, orphanCandidate: true),
            .init(path: user("Library/LaunchAgents"), kind: .launchAgents, orphanCandidate: false),
            .init(path: user("Library/Application Scripts"), kind: .scripts, orphanCandidate: true),
            .init(path: user("Library/Internet Plug-Ins"), kind: .plugins, orphanCandidate: false),
            .init(path: user("Library/PreferencePanes"), kind: .plugins, orphanCandidate: false),
            .init(path: system("/Library/Application Support"), kind: .applicationSupport, orphanCandidate: false),
            .init(path: system("/Library/Caches"), kind: .caches, orphanCandidate: false),
            .init(path: system("/Library/Preferences"), kind: .preferences, orphanCandidate: false),
            .init(path: system("/Library/LaunchAgents"), kind: .launchAgents, orphanCandidate: false),
            .init(path: system("/Library/LaunchDaemons"), kind: .launchDaemons, orphanCandidate: false),
            .init(path: system("/Library/PrivilegedHelperTools"), kind: .helperTools, orphanCandidate: false),
            .init(path: system("/Library/Logs"), kind: .logs, orphanCandidate: false),
            .init(path: system("/Library/Internet Plug-Ins"), kind: .plugins, orphanCandidate: false),
            .init(path: system("/Library/PreferencePanes"), kind: .plugins, orphanCandidate: false),
            .init(path: system("/private/var/db/receipts"), kind: .receipts, orphanCandidate: false),
        ]
        for audio in ["Components", "VST", "VST3", "MAS", "HAL"] {
            locations.append(.init(path: system("/Library/Audio/Plug-Ins/" + audio), kind: .plugins, orphanCandidate: false))
            locations.append(.init(path: user("Library/Audio/Plug-Ins/" + audio), kind: .plugins, orphanCandidate: false))
        }
        var entries: [Entry] = []
        for location in locations {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: location.path)) ?? [] where !name.hasPrefix(".") {
                // Receipts come as .plist + .bom pairs; list each package once.
                if location.kind == .receipts && !name.hasSuffix(".plist") { continue }
                entries.append(Entry(location: location, name: name, path: location.path + "/" + name))
            }
        }
        self.entries = entries
    }

    /// Files that belong to `identity`. The app bundle itself is not included.
    func resources(of identity: AppIdentity, appPath: String) -> [Leftover] {
        entries.filter { identity.owns($0.name, kind: $0.location.kind, path: $0.path) }
            .map { Leftover(kind: $0.location.kind, path: $0.path) }
            .sorted { $0.path < $1.path }
    }
}

enum Spotlight {
    /// Disk images and installer packages Spotlight knows about in `folder`.
    static func installers(in folder: String) -> [String] {
        let query = "kMDItemContentTypeTree == 'com.apple.disk-image' || kMDItemContentTypeTree == 'com.apple.installer-package-archive'"
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(mdQuery, [folder] as CFArray, 0)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for index in 0..<MDQueryGetResultCount(mdQuery) {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !path.contains("/Library/") {
                paths.append(path)
            }
        }
        return paths
    }
}

extension Exclusions {
    /// Identifiers of system components that aren't apps but keep preferences in the user Library.
    static let systemBundlePrefixes: [String] = [
        "com.apple", "org.cups", "com.openssh", "org.openssh", "com.microsoft.autoupdate", "org.python",
        "com.oracle.java", "net.java", "org.mozilla.updater",
    ]
}
