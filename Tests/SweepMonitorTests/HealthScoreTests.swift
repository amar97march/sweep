import Foundation
import Testing
@testable import SweepMonitor

@Suite struct HealthScoreTests {
    private func snapshot(free: Double = 0.5, pressure: Int = 1, uptimeDays: Double = 1, batteryHealth: Double? = 0.95) -> SystemSnapshot {
        SystemSnapshot(
            date: Date(), cpuUsage: 0.1, cpuCores: 8,
            memory: .init(total: 16_000_000_000, used: 8_000_000_000, wired: 1, compressed: 1, cached: 1, swapUsed: 0, pressureLevel: pressure),
            disk: .init(total: 1_000_000_000_000, available: UInt64(free * 1_000_000_000_000)),
            battery: batteryHealth.map { .init(charge: 0.8, isCharging: false, isPluggedIn: false, minutesRemaining: 300, cycleCount: 100, health: $0) },
            network: nil, uptime: uptimeDays * 86_400, thermalState: .nominal)
    }

    @Test func aWellKeptMacScoresFull() {
        let report = HealthScore.evaluate(HealthInputs(snapshot: snapshot(), junkBytes: 100_000_000, threats: 0, updates: 0,
                                                       daysSinceCleanup: 1, daysSinceProtectionScan: 1))
        #expect(report.score == 100)
        #expect(report.level == .excellent)
        #expect(report.recommendations.isEmpty)
    }

    @Test func seriousProblemsComeFirstAndExplainEveryPoint() {
        let report = HealthScore.evaluate(HealthInputs(snapshot: snapshot(free: 0.03, pressure: 4, uptimeDays: 30, batteryHealth: 0.7),
                                                       junkBytes: 6_000_000_000, threats: 2, updates: 3,
                                                       daysSinceCleanup: 1, daysSinceProtectionScan: 1, hasFullDiskAccess: false))
        #expect(report.level == .critical)
        #expect(report.recommendations.first?.severity == .critical)
        #expect(Set(report.recommendations.prefix(3).map(\.id)) == ["disk", "threats", "memory"])
        #expect(report.score == max(0, 100 - report.recommendations.reduce(0) { $0 + $1.penalty }))
        #expect(report.recommendations.first { $0.id == "threats" }?.module == "protection")
    }

    @Test func nudgesWhenScansAreOverdue() {
        let report = HealthScore.evaluate(HealthInputs(snapshot: snapshot()))
        #expect(Set(report.recommendations.map(\.id)) == ["protectionScan", "cleanupScan"])
        #expect(report.level == .excellent)  // tips alone don't drag a healthy Mac down far
        // Never scanned is "yet", not "in a while".
        #expect(report.recommendations.allSatisfy { $0.detail.hasSuffix("yet.") })
        let overdue = HealthScore.evaluate(HealthInputs(snapshot: snapshot(), daysSinceCleanup: 60, daysSinceProtectionScan: 60))
        #expect(overdue.recommendations.allSatisfy { $0.detail.contains("in a while") })
    }

    @Test func batteryCapacityIsRoundedLikeEverywhereElse() {
        let healthy = HealthScore.evaluate(HealthInputs(snapshot: snapshot(batteryHealth: 0.7996)))
        #expect(!healthy.recommendations.contains { $0.id == "battery" })  // shows as 80% everywhere
        let worn = HealthScore.evaluate(HealthInputs(snapshot: snapshot(batteryHealth: 0.784)))
        #expect(worn.recommendations.first { $0.id == "battery" }?.title == "Battery capacity is 78%")
    }
}
