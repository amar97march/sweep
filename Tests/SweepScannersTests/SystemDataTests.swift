import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct SystemDataTests {
    @Test func explainsPartsWithoutCountingAnythingTwice() throws {
        let mac = try FakeMac()
        try mac.file("Library/Caches/com.example.app/data", bytes: 300_000)
        try mac.file("Library/Logs/app.log", bytes: 120_000)
        try mac.file("Library/Application Support/Example/library.db", bytes: 200_000)
        let docker = try mac.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 400_000)
        try mac.file(".ollama/models/blobs/sha256-" + String(repeating: "a", count: 64), bytes: 500_000)
        try mac.file(".npm/_cacache/index", bytes: 90_000)
        try mac.file("Library/Developer/Xcode/DerivedData/App/x.o", bytes: 80_000)

        let volume: @Sendable () -> SystemDataScanner.Volume = {
            .init(purgeable: 5_000_000_000, virtualMemory: 2_000_000_000, timeMachineSnapshots: 3)
        }
        let finder = ToolFinder(environment: mac.environment())
        let report = SystemDataScanner(finder: finder, volume: volume, dockerIsRunning: { true }).scan()
        func part(_ id: String) throws -> SystemDataReport.Part { try #require(report.parts.first { $0.id == id }) }

        #expect(try part("purgeable").handling == .automatic)
        #expect(try part("purgeable").destination == .performance)
        #expect(try part("purgeable").detail.hasPrefix("3 local Time Machine snapshots"))
        #expect(try part("virtualMemory").destination == .none)
        #expect(try part("caches").destination == .cleanup("userCaches"))
        #expect(try part("aiModels").destination == .cleanup("aiModels"))
        #expect(try part("docker").bytes == Measure.allocated(docker))
        #expect(try part("developer").destination == .cleanup("developerJunk"))
        // Docker's disk lives in Containers and models in a hidden folder: each is counted once.
        #expect(try part("appData").bytes < 400_000)
        #expect(try part("hidden").bytes < 500_000)
        #expect(try part("hidden").destination == .diskMap(mac.home))
        #expect(report.parts.map(\.bytes) == report.parts.map(\.bytes).sorted(by: >))
        #expect(!report.parts.contains { $0.id == "deviceFiles" })

        // With Docker stopped there's nothing Cleanup can show, so the part says to open Docker instead.
        let stopped = SystemDataScanner(finder: finder, volume: volume, dockerIsRunning: { false }).scan()
        let dockerPart = try #require(stopped.parts.first { $0.id == "docker" })
        #expect(dockerPart.destination != .cleanup("docker"))
        #expect(dockerPart.detail.hasSuffix("Open Docker so Sweep can see what it can free."))
    }

    @Test func shortByteFormatKeepsBadgesNarrow() {
        // The decimal separator follows the user's locale.
        func short(_ bytes: UInt64) -> String { ByteFormat.short(bytes).replacingOccurrences(of: ",", with: ".") }
        #expect(short(4_380_000_000) == "4.4 GB")
        #expect(short(52_920_000_000) == "52.9 GB")
        #expect(ByteFormat.short(128_400_000_000) == "128 GB")
        #expect(ByteFormat.short(980_000_000) == "980 MB")
    }

    @Test func timeMachineSnapshotsSkipUpdateSnapshots() {
        let output = """
            Snapshots for volume group containing disk /:
            com.apple.TimeMachine.2026-10-19-101010.local
            com.apple.TimeMachine.2026-10-20-090909.local
            com.apple.os.update-5203530F8BB20B9DABC5CE76A0FFE87CCC885EE69B8A5488C24B458A7555E3AB
            """
        #expect(SystemDataScanner.timeMachineSnapshots(output) == 2)
    }
}
