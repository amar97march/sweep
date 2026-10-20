import CryptoKit
import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct ApplicationsScannerTests {
    @Test func findsAnAppsFilesAcrossTheLibrary() throws {
        let mac = try FakeMac()
        let app = try mac.app("Photo Studio", bundleID: "com.vendor.photostudio",
                              extra: ["SMPrivilegedExecutables": ["com.vendor.photostudio.helper": "anchor"]])
        try mac.plist(app + "/Contents/Library/LoginItems/Launcher.app/Contents/Info.plist",
                      ["CFBundleIdentifier": "com.vendor.photostudio.launcher"])
        try mac.file("Library/Application Support/Photo Studio/library.db")
        try mac.file("Library/Application Support/Photo Studio 2023/old.db")      // another edition: not ours
        try mac.file("Library/Application Support/Photo/other.db")                 // one word only: not ours
        try mac.file("Library/Caches/com.vendor.photostudio/c.bin")
        try mac.plist("Library/Preferences/com.vendor.photostudio.plist", ["a": 1])
        try mac.plist("Library/Preferences/ByHost/com.vendor.photostudio.01234567-89AB-CDEF-0123-456789ABCDEF.plist", ["a": 1])
        try mac.file("Library/Containers/com.vendor.photostudio.launcher/Data/x.bin")
        try mac.file("Library/Saved Application State/com.vendor.photostudio.savedState/window.data")
        try mac.systemFile("/Library/PrivilegedHelperTools/com.vendor.photostudio.helper", bytes: 1_000)
        try mac.plist("Library/LaunchAgents/com.other.sync.plist",
                      ["ProgramArguments": [app + "/Contents/MacOS/Photo Studio", "--sync"]])  // runs from inside the app
        try mac.plist(mac.system + "/private/var/db/receipts/com.vendor.photostudio.pkg.plist", ["a": 1])

        let categories = ApplicationsScanner(environment: mac.environment()).scan()
        let group = try #require(categories.category("uninstaller")?.groups.first { $0.title == "Photo Studio" })
        let paths = Set(group.items.compactMap(\.subtitle))
        let home = mac.home
        #expect(paths.contains(app))
        #expect(paths.contains(home + "/Library/Application Support/Photo Studio"))
        #expect(!paths.contains(home + "/Library/Application Support/Photo Studio 2023"))
        #expect(!paths.contains(home + "/Library/Application Support/Photo"))
        #expect(paths.contains(home + "/Library/Caches/com.vendor.photostudio"))
        #expect(paths.contains(home + "/Library/Preferences/com.vendor.photostudio.plist"))
        #expect(paths.contains(home + "/Library/Preferences/ByHost/com.vendor.photostudio.01234567-89AB-CDEF-0123-456789ABCDEF.plist"))
        #expect(paths.contains(home + "/Library/Containers/com.vendor.photostudio.launcher"))
        #expect(paths.contains(home + "/Library/Saved Application State/com.vendor.photostudio.savedState"))
        #expect(paths.contains(mac.system + "/Library/PrivilegedHelperTools/com.vendor.photostudio.helper"))
        #expect(paths.contains(home + "/Library/LaunchAgents/com.other.sync.plist"))
        let receipt = try #require(group.items.first { $0.title == "Installer Receipt" })
        #expect(receipt.action == .custom(kind: "forgetReceipt", payload: ["com.vendor.photostudio.pkg"]))
        #expect(group.items.allSatisfy { !$0.isSelectedByDefault })
    }

    @Test func findsLeftoversOfRemovedApps() throws {
        let mac = try FakeMac()
        try mac.app("Kept", bundleID: "com.kept.app")
        try mac.plist("Library/Preferences/com.gone.editor.plist", ["a": 1])
        try mac.file("Library/Caches/com.gone.editor/cache.bin")
        try mac.plist("Library/Preferences/com.kept.app.plist", ["a": 1])         // installed
        try mac.plist("Library/Preferences/com.kept.helper.plist", ["a": 1])      // same vendor as an installed app
        try mac.plist("Library/Preferences/com.apple.finder.plist", ["a": 1])     // macOS
        try mac.plist("Library/Preferences/com.running.daemon.plist", ["a": 1])   // something running now

        let categories = ApplicationsScanner(environment: mac.environment(running: ["com.running.daemon"])).scan()
        let leftovers = try #require(categories.category("leftovers"))
        #expect(leftovers.groups.map(\.title) == ["com.gone.editor"])
        let items = leftovers.groups[0].items
        #expect(items.first { $0.title == "Caches" }?.isSelectedByDefault == true)
        #expect(items.first { $0.title == "Preferences" }?.isSelectedByDefault == false)
    }

    @Test func listsInstallers() throws {
        let mac = try FakeMac()
        try mac.file("Downloads/Tool-1.0.dmg")
        try mac.file("Desktop/stuff/Driver.pkg")
        let installers = try #require(ApplicationsScanner(environment: mac.environment()).scan().category("installers"))
        #expect(Set(installers.groups.flatMap(\.items).map(\.title)) == ["Tool-1.0.dmg", "Driver.pkg"])
    }

    @Test func ourOwnAppIsNeverOffered() throws {
        let mac = try FakeMac()
        try mac.app("Sweep", bundleID: "org.sweep.Sweep")
        try mac.app("Safari", bundleID: "com.apple.Safari")
        #expect(ApplicationsScanner(environment: mac.environment()).scan().category("uninstaller") == nil)
    }

    @Test func bundleIdentifierShapes() {
        #expect(AppIdentity.bundleIDLike("com.vendor.app.plist", kind: .preferences) == "com.vendor.app")
        #expect(AppIdentity.bundleIDLike("com.vendor.app.01234567-89AB-CDEF-0123-456789ABCDEF.plist", kind: .preferences) == "com.vendor.app")
        #expect(AppIdentity.bundleIDLike("Google", kind: .applicationSupport) == nil)
        #expect(AppIdentity.bundleIDLike("com.vendor", kind: .caches) == nil)
        #expect(AppIdentity.vendor("com.vendor.app.helper") == "com.vendor")
    }
}

@Suite struct UpdateTests {
    @Test func versionOrdering() {
        #expect(Version.compare("1.10", "1.9") == .orderedDescending)
        #expect(Version.compare("2.0", "2.0.0") == .orderedSame)
        #expect(Version.compare("1.0b2", "1.0") == .orderedAscending)
        #expect(Version.compare("1.0b2", "1.0b10") == .orderedAscending)
        #expect(Version.compare("120", "99") == .orderedDescending)
    }

    static let appcast = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
          <item><title>3.0</title><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.com/3.0.zip" sparkle:version="300" sparkle:shortVersionString="3.0" length="10"/></item>
          <item><title>2.5 beta</title><sparkle:channel>beta</sparkle:channel>
            <enclosure url="https://example.com/2.5.zip" sparkle:version="250" sparkle:shortVersionString="2.5b"/></item>
          <item><title>2.1</title><description>Fixes.</description>
            <enclosure url="https://example.com/2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1"
                       sparkle:edSignature="c2ln" length="1234"/></item>
          <item><title>2.0</title>
            <enclosure url="https://example.com/2.0.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
        </channel></rss>
        """

    @Test func picksTheNewestStableItemThisMacCanRun() throws {
        let items = Appcast.parse(Data(Self.appcast.utf8))
        #expect(items.count == 4)
        let best = try #require(Appcast.best(items, systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        #expect(best.shortVersion == "2.1")
        #expect(best.edSignature == "c2ln")
        #expect(best.length == 1234)
        #expect(best.notes == "Fixes.")
    }

    @Test func checksSparkleAndAppStore() async throws {
        let mac = try FakeMac()
        try mac.app("Direct", bundleID: "com.example.direct",
                    extra: ["SUFeedURL": "https://example.com/appcast.xml", "CFBundleVersion": "200", "CFBundleShortVersionString": "2.0"])
        let store = try mac.app("Store", bundleID: "com.example.store", extra: ["CFBundleShortVersionString": "1.0"])
        try mac.file(store + "/Contents/_MASReceipt/receipt", bytes: 10)
        try mac.app("Current", bundleID: "com.example.current",
                    extra: ["SUFeedURL": "https://example.com/current.xml", "CFBundleVersion": "210"])

        let checker = UpdateChecker(fetch: { url in
            switch url.host() == "itunes.apple.com" ? "store" : url.lastPathComponent {
            case "appcast.xml", "current.xml": return Data(Self.appcast.utf8)
            case "store": return Data(#"{"results":[{"version":"1.2","trackViewUrl":"https://apps.apple.com/app/id1","minimumOsVersion":"11.0"}]}"#.utf8)
            default: throw URLError(.fileDoesNotExist)
            }
        }, systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0), brew: nil)

        let updates = await checker.check(AppCatalog.installed(in: mac.environment()))
        #expect(updates.map(\.appName) == ["Direct", "Store"])
        #expect(updates[0].newVersion == "2.1")
        #expect(updates[1].source == .appStore(page: URL(string: "https://apps.apple.com/app/id1")!))
        let category = try #require(UpdateCatalog.category(updates))
        #expect(category.groups.map(\.title) == ["App Store", "Direct Updates"])
        #expect(UpdateCatalog.decode(category.groups[1].items[0]) == updates[0])
    }

    @Test func verifiesEdDSASignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("archive bytes".utf8)
        let signature = try key.signature(for: data).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        try SparkleInstaller.verify(data, signature: signature, publicKey: publicKey)
        #expect(throws: SparkleInstaller.Failure.badSignature) {
            try SparkleInstaller.verify(Data("tampered".utf8), signature: signature, publicKey: publicKey)
        }
        #expect(throws: SparkleInstaller.Failure.unsigned) {
            try SparkleInstaller.verify(data, signature: nil, publicKey: publicKey)
        }
    }

    @Test func installsAVerifiedZipUpdate() async throws {
        let mac = try FakeMac()
        let key = Curve25519.Signing.PrivateKey()
        let installed = try mac.app("Tool", bundleID: "com.example.tool",
                                    extra: ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
                                            "CFBundleShortVersionString": "1.0"])
        // Build version 2 of the app and zip it the way Sparkle feeds ship it.
        let build = mac.root + "/build"
        try mac.app("Tool", bundleID: "com.example.tool", in: build, extra: ["CFBundleShortVersionString": "2.0"])
        let zip = mac.root + "/Tool-2.0.zip"
        try SparkleInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", build + "/Tool.app", zip])
        let archive = try Data(contentsOf: URL(fileURLWithPath: zip))
        let signature = try key.signature(for: archive).base64EncodedString()

        let update = AppUpdate(appPath: installed, appName: "Tool", bundleID: "com.example.tool", installedVersion: "1.0",
                               newVersion: "2.0", source: .sparkle(download: URL(string: "https://example.com/Tool-2.0.zip")!,
                                                                  edSignature: signature, length: Int64(archive.count)),
                               releaseNotes: nil)
        let trashed = Locked<[String]>([])
        let sandbox = mac.root
        try await SparkleInstaller.install(update, fetch: { _ in archive }, requireCodeSignature: false) { url in
            // Sandbox "Trash": keep the old version inside the fake Mac.
            let destination = sandbox + "/.Trash-" + url.lastPathComponent
            try FileManager.default.moveItem(atPath: url.path, toPath: destination)
            trashed.withLock { $0.append(destination) }
            return URL(fileURLWithPath: destination)
        }
        #expect(InstalledApp(path: installed)?.shortVersion == "2.0")
        #expect(trashed.withLock { $0 }.count == 1)
        #expect(InstalledApp(path: trashed.withLock { $0 }[0])?.shortVersion == "1.0")
    }

    @Test func deltaUpdatesAreNotMistakenForTheFullUpdate() {
        let feed = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <sparkle:version>200</sparkle:version>
              <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200" length="9000" sparkle:edSignature="full"/>
              <sparkle:deltas>
                <enclosure url="https://example.com/App-1.9-2.0.delta" sparkle:deltaFrom="190" length="900" sparkle:edSignature="delta"/>
              </sparkle:deltas>
            </item></channel></rss>
            """
        let items = Appcast.parse(Data(feed.utf8))
        #expect(items.map(\.url.absoluteString) == ["https://example.com/App-2.0.zip"])
        #expect(items.first?.edSignature == "full")
    }

    @Test func aFailedInstallPutsTheOldVersionBack() async throws {
        let mac = try FakeMac()
        let key = Curve25519.Signing.PrivateKey()
        let installed = try mac.app("Tool", bundleID: "com.example.tool",
                                    extra: ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
                                            "CFBundleShortVersionString": "1.0"])
        let build = mac.root + "/build"
        try mac.app("Tool", bundleID: "com.example.tool", in: build, extra: ["CFBundleShortVersionString": "2.0"])
        let zip = mac.root + "/Tool-2.0.zip"
        try SparkleInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", build + "/Tool.app", zip])
        let archive = try Data(contentsOf: URL(fileURLWithPath: zip))
        let update = AppUpdate(appPath: installed, appName: "Tool", bundleID: "com.example.tool", installedVersion: "1.0",
                               newVersion: "2.0", source: .sparkle(download: URL(string: "https://example.com/Tool-2.0.zip")!,
                                                                  edSignature: try key.signature(for: archive).base64EncodedString(),
                                                                  length: Int64(archive.count)),
                               releaseNotes: nil)
        let sandbox = mac.root
        await #expect(throws: (any Error).self) {
            try await SparkleInstaller.install(update, fetch: { _ in archive }, requireCodeSignature: false, trash: { url in
                let destination = sandbox + "/.Trash-" + url.lastPathComponent
                try FileManager.default.moveItem(atPath: url.path, toPath: destination)
                return URL(fileURLWithPath: destination)
            }, move: { from, to in
                // The final rename into place fails; every other move works.
                if to == installed && from.contains(".sweep-update-") { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(atPath: from, toPath: to)
            })
        }
        #expect(InstalledApp(path: installed)?.shortVersion == "1.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: (installed as NSString).deletingLastPathComponent)
        #expect(!leftovers.contains { $0.hasPrefix(".sweep-update-") })
    }

    @Test func performerForgetsReceiptsInOneBatch() async throws {
        let mac = try FakeMac()
        let batches = Locked<[[[String]]]>([])
        var performer = ApplicationsPerformer()
        performer.remover = mac.remover
        performer.removeAsAdministrator = { _ in Issue.record("must not prompt"); return .failure(.cancelled) }
        performer.administrator = { commands in batches.withLock { $0.append(commands) }; return .success("") }
        let items = ["a.pkg", "b.pkg"].map { id in
            ScanItem(id: id, title: "Installer Receipt", size: 0, isSelectedByDefault: true,
                     action: .custom(kind: "forgetReceipt", payload: [id]))
        }
        let records = await performer.perform(items)
        #expect(records.allSatisfy { $0.succeeded })
        #expect(batches.withLock { $0 } == [[["/usr/sbin/pkgutil", "--forget", "a.pkg"], ["/usr/sbin/pkgutil", "--forget", "b.pkg"]]])
    }

    @Test func performerSkipsAppsThatWontQuit() async throws {
        let mac = try FakeMac()
        let app = try mac.app("Stubborn", bundleID: "com.example.stubborn")
        var performer = ApplicationsPerformer()
        performer.remover = mac.remover
        performer.removeAsAdministrator = { _ in Issue.record("must not prompt"); return .failure(.cancelled) }
        performer.administrator = { _ in Issue.record("must not prompt"); return .failure(.cancelled) }
        performer.quitApp = { _ in false }
        let item = ScanItem(id: app, title: "Stubborn.app", size: 1, isSelectedByDefault: true,
                            action: .remove(paths: [app], mode: .moveToTrash))
        let records = await performer.perform([item])
        #expect(records.first?.outcome == .skipped("The app is still running"))
        #expect(FileManager.default.fileExists(atPath: app))
    }

    @Test func resettingAnAppQuitsItFirstAndLeavesItAloneIfItWont() async throws {
        let mac = try FakeMac()
        let app = try mac.app("Busy", bundleID: "com.example.busy")
        let prefs = try mac.plist("Library/Preferences/com.example.busy.plist", ["a": 1])
        // Only the app's files are selected (a reset), not the app itself.
        let item = ScanItem(id: app + "|" + prefs, title: "Preferences", size: 1, isSelectedByDefault: true,
                            action: .remove(paths: [prefs], mode: .moveToTrash))
        let asked = Locked<[String]>([])
        var performer = ApplicationsPerformer()
        performer.remover = mac.remover
        performer.removeAsAdministrator = { _ in .failure(.cancelled) }
        performer.quitApp = { path in asked.withLock { $0.append(path) }; return false }
        let records = await performer.perform([item])
        #expect(asked.withLock { $0 } == [app])
        #expect(records.first?.outcome == .skipped("The app is still running"))
        #expect(FileManager.default.fileExists(atPath: prefs))

        performer.quitApp = { _ in true }
        let second = await performer.perform([item])
        #expect(second.first?.succeeded == true)
        #expect(!FileManager.default.fileExists(atPath: prefs))
    }
}

@Suite struct SharedAppFilesTests {
    @Test func filesGoToTheAppTheyNameMostSpecifically() throws {
        let mac = try FakeMac()
        try mac.app("Browser", bundleID: "com.vendor.browser")
        try mac.app("Browser Canary", bundleID: "com.vendor.browser.canary")
        try mac.file("Library/Caches/com.vendor.browser/a.bin")
        try mac.file("Library/Caches/com.vendor.browser.canary/b.bin")
        let groups = try #require(ApplicationsScanner(environment: mac.environment()).scan().category("uninstaller")?.groups)
        func files(_ title: String) -> Set<String> {
            Set(groups.first { $0.title == title }?.items.dropFirst().compactMap(\.subtitle).map { ($0 as NSString).lastPathComponent } ?? [])
        }
        #expect(files("Browser") == ["com.vendor.browser"])
        #expect(files("Browser Canary") == ["com.vendor.browser.canary"])
    }

    @Test func filesTwoAppsShareEquallyBelongToNeither() throws {
        let mac = try FakeMac()
        for (name, id) in [("Writer", "com.suite.writer"), ("Sheets", "com.suite.sheets")] {
            let app = try mac.app(name, bundleID: id)
            try mac.plist(app + "/Contents/Library/LoginItems/Helper.app/Contents/Info.plist", ["CFBundleIdentifier": "com.suite.shared.helper"])
        }
        try mac.file("Library/Containers/com.suite.shared.helper/Data/state.bin")
        let groups = try #require(ApplicationsScanner(environment: mac.environment()).scan().category("uninstaller")?.groups)
        #expect(!groups.flatMap(\.items).contains { ($0.subtitle ?? "").hasSuffix("com.suite.shared.helper") })
    }
}
