import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct CleanupScannerTests {
    @Test func findsUserCachesNamedAfterTheirApps() throws {
        let mac = try FakeMac()
        try mac.app("Notes Plus", bundleID: "com.example.notesplus")
        try mac.file("Library/Caches/com.example.notesplus/blob.bin", bytes: 300_000)
        try mac.file("Library/Caches/com.other.tool/data.bin", bytes: 50_000)
        try mac.file("Library/Caches/CloudKit/state.db", bytes: 80_000)          // excluded: holds sync state
        try mac.file("Library/Containers/com.example.sandboxed/Data/Library/Caches/img.bin", bytes: 40_000)

        let categories = CleanupScanner(environment: mac.environment()).scan()
        let caches = try #require(categories.category("userCaches"))
        let titles = Set(caches.groups.map(\.title))

        #expect(titles.contains("Notes Plus"))
        #expect(titles.contains("tool"))
        #expect(titles.contains("sandboxed"))  // friendly name from the container identifier
        #expect(!caches.groups.flatMap(\.items).contains { $0.id.contains("CloudKit") })
        #expect(caches.groups.first?.title == "Notes Plus")  // largest first
        #expect(caches.groups.flatMap(\.items).allSatisfy { $0.isSelectedByDefault })
    }

    @Test func cachesOfRunningAppsAreNotPreselected() throws {
        let mac = try FakeMac()
        try mac.file("Library/Caches/com.example.open/cache.bin", bytes: 30_000)
        let categories = CleanupScanner(environment: mac.environment(running: ["com.example.open"])).scan()
        let item = try #require(categories.category("userCaches")?.groups.first?.items.first)
        #expect(!item.isSelectedByDefault)
        #expect(item.subtitle?.contains("quit it first") == true)
    }

    @Test func systemCachesSkipApple() throws {
        let mac = try FakeMac()
        try mac.systemFile("/Library/Caches/com.vendor.updater/pkg.bin")
        try mac.systemFile("/Library/Caches/com.apple.iconservices.store/icons.bin")
        let caches = try #require(CleanupScanner(environment: mac.environment()).scan().category("systemCaches"))
        #expect(caches.groups.flatMap(\.items).map(\.title) == ["com.vendor.updater"])
    }

    @Test func logsSkipTinyFiles() throws {
        let mac = try FakeMac()
        try mac.file("Library/Logs/big.log", bytes: 50_000)
        try mac.file("Library/Logs/tiny.log", bytes: 100)
        try mac.systemFile("/private/var/log/system.log.0.gz", bytes: 30_000)
        try mac.systemFile("/private/var/log/system.log", bytes: 30_000)  // current log: kept
        let logs = try #require(CleanupScanner(environment: mac.environment()).scan().category("logs"))
        let names = logs.groups.flatMap(\.items).map(\.title)
        #expect(names.contains("big.log"))
        #expect(!names.contains("tiny.log"))
        #expect(names.contains("system.log.0.gz"))
        #expect(!names.contains("system.log"))
    }

    @Test func brokenPreferencesAreFound() throws {
        let mac = try FakeMac()
        try mac.plist("Library/Preferences/com.good.app.plist", ["key": "value"])
        try mac.file("Library/Preferences/com.broken.app.plist", contents: Data("not a plist <<<".utf8))
        let broken = try #require(CleanupScanner(environment: mac.environment()).scan().category("brokenPreferences"))
        #expect(broken.groups.flatMap(\.items).map(\.title) == ["com.broken.app.plist"])
    }

    @Test func brokenLaunchAgentsPointAtMissingPrograms() throws {
        let mac = try FakeMac()
        let existing = try mac.systemFile("/usr/local/bin/real-tool", bytes: 100)
        try mac.plist("Library/LaunchAgents/com.ok.agent.plist",
                      ["Label": "com.ok.agent", "ProgramArguments": [existing]])
        try mac.plist("Library/LaunchAgents/com.gone.agent.plist",
                      ["Label": "com.gone.agent", "Program": "/Applications/Gone.app/Contents/MacOS/Gone"])
        let agents = try #require(CleanupScanner(environment: mac.environment()).scan().category("brokenLaunchAgents"))
        #expect(agents.groups.flatMap(\.items).map(\.title) == ["com.gone.agent.plist"])
    }

    @Test func aCacheFolderThatIsALinkIsNotFollowed() throws {
        let mac = try FakeMac()
        try mac.file("Documents/Thesis.pages", bytes: 50_000)
        try mac.file("Documents/Photos/trip.jpg", bytes: 50_000)
        let container = mac.home + "/Library/Containers/com.sneaky.app/Data/Library"
        try FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: container + "/Caches", withDestinationPath: mac.home + "/Documents")
        try mac.file("Library/Caches/com.real.app/blob", bytes: 50_000)

        let items = CleanupScanner(environment: mac.environment()).scan().allItems
        #expect(!items.contains { $0.action.paths.contains { $0.contains("/Documents") } })
        #expect(items.contains { $0.action.paths.contains { $0.hasSuffix("/com.real.app") } })
    }

    @Test func sweepsOwnRemovalHistoryIsKept() throws {
        let mac = try FakeMac()
        try mac.file("Library/Logs/Sweep/removals.jsonl", bytes: 50_000)
        try mac.file("Library/Logs/Other/app.log", bytes: 50_000)
        let logs = CleanupScanner(environment: mac.environment()).scan().category("logs")?.groups.flatMap(\.items) ?? []
        #expect(!logs.contains { $0.action.paths.contains { $0.contains("/Logs/Sweep") } })
        #expect(logs.contains { $0.action.paths.contains { $0.hasSuffix("/Logs/Other") } })
    }

    @Test func launchAgentsRunningCommandsByNameAreNotBroken() throws {
        let mac = try FakeMac()
        let agents = "Library/LaunchAgents"
        try mac.plist("\(agents)/com.me.backup.plist", ["Label": "com.me.backup", "ProgramArguments": ["sh", "-c", "rsync -a ~/x /y"]])
        try mac.plist("\(agents)/com.me.python.plist", ["Label": "com.me.python", "ProgramArguments": ["python3", "job.py"]])
        try mac.plist("\(agents)/com.me.drive.plist", ["Label": "com.me.drive", "Program": "/Volumes/Backup/tool"])
        try mac.plist("\(agents)/com.gone.helper.plist", ["Label": "com.gone.helper", "Program": "/opt/gone/helper"])
        let broken = CleanupScanner(environment: mac.environment()).scan().category("brokenLaunchAgents")
        #expect(broken?.groups.flatMap(\.items).map(\.title) == ["com.gone.helper.plist"])
    }

    @Test func keepsTheNewestBackupOfEachDevice() throws {
        let mac = try FakeMac()
        let base = "Library/Application Support/MobileSync/Backup"
        for (folder, date) in [("old", Date(timeIntervalSince1970: 1_000)), ("UDID-PHONE", Date(timeIntervalSince1970: 2_000))] {
            try mac.plist("\(base)/\(folder)/Info.plist", ["Device Name": "Phone", "Unique Identifier": "UDID-PHONE",
                                                         "Last Backup Date": date])
            try mac.file("\(base)/\(folder)/data.bin", bytes: 60_000)
        }
        let backups = try #require(CleanupScanner(environment: mac.environment()).scan().category("deviceBackups"))
        let items = try #require(backups.groups.first?.items)
        #expect(items.count == 2)
        #expect(items.first { $0.id.hasSuffix("/UDID-PHONE") }?.isSelectedByDefault == false)
        // A second folder for the same device that isn't its current backup is one the user archived.
        #expect(items.first { $0.id.hasSuffix("/old") }?.isSelectedByDefault == false)
        #expect(items.first { $0.id.hasSuffix("/old") }?.title == "Archived backup")
    }

    @Test func devicesWithTheSameNameKeepTheirOwnBackups() throws {
        let mac = try FakeMac()
        let base = "Library/Application Support/MobileSync/Backup"
        for udid in ["AAAA1111", "BBBB2222"] {
            try mac.plist("\(base)/\(udid)/Info.plist", ["Device Name": "iPad", "Unique Identifier": udid,
                                                       "Last Backup Date": Date()])
            try mac.file("\(base)/\(udid)/data.bin", bytes: 60_000)
        }
        // A backup without identifiers can't be matched to a device, so it isn't preselected either.
        try mac.plist("\(base)/mystery/Info.plist", ["Device Name": "iPad", "Last Backup Date": Date(timeIntervalSince1970: 5)])
        try mac.file("\(base)/mystery/data.bin", bytes: 60_000)

        let backups = try #require(CleanupScanner(environment: mac.environment()).scan().category("deviceBackups"))
        #expect(backups.groups.count == 3)
        #expect(backups.groups.flatMap(\.items).allSatisfy { !$0.isSelectedByDefault })
        #expect(Set(backups.groups.map(\.title)).isSuperset(of: ["iPad (…1111)", "iPad (…2222)"]))
    }

    @Test func developerJunk() throws {
        let mac = try FakeMac()
        try mac.file("Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyz/Build/x.o", bytes: 90_000)
        try mac.file("Library/Developer/Xcode/Archives/2026-01-01/MyApp.xcarchive/Info.plist", bytes: 2_000)
        let junk = try #require(CleanupScanner(environment: mac.environment()).scan().category("developerJunk"))
        let derived = try #require(junk.groups.first { $0.title == "Xcode Derived Data" }?.items.first)
        #expect(derived.title == "MyApp")
        #expect(derived.isSelectedByDefault)
        let archive = try #require(junk.groups.first { $0.title == "Xcode Archives" }?.items.first)
        #expect(!archive.isSelectedByDefault)
    }

    @Test func trashContentsAreDeletedPermanently() throws {
        let mac = try FakeMac()
        try mac.file(".Trash/old.zip", bytes: 70_000)
        let trash = try #require(CleanupScanner(environment: mac.environment(), mode: .moveToTrash).scan().category("trash"))
        let item = try #require(trash.groups.first?.items.first)
        #expect(item.title == "old.zip")
        #expect(item.action == .remove(paths: [mac.home + "/.Trash/old.zip"], mode: .deletePermanently))
    }

    @Test func mailDownloadsKeepEditedFiles() throws {
        let mac = try FakeMac()
        let base = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        try mac.file("\(base)/1111/untouched.pdf", bytes: 30_000)
        let edited = try mac.file("\(base)/2222/edited.pdf", bytes: 30_000)
        // Pretend the user edited it a minute after Mail saved it.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: edited)
        let mail = try #require(CleanupScanner(environment: mac.environment()).scan().category("mail"))
        let items = mail.groups.flatMap(\.items)
        #expect(items.first { $0.title == "untouched.pdf" }?.isSelectedByDefault == true)
        #expect(items.first { $0.title == "edited.pdf" }?.isSelectedByDefault == false)
    }

    @Test func emptyMacFindsNothing() throws {
        let mac = try FakeMac()
        #expect(CleanupScanner(environment: mac.environment()).scan().isEmpty)
    }

    @Test func derivedDataNames() {
        #expect(CleanupScanner.derivedDataName("Sweep-gfwjwbzdgmuhkoaxgvqkoddzbcmw") == "Sweep")
        #expect(CleanupScanner.derivedDataName("ModuleCache.noindex") == "ModuleCache.noindex")
    }
}
