import Darwin
import Foundation
import Testing
@testable import SweepCore

@Suite struct PrivacyAccessTests {
    @Test func firstLocationThatExistsDecides() {
        func answers(_ results: [String: PrivacyAccess.Probe]) -> (String) -> PrivacyAccess.Probe {
            { results[$0] ?? .missing }
        }
        // macOS 27: the per-user TCC database is gone, the system one answers.
        #expect(PrivacyAccess.hasFullDiskAccess(probing: ["/user-tcc", "/system-tcc", "/safari"],
                                                probe: answers(["/system-tcc": .granted, "/safari": .granted])))
        #expect(!PrivacyAccess.hasFullDiskAccess(probing: ["/user-tcc", "/system-tcc"],
                                                 probe: answers(["/system-tcc": .denied])))
        #expect(!PrivacyAccess.hasFullDiskAccess(probing: ["/a", "/b"], probe: answers([:])))
    }

    @Test func probingFilesAndFolders() throws {
        let base = try TestSandbox.newFolder("privacy")
        defer { TestSandbox.remove(base) }
        let readable = base + "/readable.db"
        let locked = base + "/locked.db"
        try Data("x".utf8).write(to: URL(fileURLWithPath: readable))
        try Data("x".utf8).write(to: URL(fileURLWithPath: locked))
        chmod(locked, 0)
        defer { chmod(locked, 0o644) }

        #expect(PrivacyAccess.probe(readable) == .granted)
        #expect(PrivacyAccess.probe(locked) == .denied)
        #expect(PrivacyAccess.probe(base) == .granted)
        #expect(PrivacyAccess.probe(base + "/missing") == .missing)
        #expect(PrivacyAccess.probe(readable + "/inside-a-file") == .missing)
    }
}
