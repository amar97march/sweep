import Foundation
import os

/// How macOS manages charging: the charge limit set in System Settings → Battery (macOS 26.4 and later),
/// read from powerd's published policy without any special permission.
public struct ChargeLimit: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// macOS stops charging at this percentage.
        case limited(Int)
        /// Charges to 100%.
        case off
        /// This version of macOS has no charge limit setting.
        case unavailable
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    /// Where powerd publishes its charging policies (world-readable).
    public static let policyFile = "/Library/Preferences/com.apple.powerd.charging.plist"

    /// macOS 26.4 added the setting.
    public static var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0))
    }

    public static func current(policyFile: String = policyFile, available: Bool = isAvailable) -> State {
        // Read again only when the file changes: Assistant asks every couple of seconds.
        let modified = (try? FileManager.default.attributesOfItem(atPath: policyFile)[.modificationDate]) as? Date
        let key = CacheKey(path: policyFile, modified: modified, available: available)
        if let cached = cache.withLock({ $0 }), cached.key == key { return cached.state }
        let state: State
        if let data = FileManager.default.contents(atPath: policyFile), let limit = manualLimit(inPolicyFile: data) {
            state = .limited(limit)
        } else {
            state = available ? .off : .unavailable
        }
        cache.withLock { $0 = (key, state) }
        return state
    }

    private struct CacheKey: Equatable, Sendable {
        let path: String
        let modified: Date?
        let available: Bool
    }

    private static let cache = OSAllocatedUnfairLock<(key: CacheKey, state: State)?>(initialState: nil)

    /// The user's limit from the policy file: a property list whose `policies` entry is a keyed archive of
    /// charge-control policies. The user's limit is the policy whose reason is "manualChargeLimit".
    static func manualLimit(inPolicyFile data: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = plist["policies"] as? Data else { return nil }
        return manualLimit(inArchive: archive)
    }

    /// Secure decoding: the archive can only produce arrays of policy records with integer and string fields,
    /// whatever classes it names, so a crafted file can't make Sweep create other objects.
    static func manualLimit(inArchive archive: Data) -> Int? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.setClass(PolicyRecord.self, forClassName: "ChargeCtrlPolicy")
        defer { unarchiver.finishDecoding() }
        let policies = unarchiver.decodeArrayOfObjects(ofClass: PolicyRecord.self, forKey: NSKeyedArchiveRootObjectKey) ?? []
        return policies.first { $0.reason == "manualChargeLimit" && (50...100).contains($0.limit) }?.limit
    }

    /// The fields of powerd's policy objects Sweep needs.
    @objc(SweepChargePolicyRecord)
    final class PolicyRecord: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool { true }

        let limit: Int
        let reason: String?

        init(limit: Int, reason: String?) {
            self.limit = limit
            self.reason = reason
        }

        required init?(coder: NSCoder) {
            limit = coder.decodeInteger(forKey: "soclimit")
            reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
        }

        func encode(with coder: NSCoder) {
            coder.encode(limit, forKey: "soclimit")
            coder.encode(reason, forKey: "reason")
        }
    }
}
