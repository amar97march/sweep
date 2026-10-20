import Foundation
import Testing
@testable import SweepMonitor

@Suite struct ChargeLimitTests {
    /// A policy file shaped like powerd's: a plist whose "policies" entry archives ChargeCtrlPolicy objects.
    private func policyFile(_ policies: [(Int, String)]) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("ChargeCtrlPolicy", for: ChargeLimit.PolicyRecord.self)
        archiver.encode(policies.map { ChargeLimit.PolicyRecord(limit: $0.0, reason: $0.1) } as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return try PropertyListSerialization.data(fromPropertyList: ["bootSessionUUID": "X", "policies": archiver.encodedData],
                                                  format: .binary, options: 0)
    }

    @Test func readsTheUsersManualLimit() throws {
        let data = try policyFile([(95, "thermal"), (80, "manualChargeLimit")])
        #expect(ChargeLimit.manualLimit(inPolicyFile: data) == 80)
        #expect(ChargeLimit.manualLimit(inPolicyFile: try policyFile([(90, "optimizedCharging")])) == nil)
        #expect(ChargeLimit.manualLimit(inPolicyFile: Data("not a plist".utf8)) == nil)
    }

    @Test func otherClassesInTheArchiveAreRefused() throws {
        // An archive whose root is a dictionary (not the expected array of policies) decodes to nothing.
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(["soclimit": 80, "reason": "manualChargeLimit"] as NSDictionary, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        #expect(ChargeLimit.manualLimit(inArchive: archiver.encodedData) == nil)
    }

    @Test func readsThisMacsPolicyIfItHasOne() throws {
        // On a Mac with a charge limit set, the real file must parse with secure decoding.
        guard let data = FileManager.default.contents(atPath: ChargeLimit.policyFile),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = plist["policies"] as? Data,
              archive.range(of: Data("manualChargeLimit".utf8)) != nil else { return }
        #expect(ChargeLimit.manualLimit(inPolicyFile: data) != nil)
    }

    @Test func missingPolicyMeansOffOrUnavailable() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).plist").path
        #expect(ChargeLimit.current(policyFile: missing, available: true) == .off)
        #expect(ChargeLimit.current(policyFile: missing, available: false) == .unavailable)
    }

    @Test func healthComesFromNominalOverDesignCapacity() {
        #expect(SystemMonitor.health(design: 6249, full: 5431).map { ($0 * 1000).rounded() } == 869)
        #expect(SystemMonitor.health(design: nil, full: 5431) == nil)
        #expect(SystemMonitor.health(design: 6249, full: 100) == nil)
    }
}

@Suite struct NetworkCounterTests {
    typealias Traffic = SystemMonitor.Traffic

    @Test func ratesSurviveInterfacesComingAndGoing() {
        let before = ["en0": Traffic(bytesIn: 1_000, bytesOut: 500), "utun3": Traffic(bytesIn: 9_000_000_000, bytesOut: 1)]
        // utun3 vanished (VPN disconnected) and en1 appeared: neither may produce a jump.
        let after = ["en0": Traffic(bytesIn: 3_000, bytesOut: 900), "en1": Traffic(bytesIn: 5_000_000_000, bytesOut: 7)]
        #expect(SystemMonitor.traffic(from: before, to: after) == Traffic(bytesIn: 2_000, bytesOut: 400))
    }

    @Test func aCounterThatResetsAddsNothing() {
        let before = ["en0": Traffic(bytesIn: 4_294_960_000, bytesOut: 10)]
        let after = ["en0": Traffic(bytesIn: 1_000, bytesOut: 20)]
        #expect(SystemMonitor.traffic(from: before, to: after) == Traffic(bytesIn: 0, bytesOut: 10))
    }

    @Test func tunnelsAndLoopbackAreNotCounted() {
        #expect(SystemMonitor.isCounted("en0"))
        #expect(SystemMonitor.isCounted("awdl0"))
        #expect(!SystemMonitor.isCounted("lo0"))
        #expect(!SystemMonitor.isCounted("utun4"))
        #expect(!SystemMonitor.isCounted("ipsec0"))
    }

    @Test func readsLiveCountersWithoutRoot() {
        // Every Mac has at least one physical interface; the counters must be readable as a normal user.
        #expect(!SystemMonitor.interfaceCounters().isEmpty)
    }
}
