import Foundation
import Testing
@testable import SweepMonitor

/// Read-only: these only query the system.
@Suite struct SystemMonitorTests {
    @Test func readingsAreWithinSensibleRanges() async throws {
        let monitor = SystemMonitor()
        let first = monitor.sample()
        #expect(first.cpuUsage == nil)  // needs two readings
        try await Task.sleep(for: .milliseconds(300))
        let second = monitor.sample()

        let cpu = try #require(second.cpuUsage)
        #expect((0...1).contains(cpu))
        #expect(second.cpuCores >= 1)
        #expect(second.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(second.memory.used > 0 && second.memory.used <= second.memory.total)
        #expect([1, 2, 4].contains(second.memory.pressureLevel))
        #expect(second.disk.total > 0 && second.disk.available <= second.disk.total)
        #expect(second.uptime > 0)
        let network = try #require(second.network)
        #expect(network.bytesInPerSecond >= 0 && network.bytesOutPerSecond >= 0)
        if let battery = second.battery {
            #expect((0...1).contains(battery.charge))
            if let health = battery.health { #expect((0...1).contains(health)) }
        }
    }
}
