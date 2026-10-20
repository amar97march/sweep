import CryptoKit
import Foundation
import Security
import SweepCore

/// An available update for an installed app.
public struct AppUpdate: Sendable, Codable, Hashable {
    public enum Source: Sendable, Codable, Hashable {
        /// Direct download from the app's Sparkle feed.
        case sparkle(download: URL, edSignature: String?, length: Int64?)
        /// Mac App Store listing.
        case appStore(page: URL)
        /// A Homebrew cask (`brew upgrade --cask <token>`).
        case homebrew(token: String)
    }

    public let appPath: String
    public let appName: String
    public let bundleID: String
    public let installedVersion: String
    public let newVersion: String
    public let source: Source
    public let releaseNotes: String?
    /// A page with the release notes, when the feed links to one instead of including them.
    public var releaseNotesURL: URL? = nil

    public init(appPath: String, appName: String, bundleID: String, installedVersion: String, newVersion: String,
                source: Source, releaseNotes: String?, releaseNotesURL: URL? = nil) {
        self.appPath = appPath
        self.appName = appName
        self.bundleID = bundleID
        self.installedVersion = installedVersion
        self.newVersion = newVersion
        self.source = source
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
    }

    public var sourceName: String {
        switch source {
        case .sparkle: "Developer"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        }
    }
}

/// Apps and versions the user chose not to be told about.
public struct UpdateIgnoreList: Codable, Sendable, Equatable {
    /// Bundle IDs never offered.
    public var apps: Set<String> = []
    /// Bundle ID → the one version skipped; a newer version is offered again.
    public var skippedVersions: [String: String] = [:]

    public init(apps: Set<String> = [], skippedVersions: [String: String] = [:]) {
        self.apps = apps
        self.skippedVersions = skippedVersions
    }

    public func hides(_ update: AppUpdate) -> Bool {
        apps.contains(update.bundleID) || skippedVersions[update.bundleID] == update.newVersion
    }

    public func filter(_ updates: [AppUpdate]) -> [AppUpdate] { updates.filter { !hides($0) } }
}

/// Looks for updates in Sparkle appcasts, the App Store and Homebrew.
public struct UpdateChecker: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public let fetch: Fetch
    public let systemVersion: OperatingSystemVersion
    public let region: String
    /// `brew` executable, if Homebrew is installed.
    public let brew: String?

    public init(fetch: @escaping Fetch = UpdateChecker.download,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                region: String = Locale.current.region?.identifier ?? "US",
                brew: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile)) {
        self.fetch = fetch
        self.systemVersion = systemVersion
        self.region = region
        self.brew = brew
    }

    public static let download: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Sweep/1.0 (macOS update check)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Checks every app concurrently (8 at a time). Apps that can't be checked are skipped.
    public func check(_ apps: [InstalledApp]) async -> [AppUpdate] {
        var updates: [AppUpdate] = []
        await withTaskGroup(of: AppUpdate?.self) { group in
            var pending = apps[...]
            func addNext() {
                guard let app = pending.popFirst() else { return }
                group.addTask { await self.check(app) }
            }
            for _ in 0..<8 { addNext() }
            while let result = await group.next() {
                if let result { updates.append(result) }
                addNext()
            }
        }
        if let brew { updates += await homebrewUpdates(brew: brew, apps: apps) }
        return Self.oneEach(updates).sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    /// One update per app. An app installed with Homebrew is updated through Homebrew, so its records stay right.
    static func oneEach(_ updates: [AppUpdate]) -> [AppUpdate] {
        var chosen: [String: AppUpdate] = [:]
        for update in updates {
            let key = update.appPath.isEmpty ? update.bundleID : update.appPath
            if let existing = chosen[key], case .homebrew = existing.source { continue }
            chosen[key] = update
        }
        return Array(chosen.values)
    }

    func check(_ app: InstalledApp) async -> AppUpdate? {
        if app.isAppStore { return await appStoreUpdate(app) }
        if let feed = app.info["SUFeedURL"], let url = URL(string: feed) { return await sparkleUpdate(app, feed: url) }
        return nil
    }

    // MARK: Sparkle

    func sparkleUpdate(_ app: InstalledApp, feed: URL) async -> AppUpdate? {
        guard let data = try? await fetch(feed) else { return nil }
        let items = Appcast.parse(data)
        guard let best = Appcast.best(items, systemVersion: systemVersion) else { return nil }
        // Build numbers (sparkle:version ↔ CFBundleVersion) when the feed has them, display versions otherwise.
        let (candidate, installed): (String, String)
        if let build = best.version, let current = app.version {
            (candidate, installed) = (build, current)
        } else {
            (candidate, installed) = (best.shortVersion ?? best.version ?? "0", app.shortVersion ?? app.version ?? "0")
        }
        guard Version.compare(candidate, installed) == .orderedDescending else { return nil }
        return AppUpdate(appPath: app.path, appName: app.name, bundleID: app.bundleID,
                         installedVersion: app.shortVersion ?? installed,
                         newVersion: best.shortVersion ?? candidate,
                         source: .sparkle(download: best.url, edSignature: best.edSignature, length: best.length),
                         releaseNotes: best.notes, releaseNotesURL: best.notesLink)
    }

    // MARK: App Store

    func appStoreUpdate(_ app: InstalledApp) async -> AppUpdate? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "bundleId", value: app.bundleID),
                                 URLQueryItem(name: "country", value: region.lowercased()),
                                 URLQueryItem(name: "entity", value: "desktopSoftware")]
        guard let url = components.url, let data = try? await fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let version = result["version"] as? String,
              let page = (result["trackViewUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        if let minimum = result["minimumOsVersion"] as? String,
           Version.compare(minimum, Version.string(systemVersion)) == .orderedDescending { return nil }
        guard let installed = app.shortVersion, Version.compare(version, installed) == .orderedDescending else { return nil }
        return AppUpdate(appPath: app.path, appName: app.name, bundleID: app.bundleID, installedVersion: installed,
                         newVersion: version, source: .appStore(page: page), releaseNotes: result["releaseNotes"] as? String)
    }

    // MARK: Homebrew

    func homebrewUpdates(brew: String, apps: [InstalledApp]) async -> [AppUpdate] {
        guard let output = Self.run(brew, ["outdated", "--cask", "--greedy", "--json=v2"]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        let tokens = casks.compactMap { $0["name"] as? String }
        let bundles = tokens.isEmpty ? [:] : Self.appBundles(inInfo: Self.run(brew, ["info", "--json=v2", "--cask"] + tokens) ?? "")
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String, let current = cask["current_version"] as? String else { return nil }
            let installed = (cask["installed_versions"] as? [String])?.first ?? "?"
            let app = apps.first { app in bundles[token]?.contains((app.path as NSString).lastPathComponent) ?? false }
                ?? apps.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == token }
            return AppUpdate(appPath: app?.path ?? "", appName: app?.name ?? token, bundleID: app?.bundleID ?? token,
                             installedVersion: installed, newVersion: current, source: .homebrew(token: token),
                             releaseNotes: nil)
        }
    }

    /// Cask token → the app bundles it installs, from `brew info --json=v2 --cask`.
    static func appBundles(inInfo output: String) -> [String: Set<String>] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [:] }
        var bundles: [String: Set<String>] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                for entry in artifact["app"] as? [Any] ?? [] {
                    if let name = entry as? String { bundles[token, default: []].insert((name as NSString).lastPathComponent) }
                    if let target = (entry as? [String: Any])?["target"] as? String {
                        bundles[token, default: []].insert((target as NSString).lastPathComponent)
                    }
                }
            }
        }
        return bundles
    }

    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Sparkle appcast (RSS with sparkle: extensions).
public enum Appcast {
    public struct Item: Sendable, Equatable {
        public var version: String?
        public var shortVersion: String?
        public var minimumSystemVersion: String?
        public var channel: String?
        public var url: URL
        public var edSignature: String?
        public var length: Int64?
        public var notes: String?
        public var notesLink: URL? = nil
    }

    public static func parse(_ data: Data) -> [Item] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// The newest stable item this macOS can run.
    public static func best(_ items: [Item], systemVersion: OperatingSystemVersion) -> Item? {
        let current = Version.string(systemVersion)
        return items
            .filter { $0.channel == nil }
            .filter { item in item.minimumSystemVersion.map { Version.compare($0, current) != .orderedDescending } ?? true }
            .max { Version.compare($0.version ?? $0.shortVersion ?? "0", $1.version ?? $1.shortVersion ?? "0") == .orderedAscending }
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    var items: [Appcast.Item] = []
    private var current: [String: String]?
    private var enclosure: [String: String] = [:]
    private var text = ""
    /// Inside <sparkle:deltas>: those enclosures are patches against one old version, not the full update.
    private var inDeltas = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = [:]; enclosure = [:] }
        if name == "sparkle:deltas" { inDeltas = true }
        if name == "enclosure", current != nil, !inDeltas { enclosure = attributes }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "sparkle:deltas" { inDeltas = false; return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "item", let item = current {
            if let link = enclosure["url"], let url = URL(string: link) {
                items.append(Appcast.Item(
                    version: enclosure["sparkle:version"] ?? item["sparkle:version"],
                    shortVersion: enclosure["sparkle:shortVersionString"] ?? item["sparkle:shortVersionString"],
                    minimumSystemVersion: item["sparkle:minimumSystemVersion"],
                    channel: item["sparkle:channel"],
                    url: url,
                    edSignature: enclosure["sparkle:edSignature"],
                    length: enclosure["length"].flatMap { Int64($0) },
                    notes: item["description"],
                    notesLink: (item["sparkle:fullReleaseNotesLink"] ?? item["sparkle:releaseNotesLink"]).flatMap(URL.init(string:))
                        .flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }))
            }
            current = nil
        } else if current != nil, !value.isEmpty {
            current?[name] = value
        }
        text = ""
    }
}

/// Version comparison the way Sparkle does it: numeric runs compare as numbers.
public enum Version {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = parts(a), right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : .number(0)
            let r = index < right.count ? right[index] : .number(0)
            switch (l, r) {
            case (.number(let x), .number(let y)) where x != y: return x < y ? .orderedAscending : .orderedDescending
            case (.text(let x), .text(let y)) where x != y: return x < y ? .orderedAscending : .orderedDescending
            // A pre-release tag ("1.0b1") sorts below the plain number ("1.0").
            case (.text, .number): return .orderedAscending
            case (.number, .text): return .orderedDescending
            default: continue
            }
        }
        return .orderedSame
    }

    public static func string(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private enum Part { case number(Int), text(String) }

    private static func parts(_ value: String) -> [Part] {
        var parts: [Part] = []
        var digits = "", letters = ""
        func flush() {
            if !digits.isEmpty { parts.append(.number(Int(digits) ?? 0)); digits = "" }
            if !letters.isEmpty { parts.append(.text(letters.lowercased())); letters = "" }
        }
        for character in value {
            if character.isNumber {
                if !letters.isEmpty { flush() }
                digits.append(character)
            } else if character.isLetter {
                if !digits.isEmpty { flush() }
                letters.append(character)
            } else {
                flush()
            }
        }
        flush()
        return parts
    }
}

/// Downloads, verifies and installs a Sparkle update in place of the installed app.
public enum SparkleInstaller {
    public enum Failure: Error, Equatable, Sendable {
        case unsigned, badSignature, unsupportedArchive(String), noApp, wrongApp, invalidCodeSignature, failed(String)

        public var message: String {
            switch self {
            case .unsigned: "The update isn't signed, so it can't be verified"
            case .badSignature: "The update's signature doesn't match the app's key"
            case .unsupportedArchive(let kind): "Can't install \(kind) files automatically"
            case .noApp: "No app found in the download"
            case .wrongApp: "The download contains a different app"
            case .invalidCodeSignature: "The new app's code signature isn't valid"
            case .failed(let reason): reason
            }
        }
    }

    /// Checks the EdDSA signature of `data` against the app's `SUPublicEDKey`.
    public static func verify(_ data: Data, signature: String?, publicKey: String?) throws {
        guard let publicKey, let keyData = Data(base64Encoded: publicKey),
              let signature, let signatureData = Data(base64Encoded: signature) else { throw Failure.unsigned }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: data) else { throw Failure.badSignature }
    }

    /// Installs the update: the caller must have quit the app. The old copy goes to the Trash.
    public static func install(
        _ update: AppUpdate, fetch: UpdateChecker.Fetch = UpdateChecker.download, requireCodeSignature: Bool = true,
        trash: FileRemover.Trash = FileRemover.systemTrash,
        move: @Sendable (String, String) throws -> Void = { try FileManager.default.moveItem(atPath: $0, toPath: $1) }
    ) async throws {
        guard case .sparkle(let url, let signature, _) = update.source else { throw Failure.failed("Not a Sparkle update") }
        let info = NSDictionary(contentsOfFile: update.appPath + "/Contents/Info.plist")
        let data = try await fetch(url)
        try verify(data, signature: signature, publicKey: info?["SUPublicEDKey"] as? String)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent(url.lastPathComponent.isEmpty ? "update" : url.lastPathComponent)
        try data.write(to: archive)
        let extracted = work.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try unpack(archive, into: extracted)

        guard let newApp = findApp(in: extracted.path) else { throw Failure.noApp }
        guard InstalledApp(path: newApp)?.bundleID == update.bundleID else { throw Failure.wrongApp }
        if requireCodeSignature {
            guard let newTeam = teamID(newApp), newTeam == teamID(update.appPath) else { throw Failure.invalidCodeSignature }
        }
        // Stage the new version next to the old one first (same volume, so the last step is a rename), put the
        // old version in the Trash, then rename the new one into place. If that fails, the old one comes back:
        // the app is never left missing.
        let folder = (update.appPath as NSString).deletingLastPathComponent
        let staged = folder + "/.sweep-update-\(UUID().uuidString).app"
        try move(newApp, staged)
        let old: URL?
        do {
            old = try trash(URL(fileURLWithPath: update.appPath))
        } catch {
            try? FileManager.default.removeItem(atPath: staged)
            throw error
        }
        do {
            try move(staged, update.appPath)
        } catch {
            if let old, !FileManager.default.fileExists(atPath: update.appPath) { try? move(old.path, update.appPath) }
            try? FileManager.default.removeItem(atPath: staged)
            throw error
        }
    }

    static func unpack(_ archive: URL, into folder: URL) throws {
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.bz2") {
            try run("/usr/bin/tar", ["-xf", archive.path, "-C", folder.path])
        } else if name.hasSuffix(".dmg") {
            let mount = folder.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, archive.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            guard let app = findApp(in: mount.path) else { throw Failure.noApp }
            try run("/usr/bin/ditto", [app, folder.appendingPathComponent((app as NSString).lastPathComponent).path])
        } else {
            throw Failure.unsupportedArchive((name as NSString).pathExtension)
        }
    }

    static func findApp(in folder: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        if let app = names.first(where: { $0.hasSuffix(".app") }) { return folder + "/" + app }
        for name in names where !name.hasPrefix(".") && AppCatalog.isDirectory(folder + "/" + name) {
            if let app = findApp(in: folder + "/" + name) { return app }
        }
        return nil
    }

    /// Team identifier of a validly signed bundle, or nil.
    static func teamID(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    @discardableResult
    /// Runs an install step (unpacking, mounting, `brew upgrade`). Half an hour is far longer than any of
    /// them takes; past that something is stuck, and the update is reported as failed instead of hanging.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 1_800) throws -> String {
        let result = try Subprocess.run(executable, arguments, timeout: timeout)
        if result.timedOut { throw Failure.failed("\((executable as NSString).lastPathComponent) didn't finish") }
        guard result.status == 0 else { throw Failure.failed(result.errors.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.output
    }
}

/// Release notes from feeds, which are usually HTML, as plain text with paragraphs and bullet points.
public enum ReleaseNotes {
    public static func plainText(_ notes: String) -> String {
        var text = notes
        guard text.contains("<") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Drop what is never content.
        for tag in ["script", "style", "head"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!\\[CDATA\\[|\\]\\]>", with: "", options: .regularExpression)
        let breaks: [(String, String)] = [("<li[^>]*>", "\n• "), ("<br\\s*/?>", "\n"), ("</(p|div|h[1-6]|ul|ol|tr)>", "\n"),
                                          ("<(p|div|h[1-6]|ul|ol|tr)[^>]*>", "\n")]
        for (pattern, replacement) in breaks {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // "&amp;" last, so "&amp;lt;" becomes "&lt;" as written rather than "<".
        let entities = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&ndash;", "–"),
                        ("&mdash;", "—"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”")]
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        text = decodingNumericEntities(text).replacingOccurrences(of: "&amp;", with: "&")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "&#8217;" and "&#x2019;" → "’".
    static func decodingNumericEntities(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let digits = Range(match.range(at: 2), in: text) else { continue }
            let isHex = match.range(at: 1).length > 0
            guard let value = UInt32(text[digits], radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) else { continue }
            result.replaceSubrange(Range(match.range, in: result) ?? whole, with: String(Character(scalar)))
        }
        return result
    }
}
