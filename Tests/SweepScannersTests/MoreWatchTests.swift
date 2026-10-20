import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct IntelAppTests {
    /// A Mach-O header: thin little-endian, or universal big-endian with these CPU types.
    static func header(_ types: [UInt32], universal: Bool) -> Data {
        func big(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func little(_ value: UInt32) -> [UInt8] { big(value).reversed() }
        var bytes: [UInt8]
        if universal {
            bytes = big(0xCAFE_BABE) + big(UInt32(types.count))
            for type in types { bytes += big(type) + big(0) + big(4096) + big(1000) + big(12) }
        } else {
            bytes = little(0xFEED_FACF) + little(types[0]) + [UInt8](repeating: 0, count: 24)
        }
        return Data(bytes + [UInt8](repeating: 0, count: 64))
    }

    static let arm: UInt32 = 0x0100_000C, intel: UInt32 = 0x0100_0007

    @Test func readsArchitecturesFromTheHeader() {
        #expect(MachO.architectures(inHeader: Self.header([Self.arm, Self.intel], universal: true)) == [.arm64, .x86_64])
        #expect(MachO.architectures(inHeader: Self.header([Self.intel], universal: false)) == [.x86_64])
        #expect(MachO.architectures(inHeader: Self.header([Self.arm], universal: false)) == [.arm64])
        // A Java class file starts with the same magic, then a version number, not a slice count.
        #expect(MachO.architectures(inHeader: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34] + [UInt8](repeating: 0, count: 32))) == nil)
        #expect(MachO.architectures(inHeader: Data("#!/bin/sh\necho hi\n".utf8)) == nil)
        #expect(MachO.architectures(of: "/bin/ls")?.contains(.arm64) == true)
    }

    @Test func intelOnlyAppsAreListedForRemovalNotPreselected() throws {
        let mac = try FakeMac()
        let old = try mac.app("Old Tool", bundleID: "com.example.old")
        try Self.header([Self.intel], universal: false).write(to: URL(fileURLWithPath: old + "/Contents/MacOS/Old Tool"))
        let universal = try mac.app("Universal", bundleID: "com.example.universal")
        try Self.header([Self.intel, Self.arm], universal: true).write(to: URL(fileURLWithPath: universal + "/Contents/MacOS/Universal"))
        try mac.app("Script", bundleID: "com.example.script")  // random bytes: not Mach-O, never flagged
        let apps = AppCatalog.installed(in: mac.environment())
        #expect(apps.filter(MachO.isIntelOnly).map(\.name) == ["Old Tool"])
        let category = try #require(ApplicationsScanner(environment: mac.environment()).intelOnlyApps(apps))
        let item = try #require(category.groups.first?.items.first)
        #expect(category.id == "intelApps")
        #expect(item.title == "Old Tool")
        #expect(!item.isSelectedByDefault)
        #expect(item.action == .remove(paths: [old], mode: .moveToTrash))
        #expect(ApplicationsScanner(environment: mac.environment()).intelOnlyApps(apps.filter { $0.name != "Old Tool" }) == nil)
    }
}

@Suite struct SecurityChecklistTests {
    private func checklist(_ responses: [String: (Int32, String)], plist: [String: Any] = [:]) -> [String: SecurityCheck] {
        let log = CommandLog(responses)
        nonisolated(unsafe) let settings = plist
        let checks = SecurityChecklist(run: log.run, readPlist: { _ in settings }, now: Date(timeIntervalSince1970: 1_800_000_000)).checks()
        #expect(log.recorded.allSatisfy { !$0.contains("write") && !$0.contains("--setglobalstate") && !$0.contains("enable") }, "only reads")
        return Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })
    }

    @Test func aWellSetUpMacPassesEveryCheck() {
        let checks = checklist([
            "fdesetup status": (0, "FileVault is On.\n"),
            "socketfilterfw --getglobalstate": (0, "Firewall is enabled. (State = 1)\n"),
            "spctl --status": (0, "assessments enabled\n"),
            "csrutil status": (0, "System Integrity Protection status: enabled.\n"),
            "xprotect version": (0, "Version: 5367 Installed: 2027-01-10 08:29:19 +0000\n"),
            "sysadminctl -screenLock": (0, "2026-10-20 sysadminctl[1:2] screenLock delay is 60 seconds\n"),
            "tmutil destinationinfo": (0, "Name : Backup\nKind : Local\n"),
            "tmutil latestbackup": (0, "/Volumes/Backup/2027-01-14-101500.backup\n"),
        ], plist: ["AutomaticallyInstallMacOSUpdates": true, "CriticalUpdateInstall": 1])
        #expect(checks.count == 8)
        #expect(checks.values.allSatisfy { $0.status == .good }, "\(checks.values.filter { $0.status != .good }.map(\.id))")
        #expect(checks["xprotect"]?.detail.hasPrefix("XProtect 5367, updated") == true)
        #expect(checks["screenLock"]?.detail == "Asked for within 1 minute of locking.")
        #expect(checks["backup"]?.detail == "Last Time Machine backup 1 day ago.")
    }

    @Test func problemsComeWithAFix() {
        let checks = checklist([
            "fdesetup status": (0, "FileVault is Off.\n"),
            "socketfilterfw --getglobalstate": (0, "Firewall is disabled. (State = 0)\n"),
            "spctl --status": (0, "assessments disabled\n"),
            "csrutil status": (0, "System Integrity Protection status: disabled.\n"),
            "xprotect version": (0, "Version: 5100 Installed: 2026-05-01 08:00:00 +0000\n"),
            "sysadminctl -screenLock": (0, "screenLock is off\n"),
            "tmutil destinationinfo": (0, "tmutil: No destinations configured.\n"),
        ], plist: ["CriticalUpdateInstall": false])
        #expect(checks["fileVault"]?.status == .problem)
        #expect(checks["fileVault"]?.fix != nil)
        #expect(checks["firewall"]?.status == .warning)
        #expect(checks["gatekeeper"]?.status == .problem)
        #expect(checks["sip"]?.status == .problem)
        #expect(checks["updates"]?.status == .problem)
        #expect(checks["updates"]?.detail.contains("Security responses") == true)
        #expect(checks["xprotect"]?.status == .warning)
        #expect(checks["screenLock"]?.status == .problem)
        #expect(checks["backup"]?.status == .warning)
    }

    @Test func unreadableAnswersAreUnknownNotGood() {
        let checks = checklist([:])
        #expect(checks["fileVault"]?.status == .unknown)
        #expect(checks["firewall"]?.status == .unknown)
        #expect(checks["xprotect"]?.status == .unknown)
        #expect(checks["screenLock"]?.status == .unknown)
        // No settings file means macOS's defaults: checks on, macOS updates waiting.
        #expect(checks["updates"]?.status == .warning)
        let slow = checklist(["sysadminctl -screenLock": (0, "screenLock delay is 3600 seconds")])
        #expect(slow["screenLock"]?.status == .warning)
    }
}

@Suite struct TrashedAppTests {
    @Test func findsWhatATrashedAppLeftBehind() throws {
        let mac = try FakeMac()
        let trash = mac.home + "/.Trash"
        let zoom = try mac.app("Zoomish", bundleID: "com.example.zoomish", in: trash)
        try mac.file("Library/Caches/com.example.zoomish/cache.db", bytes: 30_000)
        try mac.file("Library/Application Support/Zoomish/data.bin", bytes: 50_000)
        try mac.file("Library/Preferences/com.example.zoomish.plist", bytes: 500)
        try mac.file("Library/Caches/com.example.other/keep.db", bytes: 10_000)
        try mac.app("Other", bundleID: "com.example.other")

        let apps = TrashedApps.apps(inTrash: trash)
        #expect(apps.map(\.path) == [zoom])
        let category = try #require(TrashedApps.leftovers(of: apps[0], environment: mac.environment()))
        let paths = category.groups.flatMap(\.items).map(\.subtitle)
        #expect(paths.contains(mac.home + "/Library/Caches/com.example.zoomish"))
        #expect(paths.contains(mac.home + "/Library/Preferences/com.example.zoomish.plist"))
        #expect(!paths.contains { $0?.contains("com.example.other") == true }, "another app's files stay")
        #expect(category.groups.flatMap(\.items).allSatisfy { $0.isSelectedByDefault })
        #expect(category.title == "Left by Zoomish")
    }

    @Test func nothingIsOfferedWhileAnotherCopyIsInstalled() throws {
        let mac = try FakeMac()
        let trash = mac.home + "/.Trash"
        try mac.app("Zoomish", bundleID: "com.example.zoomish", in: trash)
        try mac.app("Zoomish", bundleID: "com.example.zoomish")
        try mac.file("Library/Caches/com.example.zoomish/cache.db", bytes: 30_000)
        let app = try #require(TrashedApps.apps(inTrash: trash).first)
        #expect(TrashedApps.leftovers(of: app, environment: mac.environment()) == nil)
    }
}

@Suite struct TweakTests {
    @Test func everyTweakCanBeUndone() {
        #expect(Set(Tweak.all.map(\.id)).count == Tweak.all.count)
        for tweak in Tweak.all {
            #expect(tweak.choices.contains { $0.value == nil }, "\(tweak.id) has a choice that restores macOS's default")
            #expect(!tweak.domain.isEmpty && !tweak.key.isEmpty)
        }
    }

    @Test func readsAndWritesThroughDefaults() throws {
        let hidden = try #require(Tweak.all.first { $0.id == "finderHidden" })
        let format = try #require(Tweak.all.first { $0.id == "screenshotFormat" })
        let log = CommandLog(["defaults read": (0, "1\n")])
        let store = TweakStore(run: log.run)
        #expect(store.value(of: hidden) == .bool(true))
        #expect(store.choice(of: hidden) == 0)
        #expect(store.set(hidden, choice: 1))
        #expect(log.recorded.last == ["/usr/bin/defaults", "delete", "com.apple.finder", "AppleShowAllFiles"])
        #expect(store.set(hidden, choice: 0))
        #expect(log.recorded.last == ["/usr/bin/defaults", "write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"])

        let unset = TweakStore(run: CommandLog(["defaults read": (1, "does not exist")]).run)
        #expect(unset.value(of: hidden) == nil)
        #expect(unset.choice(of: hidden) == 1, "unset means off")
        #expect(unset.choice(of: format) == 0, "unset means PNG")
        let jpeg = TweakStore(run: CommandLog(["defaults read": (0, "jpg\n")]).run)
        #expect(jpeg.choice(of: format) == 1)

        store.relaunch("Finder")
        store.relaunch("loginwindow")
        #expect(log.recorded.filter { $0[0] == "/usr/bin/killall" } == [["/usr/bin/killall", "Finder"]], "only Finder, Dock or the menu bar")
    }

    @Test func numbersAndTextParse() {
        #expect(TweakStore.parse("0", like: .number(0.5)) == .number(0))
        #expect(TweakStore.parse("0.15", like: .number(0.5)) == .number(0.15))
        #expect(TweakStore.parse("SCcf", like: .text("SCev")) == .text("SCcf"))
        #expect(TweakStore.parse("maybe", like: .bool(false)) == nil)
    }
}
