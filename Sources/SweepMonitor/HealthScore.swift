import Foundation

/// What the health score looks at.
public struct HealthInputs: Sendable {
    public var snapshot: SystemSnapshot
    /// Junk found by the last Cleanup scan, if one ran.
    public var junkBytes: UInt64?
    /// Threats found by the last Protection scan, if one ran.
    public var threats: Int?
    /// App updates found by the last Applications scan, if one ran.
    public var updates: Int?
    public var daysSinceCleanup: Double?
    public var daysSinceProtectionScan: Double?
    public var hasFullDiskAccess: Bool
    /// Health the drives report about themselves.
    public var drives: [DriveHealth]
    /// Security settings that are off (titles), from the security checklist.
    public var securityProblems: [String]
    /// Apps that need Rosetta, from the last Applications scan.
    public var intelOnlyApps: Int?

    public init(snapshot: SystemSnapshot, junkBytes: UInt64? = nil, threats: Int? = nil, updates: Int? = nil,
                daysSinceCleanup: Double? = nil, daysSinceProtectionScan: Double? = nil, hasFullDiskAccess: Bool = true,
                drives: [DriveHealth] = [], securityProblems: [String] = [], intelOnlyApps: Int? = nil) {
        self.snapshot = snapshot
        self.junkBytes = junkBytes
        self.threats = threats
        self.updates = updates
        self.daysSinceCleanup = daysSinceCleanup
        self.daysSinceProtectionScan = daysSinceProtectionScan
        self.hasFullDiskAccess = hasFullDiskAccess
        self.drives = drives
        self.securityProblems = securityProblems
        self.intelOnlyApps = intelOnlyApps
    }
}

public struct Recommendation: Identifiable, Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case tip = 0, warning = 1, critical = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let title: String
    public let detail: String
    public let severity: Severity
    /// Module that fixes it (`ModuleKind` raw value), if any.
    public let module: String?
    /// Points taken off the score.
    public let penalty: Int
}

public struct HealthReport: Sendable, Equatable {
    public enum Level: String, Sendable {
        case excellent = "Excellent", good = "Good", fair = "Fair", attention = "Needs Attention", critical = "Critical"
    }

    public let score: Int
    public let level: Level
    /// Most important first.
    public let recommendations: [Recommendation]
}

/// A transparent score: start at 100 and subtract a fixed penalty for each problem, so every point lost is
/// explained by a recommendation.
public enum HealthScore {
    public static func evaluate(_ inputs: HealthInputs) -> HealthReport {
        var items: [Recommendation] = []
        func add(_ id: String, _ title: String, _ detail: String, _ severity: Recommendation.Severity, _ module: String?, _ penalty: Int) {
            items.append(Recommendation(id: id, title: title, detail: detail, severity: severity, module: module, penalty: penalty))
        }
        let snapshot = inputs.snapshot
        let free = snapshot.disk.freeFraction
        let freeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: snapshot.disk.available), countStyle: .file)
        if snapshot.disk.total > 0 && free < 0.05 {
            add("disk", "Your startup disk is almost full", "Only \(freeText) left. macOS slows down and updates fail without free space.", .critical, "cleanup", 30)
        } else if snapshot.disk.total > 0 && free < 0.15 {
            add("disk", "Free up disk space", "\(freeText) left. Keep at least 15% free for macOS to work well.", .warning, "diskMap", 12)
        }
        if let threats = inputs.threats, threats > 0 {
            add("threats", "Remove \(threats) \(threats == 1 ? "threat" : "threats")", "Malware was found on your Mac.", .critical, "protection", 30)
        } else if let days = inputs.daysSinceProtectionScan, days <= 14 {
            // Scanned recently: nothing to suggest.
        } else {
            add("protectionScan", "Check for malware",
                inputs.daysSinceProtectionScan == nil ? "You haven't scanned for threats yet." : "You haven't scanned for threats in a while.",
                .tip, "protection", 5)
        }
        switch snapshot.memory.pressureLevel {
        case 4: add("memory", "Memory is under heavy pressure", "Quit apps you aren't using.", .critical, "performance", 15)
        case 2: add("memory", "Memory is getting tight", "Quitting unused apps will make things snappier.", .warning, "performance", 8)
        default: break
        }
        // Rounded once, the way every battery figure in the app shows it.
        if let health = snapshot.battery?.health, Int((health * 100).rounded()) < 80 {
            add("battery", "Battery capacity is \(Int((health * 100).rounded()))%",
                "Below 80% the battery may need service. Check System Settings → Battery → Battery Health.", .warning, nil, 8)
        }
        if let drive = inputs.drives.max(by: { $0.status < $1.status }), drive.status != .good, let problem = drive.problems.first {
            if drive.status == .failing {
                add("drive", "Back up your Mac now", "\(drive.name): \(problem.text) Replace the drive or have it serviced.", .critical, nil, 30)
            } else {
                add("drive", "Keep an eye on your drive", "\(drive.name): \(problem.text) Make sure your backups are current.", .warning, nil, 8)
            }
        }
        if let first = inputs.securityProblems.first {
            let count = inputs.securityProblems.count
            add("security", count == 1 ? "Turn on \(first)" : "Fix \(count) security settings",
                count == 1 ? "\(first) is off. See the security checklist below." : inputs.securityProblems.joined(separator: ", ") + " need attention.",
                .warning, nil, min(6 * count, 18))
        }
        if let intel = inputs.intelOnlyApps, intel > 0 {
            add("intel", "\(intel) \(intel == 1 ? "app needs" : "apps need") Rosetta",
                "Intel-only apps stop opening after macOS 27. Look for Apple silicon versions.", .tip, "applications", 3)
        }
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
            add("thermal", "Your Mac is running hot", "Heavy work or blocked vents can slow it down.", .warning, "performance", 8)
        }
        if let junk = inputs.junkBytes {
            let text = ByteCountFormatter.string(fromByteCount: Int64(clamping: junk), countStyle: .file)
            if junk >= 5_000_000_000 {
                add("junk", "Clean up \(text) of junk", "Caches and logs are taking a lot of space.", .warning, "cleanup", 10)
            } else if junk >= 1_000_000_000 {
                add("junk", "Clean up \(text) of junk", "A quick cleanup frees space.", .tip, "cleanup", 4)
            }
        } else if inputs.daysSinceCleanup.map({ $0 > 30 }) ?? true {
            add("cleanupScan", "Look for junk",
                inputs.daysSinceCleanup == nil ? "You haven't cleaned junk files yet." : "You haven't cleaned junk files in a while.",
                .tip, "cleanup", 4)
        }
        if let updates = inputs.updates, updates > 0 {
            add("updates", "Update \(updates) \(updates == 1 ? "app" : "apps")", "Updates fix bugs and security issues.", .tip, "applications", 3 + min(updates, 5))
        }
        if snapshot.uptime > 14 * 86_400 {
            add("restart", "Restart your Mac", "It's been running for \(Int(snapshot.uptime / 86_400)) days. A restart applies updates and clears memory.", .tip, nil, 4)
        }
        if !inputs.hasFullDiskAccess {
            add("fda", "Allow Full Disk Access", "Without it, scans can't see Mail, Safari and other protected folders.", .tip, nil, 3)
        }
        let score = max(0, 100 - items.reduce(0) { $0 + $1.penalty })
        let level: HealthReport.Level = score >= 90 ? .excellent : score >= 75 ? .good : score >= 55 ? .fair : score >= 35 ? .attention : .critical
        let sorted = items.sorted { ($0.severity, $0.penalty) > ($1.severity, $1.penalty) }
        return HealthReport(score: score, level: level, recommendations: sorted)
    }
}
