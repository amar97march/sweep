import Foundation
import Security
import SweepCore

/// A background item as Sweep remembers it, to notice when one appears or goes away.
public struct WatchedItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case loginItem, app, agent, daemon

        public var title: String {
            switch self {
            case .loginItem: "Login item"
            case .app: "App helper"
            case .agent: "Launch agent"
            case .daemon: "Launch daemon"
            }
        }
    }

    public let id: String
    public var name: String
    public var developer: String?
    public var kind: Kind
    public var enabled: Bool
    public var plist: String?
    public var executable: String?
    public var label: String?
    public var bundlePath: String?
    /// When Sweep first saw it (for items there before Sweep started watching: when its plist was created).
    public var firstSeen: Date

    public init(id: String, name: String, developer: String?, kind: Kind, enabled: Bool, plist: String?, executable: String?,
                label: String?, bundlePath: String?, firstSeen: Date) {
        self.id = id
        self.name = name
        self.developer = developer
        self.kind = kind
        self.enabled = enabled
        self.plist = plist
        self.executable = executable
        self.label = label
        self.bundlePath = bundlePath
        self.firstSeen = firstSeen
    }

    /// The file whose signature says who made it: the app for login items, else the program launchd runs.
    public var signedPath: String? { bundlePath ?? executable }
    /// System-wide items need the administrator password to turn off.
    public var isSystemWide: Bool { kind == .daemon }
    /// Login items and app-registered helpers are switched in System Settings; launchd items Sweep can switch itself.
    public var isSwitchable: Bool { (kind == .agent || kind == .daemon) && label != nil }
}

/// One appearance or disappearance, for the change history.
public struct BackgroundChange: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case added, removed }
    public var id = UUID()
    public let kind: Kind
    public let item: WatchedItem
    public let date: Date

    public init(kind: Kind, item: WatchedItem, date: Date) {
        self.kind = kind
        self.item = item
        self.date = date
    }
}

public enum BackgroundWatch {
    public static func identity(_ item: BackgroundItem) -> String {
        [kind(item.type)?.rawValue ?? "other", item.identifier, item.plist ?? item.bundlePath ?? ""].joined(separator: "|")
    }

    static func kind(_ kind: BackgroundItem.Kind) -> WatchedItem.Kind? {
        switch kind {
        case .loginItem: .loginItem
        case .app: .app
        case .agent: .agent
        case .daemon: .daemon
        case .other: nil
        }
    }

    public struct Comparison: Sendable, Equatable {
        public var current: [WatchedItem]
        public var added: [WatchedItem]
        public var removed: [WatchedItem]
    }

    /// What changed since `known` was recorded. With nothing recorded yet, everything becomes the baseline and
    /// nothing counts as added, so the first look doesn't raise an alarm about items that were always there.
    public static func compare(known: [WatchedItem]?, current items: [BackgroundItem], now: Date,
                               created: (String) -> Date? = BackgroundWatch.creationDate) -> Comparison {
        let previous = Dictionary((known ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var current: [WatchedItem] = []
        for item in items {
            guard let kind = kind(item.type) else { continue }
            let id = identity(item)
            guard seen.insert(id).inserted else { continue }
            let firstSeen = previous[id]?.firstSeen ?? (known == nil ? (item.plist ?? item.bundlePath).flatMap(created) ?? now : now)
            current.append(WatchedItem(id: id, name: item.name, developer: item.developer, kind: kind, enabled: item.enabled,
                                       plist: item.plist, executable: item.executable, label: item.label,
                                       bundlePath: item.bundlePath, firstSeen: firstSeen))
        }
        guard let known else { return Comparison(current: current, added: [], removed: []) }
        let added = current.filter { previous[$0.id] == nil }
        let removed = known.filter { old in !seen.contains(old.id) }
        return Comparison(current: current, added: added, removed: removed)
    }

    public static func creationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }
}

/// Who signed a program, the way Gatekeeper sees it.
public enum Signer: Sendable, Equatable, Codable {
    case apple
    case developerID(name: String, team: String?, notarized: Bool)
    /// Signed with a certificate that isn't Developer ID (an App Store or development build).
    case other(name: String)
    case adHoc
    case unsigned
    /// The signature doesn't match the program: it was changed after signing.
    case invalid
    case missing

    public var isTrusted: Bool {
        switch self {
        case .apple, .developerID: true
        case .other, .adHoc, .unsigned, .invalid, .missing: false
        }
    }

    public var summary: String {
        switch self {
        case .apple: "Signed by Apple"
        case .developerID(let name, _, let notarized): "Signed by \(name)" + (notarized ? " · notarized" : "")
        case .other(let name): "Signed by \(name)"
        case .adHoc: "Not signed by a known developer"
        case .unsigned: "Not signed"
        case .invalid: "Signature is broken: the program was changed after signing"
        case .missing: "Its program is missing"
        }
    }

    /// Checks `path` (an app bundle or a program). Resources aren't hashed, so this is quick even for large apps.
    public static func check(_ path: String) -> Signer {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures)
        func satisfies(_ text: String) -> Bool {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
            return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let details = info as? [String: Any] ?? [:]
        guard details[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid }
        if satisfies("anchor apple") { return .apple }
        let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard let leaf = certificates.first else { return .adHoc }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? "an unknown developer"
        let team = details[kSecCodeInfoTeamIdentifier as String] as? String
        if subject.hasPrefix("Developer ID Application: ") || satisfies("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists") {
            let name = subject.replacingOccurrences(of: "Developer ID Application: ", with: "")
                .replacingOccurrences(of: team.map { " (\($0))" } ?? "", with: "")
            return .developerID(name: name, team: team, notarized: satisfies("notarized"))
        }
        return .other(name: subject)
    }
}

/// launchd's view: which items are running and which are switched off.
public struct LaunchdState: Sendable, Equatable {
    public var running: Set<String> = []
    public var disabled: Set<String> = []

    public init(running: Set<String> = [], disabled: Set<String> = []) {
        self.running = running
        self.disabled = disabled
    }

    /// Reads the user's and the system's launchd domains (read-only; no administrator rights needed).
    public static func read(userID: uid_t, systemLabels: [String], run: PerformanceScanner.Run = Shell.run) -> LaunchdState {
        var state = LaunchdState()
        let list = run("/bin/launchctl", ["list"])
        if list.status == 0 { state.running = runningLabels(inList: list.output) }
        for domain in ["gui/\(userID)", "system"] {
            let result = run("/bin/launchctl", ["print-disabled", domain])
            if result.status == 0 { state.disabled.formUnion(disabledLabels(in: result.output)) }
        }
        for label in systemLabels {
            let result = run("/bin/launchctl", ["print", "system/\(label)"])
            if result.status == 0, result.output.contains("state = running") { state.running.insert(label) }
        }
        return state
    }

    /// Labels with a process ID in `launchctl list` ("PID\tStatus\tLabel", "-" when not running).
    static func runningLabels(inList output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count == 3, Int(fields[0]) != nil else { return nil }
            return String(fields[2])
        })
    }

    /// Labels marked `=> disabled` in `launchctl print-disabled`.
    static func disabledLabels(in output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasSuffix("=> disabled") || text.hasSuffix("=> true"),
                  let first = text.firstIndex(of: "\""), let last = text[text.index(after: first)...].firstIndex(of: "\"") else { return nil }
            return String(text[text.index(after: first)..<last])
        })
    }
}

/// Turns launchd background items off and back on. Off is reversible: the plist stays where it is and launchd
/// remembers the item as disabled, so it doesn't start again until it's turned back on.
public struct BackgroundItemSwitch: Sendable {
    public enum Outcome: Equatable, Sendable {
        case done
        case needsSystemSettings
        case cancelled
        case failed(String)
    }

    public var userID: uid_t
    public var run: PerformanceScanner.Run
    public var administrator: @Sendable ([[String]]) -> Result<String, Administrator.Failure>

    public init(userID: uid_t = getuid(), run: @escaping PerformanceScanner.Run = Shell.run,
                administrator: @escaping @Sendable ([[String]]) -> Result<String, Administrator.Failure> = Administrator.runBatch) {
        self.userID = userID
        self.run = run
        self.administrator = administrator
    }

    public func set(_ item: WatchedItem, on: Bool) -> Outcome {
        guard item.isSwitchable, let label = item.label else { return .needsSystemSettings }
        if item.isSystemWide {
            let target = "system/\(label)"
            var commands = [["/bin/launchctl", on ? "enable" : "disable", target]]
            if !on { commands.append(["/bin/launchctl", "bootout", target]) }
            else if let plist = item.plist { commands.append(["/bin/launchctl", "bootstrap", "system", plist]) }
            switch administrator(commands) {
            case .success: return .done
            case .failure(.cancelled): return .cancelled
            case .failure(.failed(let message)):
                // Bootstrapping something already loaded fails harmlessly; the switch itself is what matters.
                return on && message.contains("already") ? .done : .failed(message)
            }
        }
        let domain = "gui/\(userID)"
        let result = run("/bin/launchctl", [on ? "enable" : "disable", "\(domain)/\(label)"])
        guard result.status == 0 else { return .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if on, let plist = item.plist {
            _ = run("/bin/launchctl", ["bootstrap", domain, plist])
        } else if !on {
            _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        }
        return .done
    }
}
