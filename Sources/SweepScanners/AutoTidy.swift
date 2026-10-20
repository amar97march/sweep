import CoreServices
import Foundation
import SweepCore

/// A rule that tidies one kind of everyday clutter. Whatever a rule picks goes to the Trash.
public struct TidyRule: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case oldInstallers, desktopScreenshots, oldDownloads
    }

    public var kind: Kind
    public var isEnabled: Bool
    /// Items untouched for at least this many days are tidied.
    public var days: Int
    /// When the rule was switched on. It first runs a day later, so the user can preview it.
    public var activeFrom: Date?

    public var id: Kind { kind }

    public init(kind: Kind, isEnabled: Bool, days: Int, activeFrom: Date? = nil) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.days = days
        self.activeFrom = activeFrom
    }

    /// Whether the rule may run at `now`: on, and switched on at least a day ago.
    public func isDue(at now: Date) -> Bool {
        isEnabled && (activeFrom ?? .distantPast).addingTimeInterval(86_400) <= now
    }

    /// Every rule, switched off.
    public static let defaults: [TidyRule] = [
        TidyRule(kind: .oldInstallers, isEnabled: false, days: 7),
        TidyRule(kind: .desktopScreenshots, isEnabled: false, days: 14),
        TidyRule(kind: .oldDownloads, isEnabled: false, days: 60),
    ]

    public static let dayChoices = [3, 7, 14, 30, 60, 90]

    public var title: String {
        switch kind {
        case .oldInstallers: "Installers in Downloads"
        case .desktopScreenshots: "Screenshots on the Desktop"
        case .oldDownloads: "Old files in Downloads"
        }
    }

    public var explanation: String {
        switch kind {
        case .oldInstallers: "Disk images and packages you already installed from."
        case .desktopScreenshots: "Screenshots and screen recordings, wherever macOS saves them."
        case .oldDownloads: "Anything in Downloads you haven't opened or changed for a while."
        }
    }

    public var symbol: String {
        switch kind {
        case .oldInstallers: "shippingbox.fill"
        case .desktopScreenshots: "camera.viewfinder"
        case .oldDownloads: "arrow.down.circle.fill"
        }
    }
}

/// Finds what each tidy rule would move to the Trash. Read-only; `CleanupPerformer` does the moving.
public struct AutoTidy: Sendable {
    /// When a file was last relevant to the user: added, opened or changed, whichever is latest.
    public typealias LastTouched = @Sendable (String) -> Date?

    public let environment: ScanEnvironment
    public let lastTouched: LastTouched
    /// Where screenshots are saved, if the user moved them off the Desktop.
    public let screenshotFolder: String?

    public init(environment: ScanEnvironment, lastTouched: @escaping LastTouched = AutoTidy.spotlightLastTouched,
                screenshotFolder: String? = AutoTidy.customScreenshotFolder()) {
        self.environment = environment
        self.lastTouched = lastTouched
        self.screenshotFolder = screenshotFolder
    }

    public func candidates(for rule: TidyRule) -> [ScanItem] {
        let cutoff = environment.now.addingTimeInterval(-Double(rule.days) * 86_400)
        let downloads = environment.user("Downloads")
        let entries: [String]
        switch rule.kind {
        case .oldInstallers:
            entries = Self.contents(downloads).filter { ["dmg", "pkg", "mpkg"].contains(($0 as NSString).pathExtension.lowercased()) }
        case .desktopScreenshots:
            let folders = [environment.user("Desktop"), screenshotFolder].compactMap { $0 }
            entries = Array(Set(folders)).sorted().flatMap(Self.contents).filter { Self.isScreenshot($0) || Self.isScreenCapture($0) }
        case .oldDownloads:
            entries = Self.contents(downloads).filter { !Self.isUnfinishedDownload($0) }
        }
        return entries.compactMap { path -> ScanItem? in
            guard let touched = lastTouched(path), touched < cutoff else { return nil }
            return ScanItem(id: path, title: (path as NSString).lastPathComponent, subtitle: path, size: Measure.size(path),
                            date: touched, isSelectedByDefault: true, action: .remove(paths: [path], mode: .moveToTrash))
        }
        .sorted { $0.size > $1.size }
    }

    /// Screenshots and screen recordings by the names macOS gives them in English ("Screenshot …",
    /// older "Screen Shot …", "Screen Recording …").
    static func isScreenshot(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let kinds = ["png", "jpg", "jpeg", "heic", "tiff", "pdf", "mov", "mp4"]
        guard kinds.contains((name as NSString).pathExtension.lowercased()) else { return false }
        return ["Screenshot ", "Screen Shot ", "Screen Recording "].contains { name.hasPrefix($0) }
    }

    /// Spotlight marks screenshots whatever language their name is in.
    static func isScreenCapture(_ path: String) -> Bool {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return false }
        return (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool) == true
    }

    static func isUnfinishedDownload(_ path: String) -> Bool {
        ["download", "crdownload", "part", "partial"].contains((path as NSString).pathExtension.lowercased())
    }

    static func contents(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") && $0 != "Icon\r" }
            .map { folder + "/" + $0 }
    }

    /// Latest of Spotlight's "date added" and "last opened", and the file's own modification date.
    public static let spotlightLastTouched: LastTouched = { path in
        var dates: [Date] = []
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString) {
            for key in [kMDItemDateAdded, kMDItemLastUsedDate] {
                if let date = MDItemCopyAttribute(item, key) as? Date { dates.append(date) }
            }
        }
        if let modified = Measure.modificationDate(path) { dates.append(modified) }
        return dates.max()
    }

    /// The folder set with `defaults write com.apple.screencapture location`, if any.
    public static func customScreenshotFolder() -> String? {
        guard let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
              !location.isEmpty else { return nil }
        return (location as NSString).expandingTildeInPath
    }
}
