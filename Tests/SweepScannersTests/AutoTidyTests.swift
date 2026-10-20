import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct AutoTidyTests {
    /// File dates come from the files themselves, not Spotlight, so fixtures are predictable.
    private func tidy(_ mac: FakeMac, screenshots: String? = nil) -> AutoTidy {
        AutoTidy(environment: mac.environment(), lastTouched: { Measure.modificationDate($0) }, screenshotFolder: screenshots)
    }

    private func age(_ path: String, days: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: path)
    }

    @Test func installersOlderThanTheRuleGoToTheTrash() throws {
        let mac = try FakeMac()
        let old = try mac.file("Downloads/Tool-1.2.dmg", bytes: 40_000)
        let fresh = try mac.file("Downloads/Other.pkg", bytes: 40_000)
        let document = try mac.file("Downloads/notes.txt", bytes: 1_000)
        try age(old, days: 10)
        try age(fresh, days: 2)
        try age(document, days: 100)
        let items = tidy(mac).candidates(for: TidyRule(kind: .oldInstallers, isEnabled: true, days: 7))
        #expect(items.map(\.id) == [old])
        #expect(items.first?.action == .remove(paths: [old], mode: .moveToTrash))
    }

    @Test func screenshotsAreFoundOnTheDesktopAndInTheirOwnFolder() throws {
        let mac = try FakeMac()
        let desktop = try mac.file("Desktop/Screenshot 2026-09-01 at 10.00.00.png")
        let recording = try mac.file("Pictures/Shots/Screen Recording 2026-09-02 at 09.00.00.mov")
        let photo = try mac.file("Desktop/Holiday.png")
        for path in [desktop, recording, photo] { try age(path, days: 30) }
        let items = tidy(mac, screenshots: mac.home + "/Pictures/Shots")
            .candidates(for: TidyRule(kind: .desktopScreenshots, isEnabled: true, days: 14))
        #expect(Set(items.map(\.id)) == [desktop, recording])
    }

    @Test func oldDownloadsSkipUnfinishedOnes() throws {
        let mac = try FakeMac()
        let old = try mac.file("Downloads/archive.zip")
        let folder = try mac.file("Downloads/Project/readme.md")
        let unfinished = try mac.file("Downloads/movie.mp4.crdownload")
        let recent = try mac.file("Downloads/today.pdf")
        for path in [old, unfinished] { try age(path, days: 90) }
        try age((folder as NSString).deletingLastPathComponent, days: 90)
        try age(recent, days: 1)
        let items = tidy(mac).candidates(for: TidyRule(kind: .oldDownloads, isEnabled: true, days: 60))
        #expect(Set(items.map(\.id)) == [old, mac.home + "/Downloads/Project"])
    }

    @Test func tidyingMovesOnlyWhatTheRulePicked() throws {
        let mac = try FakeMac()
        let old = try mac.file("Downloads/Old.dmg")
        let keep = try mac.file("Downloads/New.dmg")
        try age(old, days: 30)
        let items = tidy(mac).candidates(for: TidyRule(kind: .oldInstallers, isEnabled: true, days: 7))
        let records = CleanupPerformer.perform(items, remover: mac.remover, allowAdministrator: false)
        #expect(records.map(\.outcome) == [.done("Moved to Trash")])
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: keep))
    }
}
