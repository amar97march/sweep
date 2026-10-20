import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

@Suite struct CloudTests {
    private func options() -> CloudScanner.Options {
        var options = CloudScanner.Options()
        options.largeFileSize = 100_000
        return options
    }

    @Test func findsProvidersAndNamesThem() throws {
        let mac = try FakeMac()
        try mac.file("Library/Mobile Documents/com~apple~CloudDocs/a.txt", bytes: 10)
        try mac.file("Library/CloudStorage/GoogleDrive-me@example.com/My Drive/b.txt", bytes: 10)
        try mac.file("Library/CloudStorage/Dropbox/c.txt", bytes: 10)
        let names = CloudScanner(environment: mac.environment()).providers().map(\.name)
        #expect(names == ["iCloud Drive", "Dropbox", "Google Drive (me@example.com)"])
    }

    @Test func listsLargeDownloadedFilesForEviction() throws {
        let mac = try FakeMac()
        let big = try mac.file("Library/Mobile Documents/com~apple~CloudDocs/Videos/trip.mov", bytes: 300_000)
        try mac.file("Library/Mobile Documents/com~apple~CloudDocs/notes.txt", bytes: 1_000)
        try mac.file("Library/CloudStorage/OneDrive-Personal/backup.zip", bytes: 200_000)
        // Opened recently → listed but not preselected.
        var environment = mac.environment()
        environment.now = Date()
        let categories = CloudScanner(environment: environment, options: options()).scan()
        let local = try #require(categories.category("localCopies"))
        #expect(local.groups.map(\.title) == ["iCloud Drive", "OneDrive (Personal)"])
        let trip = try #require(local.groups[0].items.first)
        #expect(trip.action == .custom(kind: "evict", payload: [big]))
        #expect(!trip.isSelectedByDefault)

        // A month and a half later it counts as not opened recently.
        environment.now = Date().addingTimeInterval(45 * 86_400)
        let later = CloudScanner(environment: environment, options: options()).scan()
        #expect(later.category("localCopies")?.groups[0].items.first?.isSelectedByDefault == true)
    }

    @Test func appPrivateDataIsListedButNeverRemovedFileByFile() throws {
        let mac = try FakeMac()
        let root = "Library/Mobile Documents"
        try mac.file("\(root)/57T9237FN3~net~whatsapp~WhatsApp/Accounts/123/backup/Media.tar", bytes: 150_000)
        try mac.file("\(root)/57T9237FN3~net~whatsapp~WhatsApp/Accounts/123/backup/ChatStorage.sqlite.enc", bytes: 60_000)
        let pages = try mac.file("\(root)/com~apple~Pages/Documents/Plans/Big Plan.pages", bytes: 200_000)
        let movie = try mac.file("\(root)/com~apple~CloudDocs/Videos/trip.mov", bytes: 300_000)

        let categories = CloudScanner(environment: mac.environment(), options: options()).scan()
        // Only files visible in iCloud Drive can be acted on.
        #expect(Set(categories.category("localCopies")?.groups.flatMap(\.items).map(\.id) ?? []) == ["evict:" + pages, "evict:" + movie])
        #expect(!categories.allItems.contains { $0.action.paths.contains { $0.contains("whatsapp") } })
        let subtitles = categories.category("localCopies")?.groups.flatMap(\.items).compactMap(\.subtitle) ?? []
        #expect(subtitles.contains { $0.hasSuffix("iCloud Drive/Pages/Plans") })
        #expect(subtitles.contains { $0.hasSuffix("iCloud Drive/Videos") })

        // The backup shows up once, as the app's data, with nothing to tick.
        let app = try #require(categories.category("iCloudAppData")?.groups.first?.items.first)
        #expect(app.title == "WhatsApp")
        #expect(app.size >= 210_000)
        #expect(app.action == .none && app.note != nil)
    }

    @Test func appNamesFromContainers() {
        #expect(CloudScanner.appName(container: "57T9237FN3~net~whatsapp~WhatsApp", installed: []) == "WhatsApp")
        #expect(CloudScanner.appName(container: "iCloud~com~apple~MobileSMS", installed: []) == "MobileSMS")
        #expect(CloudScanner.appName(container: "com~apple~mail", installed: []) == "Mail")
    }

    @Test func pinnedFilesAreLeftAlone() throws {
        let mac = try FakeMac()
        let pinned = try mac.file("Library/CloudStorage/Dropbox/keep.mov", bytes: 300_000)
        #expect(setxattr(pinned, "com.apple.fileprovider.pinned#PX", "1", 1, 0, XATTR_NOFOLLOW) == 0)
        #expect(CloudScanner(environment: mac.environment(), options: options()).scan().isEmpty)
    }

    @Test func evictsThroughTheInjectedHook() throws {
        let mac = try FakeMac()
        let calls = Locked<[String]>([])
        var performer = CloudPerformer()
        performer.remover = mac.remover
        performer.evict = { path in calls.withLock { $0.append(path) }; return nil }
        let item = ScanItem(id: "e", title: "trip.mov", size: 300_000, isSelectedByDefault: true,
                            action: .custom(kind: "evict", payload: ["/cloud/trip.mov"]))
        let records = performer.perform([item])
        #expect(calls.withLock { $0 } == ["/cloud/trip.mov"])
        #expect(records.first?.outcome == .done("Local copy removed"))
        #expect(records.first?.bytes == 300_000)
    }
}
