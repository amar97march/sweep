import Foundation
import SweepCore
import SweepLens

/// Sample results for screenshots and previews. Never acted on: actions are `.none`-like fakes.
enum DemoData {
    private static func item(_ title: String, _ subtitle: String, _ size: UInt64, selected: Bool = true,
                             days: Double? = nil, note: String? = nil) -> ScanItem {
        ScanItem(id: UUID().uuidString, title: title, subtitle: subtitle, size: size,
                 date: days.map { Date().addingTimeInterval(-$0 * 86_400) }, isSelectedByDefault: selected,
                 action: .custom(kind: "demo", payload: []), note: note)
    }

    private static func group(_ title: String, _ subtitle: String?, _ symbol: String, _ items: [ScanItem]) -> ScanGroup {
        ScanGroup(id: UUID().uuidString, title: title, subtitle: subtitle, icon: .symbol(symbol), items: items)
    }

    static func categories(for kind: ModuleKind) -> [ScanCategory] {
        let GB: UInt64 = 1_000_000_000, MB: UInt64 = 1_000_000
        switch kind {
        case .cleanup:
            return [
                ScanCategory(id: "userCaches", title: "User Cache Files", summary: "Apps rebuild these files when needed.", symbol: "archivebox.fill", groups: [
                    group("Google Chrome", nil, "globe", [item("com.google.Chrome", "~/Library/Caches/com.google.Chrome", 1_840 * MB)]),
                    group("Spotify", nil, "music.note", [item("com.spotify.client", "~/Library/Caches/com.spotify.client", 960 * MB)]),
                    group("Xcode", nil, "hammer.fill", [item("com.apple.dt.Xcode", "~/Library/Caches/com.apple.dt.Xcode", 640 * MB)]),
                    group("npm", "Developer tool cache", "shippingbox.fill", [item(".npm/_cacache", "~/.npm/_cacache", 1_200 * MB, selected: false)]),
                ]),
                ScanCategory(id: "logs", title: "Log Files", summary: "Activity records apps keep.", symbol: "doc.text.magnifyingglass", groups: [
                    group("User Logs", "~/Library/Logs", "doc.text.fill", [item("Zoom", "~/Library/Logs/zoom.us", 220 * MB, days: 3),
                                                                           item("JetBrains", "~/Library/Logs/JetBrains", 140 * MB, days: 12)]),
                ]),
                ScanCategory(id: "developerJunk", title: "Developer Junk", summary: "Build products from Xcode.", symbol: "hammer.circle.fill", groups: [
                    group("Xcode Derived Data", nil, "hammer.fill", [item("MyApp", "DerivedData/MyApp-gfwjwb", 3 * GB, days: 40),
                                                                      item("Sweep", "DerivedData/Sweep-abcdef", 1_100 * MB, days: 2)]),
                ]),
                ScanCategory(id: "trash", title: "Trash Bins", summary: "Items already in the Trash.", symbol: "trash.square.fill", groups: [
                    group("Trash", "~/.Trash", "trash.fill", [item("Old Project.zip", "~/.Trash/Old Project.zip", 2_400 * MB, days: 20)]),
                ]),
                ScanCategory(id: "aiModels", title: "AI Models", summary: "Models downloaded by local AI apps. They can be downloaded again, but large ones take a while. Removed models go to the Trash.", symbol: "brain", groups: [
                    group("Ollama", "~/.ollama/models", "brain", [item("llama3.1:8b", "Same model file as LM Studio's Meta-Llama-3.1-8B-GGUF", 4_900 * MB, selected: false, days: 45),
                                                                  item("qwen2.5-coder:14b", "Ollama model", 9 * GB, selected: false, days: 12),
                                                                  item("Unused model files", "3 files no installed model uses", 1_300 * MB)]),
                    group("LM Studio", "~/.lmstudio/models", "brain", [item("Meta-Llama-3.1-8B-GGUF", "Same model file as Ollama's llama3.1:8b", 4_900 * MB, selected: false, days: 60)]),
                    group("Hugging Face", "~/.cache/huggingface/hub", "cube.fill", [item("openai/whisper-large-v3", "Hugging Face model", 3_100 * MB, selected: false, days: 90),
                                                                                    item("Download cache", "Speeds up repeat downloads; safe to remove", 640 * MB)]),
                ]),
                ScanCategory(id: "docker", title: "Docker", summary: "Space Docker can free inside its virtual disk. Volumes, which hold your data, are never touched. Docker returns the space to macOS after cleaning.", symbol: "shippingbox.fill", groups: [
                    group("Docker", "Docker Desktop · its disk image uses 36 GB on this Mac", "shippingbox.fill", [
                        item("Build cache", "Layers saved from earlier builds; Docker rebuilds them when needed", 6_200 * MB, selected: false),
                        item("Unused images", "Images no container uses; Docker downloads them again when needed", 11 * GB, selected: false),
                        item("Stopped containers", "Removes stopped containers and changes made inside them", 380 * MB, selected: false)]),
                ]),
            ]
        case .protection:
            return [
                ScanCategory(id: "threats", title: "Threats", summary: "Files matching known malware signatures.", symbol: "ladybug.fill", groups: [
                    group("Malware", "1 found", "exclamationmark.shield.fill", [item("Installer", "MACOS.ADLOAD · ~/Downloads/Player/Installer", 3 * MB)]),
                ]),
                ScanCategory(id: "browsers", title: "Browsing Data", summary: "History and cookies your browsers keep.", symbol: "safari.fill", groups: [
                    group("Google Chrome", "Default profile", "globe", [item("Browsing History", "12,480 visits", 0, selected: false),
                                                                        item("Cookies", "1,932 cookies", 0, selected: false)]),
                    group("Safari", "Safari", "safari", [item("Browsing History", "4,211 visits", 0, selected: false)]),
                ]),
            ]
        case .performance:
            return [
                ScanCategory(id: "maintenance", title: "Maintenance Tasks", summary: "Housekeeping macOS doesn't always do.", symbol: "wrench.and.screwdriver.fill", groups: [
                    group("Recommended", "Quick and safe to run now", "star.fill", [
                        item("Flush DNS Cache", "Fixes websites that won't load after network changes.", 0),
                        item("Free Up RAM", "Asks macOS to release inactive memory right away.", 0),
                        item("Speed Up Mail", "Compacts Mail's message database.", 0)]),
                    group("Other Tasks", "Run these when something feels off", "wrench.and.screwdriver.fill", [
                        item("Reindex Spotlight", "Rebuilds the search index.", 0, selected: false),
                        item("Rebuild Launch Services", "Fixes duplicate apps in “Open With”.", 0, selected: false)]),
                ]),
                ScanCategory(id: "backgroundItems", title: "Background Items", summary: "Helpers that run in the background.", symbol: "gearshape.2.fill", groups: [
                    group("Adobe", "2 background items", "gearshape.2.fill", [item("Acrobat Update Helper", "Running at startup", 0, selected: false),
                                                                              item("Creative Cloud", "Running at startup", 0, selected: false)]),
                ]),
            ]
        case .applications:
            return [
                ScanCategory(id: "updates", title: "Updates", summary: "New versions of apps you have.", symbol: "arrow.triangle.2.circlepath.circle.fill", groups: [
                    group("Direct Updates", "Verified before installing", "arrow.down.app.fill", [item("Visual Studio Code", "1.104 → 1.105", 0),
                                                                                                item("iTerm", "3.5.9 → 3.6.0", 0)]),
                ]),
                ScanCategory(id: "uninstaller", title: "Uninstaller", summary: "Remove an app with all its files.", symbol: "xmark.bin.fill", groups: [
                    group("Zoom", "Version 6.4 · Last opened Aug 2", "video.fill", [item("zoom.us.app", "/Applications/zoom.us.app", 410 * MB, selected: false),
                                                                                      item("Application Support", "~/Library/Application Support/zoom.us", 180 * MB, selected: false),
                                                                                      item("Caches", "~/Library/Caches/us.zoom.xos", 90 * MB, selected: false)]),
                ]),
                ScanCategory(id: "leftovers", title: "Leftovers", summary: "Files left by apps already deleted.", symbol: "puzzlepiece.extension.fill", groups: [
                    group("com.oldvendor.editor", "App no longer installed", "questionmark.app.fill", [item("Caches", "~/Library/Caches/com.oldvendor.editor", 320 * MB)]),
                ]),
            ]
        case .declutter:
            return [
                ScanCategory(id: "duplicates", title: "Duplicates", summary: "Identical copies of the same file.", symbol: "doc.on.doc.fill", groups: [
                    group("Holiday.mov", "3 copies · 1.2 GB each", "film", [item("Holiday.mov", "~/Movies", 1_200 * MB, selected: false),
                                                                           item("Holiday.mov", "~/Downloads", 1_200 * MB),
                                                                           item("Holiday copy.mov", "~/Desktop", 1_200 * MB)]),
                ]),
                ScanCategory(id: "large", title: "Large & Old Files", summary: "Big files with when you last opened them.", symbol: "shippingbox.fill", groups: [
                    group("1 GB and larger", "2 files", "externaldrive.fill", [item("ubuntu-24.04.iso", "~/Downloads", 6 * GB, selected: false, days: 400),
                                                                                item("Recording.mov", "~/Movies", 2 * GB, selected: false, days: 30)]),
                ]),
            ]
        case .cloudFiles:
            return [
                ScanCategory(id: "localCopies", title: "Large Downloaded Files", summary: "Remove the local copy; the file stays in the cloud.", symbol: "icloud.and.arrow.down.fill", groups: [
                    group("iCloud Drive", "Downloaded to this Mac", "icloud.and.arrow.down.fill", [item("Wedding.mov", "iCloud Drive/Videos", 4 * GB, days: 120)]),
                    group("Google Drive (you@example.com)", "Downloaded to this Mac", "icloud.and.arrow.down.fill", [item("Archive.zip", "Google Drive/My Drive", 900 * MB, days: 60)]),
                ]),
            ]
        default:
            return []
        }
    }

    static func records(for kind: ModuleKind) -> [ActionRecord] {
        categories(for: kind).flatMap { $0.groups.flatMap(\.items) }.filter(\.isSelectedByDefault).map {
            ActionRecord(itemID: $0.id, title: $0.title, detail: $0.subtitle ?? "", bytes: $0.size, outcome: .done("Removed"))
        }
    }

    /// Records for the log sheet: mostly done, plus a skipped and a failed item and some long paths.
    static func logRecords(for kind: ModuleKind) -> [ActionRecord] {
        let GB: UInt64 = 1_000_000_000, MB: UInt64 = 1_000_000
        if kind == .performance {
            return [
                ActionRecord(title: "Flush DNS Cache", detail: "Fixes websites that won't load after network changes.", bytes: 0, outcome: .done("Done")),
                ActionRecord(title: "Free Up RAM", detail: "Asks macOS to release inactive memory right away.", bytes: 0, outcome: .done("Done")),
                ActionRecord(title: "Speed Up Mail", detail: "Compacts Mail's message database.", bytes: 0, outcome: .skipped("Quit Mail first")),
                ActionRecord(title: "Reindex Spotlight", detail: "Rebuilds the search index.", bytes: 0,
                             outcome: .failed("The administrator password wasn't entered")),
            ]
        }
        return [
            ActionRecord(title: "com.google.Chrome", detail: "~/Library/Caches/com.google.Chrome", bytes: 1_840 * MB, outcome: .done("Removed")),
            ActionRecord(title: "com.spotify.client", detail: "~/Library/Caches/com.spotify.client", bytes: 960 * MB, outcome: .done("Removed")),
            ActionRecord(title: "MyApp", detail: "~/Library/Developer/Xcode/DerivedData/MyApp-gfwjwbqzkeyhcvaxtdhljeyiuxyz/Build/Intermediates.noindex",
                         bytes: 3 * GB, outcome: .done("Moved to Trash")),
            ActionRecord(title: "Zoom", detail: "~/Library/Logs/zoom.us", bytes: 220 * MB, outcome: .done("Removed")),
            ActionRecord(title: "JetBrains", detail: "~/Library/Logs/JetBrains/IntelliJIdea2025.2/indexing-diagnostic/project-with-a-very-long-name-3f2a91",
                         bytes: 140 * MB, outcome: .skipped("In use by IntelliJ IDEA")),
            ActionRecord(title: "Old Project.zip", detail: "~/.Trash/Old Project.zip", bytes: 2_400 * MB, outcome: .failed("Permission denied")),
        ]
    }

    /// What removing `session`'s items might report: flagged items skipped, the last of the rest failed,
    /// everything else moved to the Trash.
    @MainActor static func removalRecords(for session: RemovalSession) -> [RemovalRecord] {
        let removable = session.removableItems
        func record(_ item: LensItem, _ outcome: RemovalRecord.Outcome) -> RemovalRecord? {
            item.path.map { RemovalRecord(date: Date(), path: $0, bytes: item.size, mode: .moveToTrash, outcome: outcome) }
        }
        let removed = removable.enumerated().compactMap { index, item in
            record(item, index == removable.count - 1 && removable.count > 1
                ? .failed(reason: "Permission denied") : .trashed(location: NSHomeDirectory() + "/.Trash/" + item.name))
        }
        let skipped = session.items.compactMap { item in session.warnings[item.id].flatMap { record(item, .skipped(reason: $0)) } }
        return removed + skipped
    }
}

extension CatalogModuleModel {
    /// Shows the done screen with given records, without performing anything (screenshots only).
    func previewDone(_ records: [ActionRecord]) {
        setPreview(records: records)
    }
}
