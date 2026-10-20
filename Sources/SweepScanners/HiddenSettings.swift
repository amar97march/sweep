import Foundation
import SweepCore

/// A macOS preference that has no switch in System Settings, set with `defaults` like OnyX-style tools do. Every
/// one is a plain user preference: "Restore Default" deletes the key, putting macOS back exactly as it was.
public struct Tweak: Identifiable, Sendable, Equatable {
    public enum Value: Sendable, Equatable, Hashable {
        case bool(Bool), number(Double), text(String)

        var arguments: [String] {
            switch self {
            case .bool(let value): ["-bool", value ? "true" : "false"]
            case .number(let value): ["-float", String(value)]
            case .text(let value): ["-string", value]
            }
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case finder = "Finder", dock = "Dock", screenshots = "Screenshots", general = "Files and Disks"
    }

    public let id: String
    public let group: Group
    public let title: String
    public let detail: String
    public let domain: String
    public let key: String
    /// Choices; for a switch, the first is "on". A nil value means "the macOS default" (key deleted).
    public let choices: [(title: String, value: Value?)]
    /// Value macOS uses when the key isn't set.
    public let systemDefault: Value
    /// Process to relaunch for the change to show ("Finder", "Dock", "SystemUIServer").
    public let relaunch: String?

    public var isSwitch: Bool { choices.count == 2 && choices[0].title == "On" }

    public static func == (a: Tweak, b: Tweak) -> Bool { a.id == b.id }

    static func toggle(_ id: String, _ group: Group, _ title: String, _ detail: String, domain: String, key: String,
                       on: Value, off: Value? = nil, systemDefault: Value, relaunch: String?) -> Tweak {
        Tweak(id: id, group: group, title: title, detail: detail, domain: domain, key: key,
              choices: [("On", on), ("Off", off)], systemDefault: systemDefault, relaunch: relaunch)
    }

    public static let all: [Tweak] = [
        toggle("finderHidden", .finder, "Show hidden files", "Files whose names start with a dot, and system folders like ~/Library.",
               domain: "com.apple.finder", key: "AppleShowAllFiles", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("finderPathBar", .finder, "Show path bar", "Where the current folder is, at the bottom of every window.",
               domain: "com.apple.finder", key: "ShowPathbar", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("finderStatusBar", .finder, "Show status bar", "Item count and free space at the bottom of windows.",
               domain: "com.apple.finder", key: "ShowStatusBar", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("finderExtensions", .finder, "Show all filename extensions", "\"Report.pdf\" instead of \"Report\".",
               domain: "NSGlobalDomain", key: "AppleShowAllExtensions", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("finderFoldersFirst", .finder, "Keep folders on top", "Folders sort before files in lists and on the desktop.",
               domain: "com.apple.finder", key: "_FXSortFoldersFirst", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("finderPathTitle", .finder, "Full path in the window title", "/Users/you/Documents/Project instead of Project.",
               domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("finderSearchScope", .finder, "Search the current folder", "Search starts in the folder you're in instead of the whole Mac.",
               domain: "com.apple.finder", key: "FXDefaultSearchScope", on: .text("SCcf"), systemDefault: .text("SCev"), relaunch: "Finder"),
        toggle("finderExtensionWarning", .finder, "Skip the warning when changing an extension", "No confirmation when you rename .txt to .md.",
               domain: "com.apple.finder", key: "FXEnableExtensionChangeWarning", on: .bool(false), systemDefault: .bool(true), relaunch: "Finder"),
        toggle("dockNoDelay", .dock, "Show a hidden Dock instantly", "No half-second wait when you move to the edge of the screen.",
               domain: "com.apple.dock", key: "autohide-delay", on: .number(0), systemDefault: .number(0.5), relaunch: "Dock"),
        toggle("dockFastAnimation", .dock, "Faster Dock animation", "The hidden Dock slides in quickly.",
               domain: "com.apple.dock", key: "autohide-time-modifier", on: .number(0.15), systemDefault: .number(0.5), relaunch: "Dock"),
        toggle("dockOpenOnly", .dock, "Show only open apps", "The Dock lists running apps, not the ones you keep in it.",
               domain: "com.apple.dock", key: "static-only", on: .bool(true), systemDefault: .bool(false), relaunch: "Dock"),
        toggle("dockDimHidden", .dock, "Dim hidden apps", "Apps you hid with ⌘H look translucent in the Dock.",
               domain: "com.apple.dock", key: "showhidden", on: .bool(true), systemDefault: .bool(false), relaunch: "Dock"),
        Tweak(id: "screenshotFormat", group: .screenshots, title: "Screenshot format", detail: "HEIC and JPEG files are much smaller than PNG.",
              domain: "com.apple.screencapture", key: "type",
              choices: [("PNG", nil), ("JPEG", .text("jpg")), ("HEIC", .text("heic")), ("PDF", .text("pdf"))],
              systemDefault: .text("png"), relaunch: "SystemUIServer"),
        toggle("screenshotShadow", .screenshots, "Leave out window shadows", "Window screenshots without the large transparent shadow.",
               domain: "com.apple.screencapture", key: "disable-shadow", on: .bool(true), systemDefault: .bool(false), relaunch: "SystemUIServer"),
        toggle("screenshotDate", .screenshots, "Leave the date out of file names", "\"Screenshot 1.png\" instead of the date and time.",
               domain: "com.apple.screencapture", key: "include-date", on: .bool(false), systemDefault: .bool(true), relaunch: "SystemUIServer"),
        toggle("saveExpanded", .general, "Open save dialogs expanded", "Show the full folder browser every time you save.",
               domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", on: .bool(true), systemDefault: .bool(false), relaunch: nil),
        toggle("dsStoreNetwork", .general, "No .DS_Store files on network drives", "Finder stops leaving view settings files on shared folders.",
               domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("dsStoreUSB", .general, "No .DS_Store files on USB drives", "Keeps drives you share with other computers tidy.",
               domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", on: .bool(true), systemDefault: .bool(false), relaunch: "Finder"),
        toggle("timeMachineNewDisks", .general, "Don't offer new disks for Time Machine", "No \"Use this disk for backups?\" when you plug in a drive.",
               domain: "com.apple.TimeMachine", key: "DoNotOfferNewDisksForBackup", on: .bool(true), systemDefault: .bool(false), relaunch: nil),
    ]
}

/// Reads and writes tweaks through `defaults`, and relaunches the app that shows them.
public struct TweakStore: Sendable {
    public var run: PerformanceScanner.Run

    public init(run: @escaping PerformanceScanner.Run = Shell.quick) {
        self.run = run
    }

    /// The value set now, or nil when macOS uses its default.
    public func value(of tweak: Tweak) -> Tweak.Value? {
        let result = run("/usr/bin/defaults", ["read", tweak.domain, tweak.key])
        guard result.status == 0 else { return nil }
        return Self.parse(result.output.trimmingCharacters(in: .whitespacesAndNewlines), like: tweak.systemDefault)
    }

    static func parse(_ text: String, like example: Tweak.Value) -> Tweak.Value? {
        switch example {
        case .bool: ["1", "true", "yes"].contains(text.lowercased()) ? .bool(true) : ["0", "false", "no"].contains(text.lowercased()) ? .bool(false) : nil
        case .number: Double(text).map { .number($0) }
        case .text: .text(text)
        }
    }

    /// Which choice the current value matches (the default choice when the key isn't set).
    public func choice(of tweak: Tweak) -> Int {
        let current = value(of: tweak)
        if let index = tweak.choices.firstIndex(where: { $0.value != nil && $0.value == current }) { return index }
        if current == nil || current == tweak.systemDefault { return tweak.choices.firstIndex { $0.value == nil } ?? (tweak.choices.count - 1) }
        return tweak.choices.firstIndex { $0.value == nil } ?? 0
    }

    /// Sets a choice: writes its value, or deletes the key for "the macOS default". Returns false if `defaults` failed.
    @discardableResult
    public func set(_ tweak: Tweak, choice index: Int) -> Bool {
        guard tweak.choices.indices.contains(index) else { return false }
        if let value = tweak.choices[index].value {
            return run("/usr/bin/defaults", ["write", tweak.domain, tweak.key] + value.arguments).status == 0
        }
        let result = run("/usr/bin/defaults", ["delete", tweak.domain, tweak.key])
        return result.status == 0 || result.output.contains("does not exist")
    }

    public func restoreDefault(_ tweak: Tweak) {
        _ = run("/usr/bin/defaults", ["delete", tweak.domain, tweak.key])
    }

    /// Relaunches Finder, the Dock or the menu bar so the change shows. They reopen by themselves.
    public func relaunch(_ process: String) {
        guard ["Finder", "Dock", "SystemUIServer"].contains(process) else { return }
        _ = run("/usr/bin/killall", [process])
    }
}
