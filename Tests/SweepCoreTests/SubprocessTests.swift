import Foundation
import Testing
@testable import SweepCore

@Suite struct SubprocessTests {
    @Test func aProgramThatFillsItsErrorPipeStillFinishes() throws {
        // 300 KB on stderr is far past the pipe buffer; reading stdout first would stall forever.
        let result = try Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\\\0' x >&2; echo done"], timeout: 20)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
        #expect(result.errors.count == 300_000)
    }

    @Test func aStuckProgramIsStoppedAtTheTimeout() throws {
        let start = Date()
        let result = try Subprocess.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
