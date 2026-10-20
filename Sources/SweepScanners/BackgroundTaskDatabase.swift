import Foundation
import SweepNative

/// The database behind System Settings → General → Login Items, read directly. It's readable by every user, while
/// `sfltool dumpbtm` can wait indefinitely for an administrator's approval on recent macOS.
///
/// Since macOS 15 there is one keyed archive per user (`BackgroundItems-v<N>-<user UUID>.btm`) plus one for
/// system-wide items (`…-FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE.btm`). Each holds `ItemRecord`s: apps, their login
/// items and launch agents, legacy agents and daemons, and developer groups.
public enum BackgroundTaskDatabase {
    public static let folder = "/private/var/db/com.apple.backgroundtaskmanagement"
    static let systemStore = "FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE"

    /// The user's background items and the system-wide daemons, or nil when this macOS keeps them another way.
    public static func items(userID: uid_t, home: String, folder: String = folder) -> [BackgroundItem]? {
        guard let user = uuid(of: userID), let userFile = newestFile(for: user, in: folder),
              let data = FileManager.default.contents(atPath: userFile), let userItems = items(inArchive: data, home: home)
        else { return nil }
        let system = newestFile(for: systemStore, in: folder).flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { items(inArchive: $0, home: home) } ?? []
        return userItems + system.filter { $0.type == .daemon || $0.type == .agent }
    }

    static func uuid(of user: uid_t) -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SweepUserUUID(user, &bytes) == 0 else { return nil }
        return NSUUID(uuidBytes: bytes).uuidString
    }

    /// The highest-versioned database file for `uuid`.
    static func newestFile(for uuid: String, in folder: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let matches = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("BackgroundItems-v"), name.hasSuffix("-\(uuid).btm") else { return nil }
            let version = name.dropFirst("BackgroundItems-v".count).prefix { $0.isNumber }
            return Int(version).map { ($0, name) }
        }
        return matches.max { $0.0 < $1.0 }.map { folder + "/" + $0.1 }
    }

    /// Item types, as BTM numbers them; 0x10000 marks a legacy (plist-based) item.
    enum ItemType: Int {
        case app = 0x2, loginItem = 0x4, agent = 0x8, daemon = 0x10, developer = 0x20
    }

    static func items(inArchive data: Data, home: String) -> [BackgroundItem]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(RecordStore.self, forClassName: "BTMUserStore")
        unarchiver.setClass(Record.self, forClassName: "ItemRecord")
        guard let store = unarchiver.decodeObject(of: RecordStore.self, forKey: "userStore") else { return nil }
        let byIdentifier = Dictionary(store.records.compactMap { record in record.identifier.map { ($0, record) } },
                                      uniquingKeysWith: { first, _ in first })

        /// Paths inside an app ("/Contents/Library/LoginItems/Helper.app") are relative to the app that contains them.
        func absolute(_ path: String?, in record: Record) -> String? {
            guard var path, !path.isEmpty else { return nil }
            if path.hasPrefix("/Users/"), let rest = path.split(separator: "/", maxSplits: 2).dropFirst().first, Int(rest) != nil {
                path = home + "/" + path.split(separator: "/", maxSplits: 2).dropFirst(2).joined()  // "/Users/501/…"
            }
            let isRelative = !path.hasPrefix("/") || path.hasPrefix("/Contents/")
            guard isRelative else { return path }
            guard let container = record.container.flatMap({ byIdentifier[$0] }), let base = container.url?.path else { return nil }
            return base + (path.hasPrefix("/") ? "" : "/") + path
        }

        return store.records.compactMap { record in
            let enabled = record.disposition & 0x1 != 0
            let kind: BackgroundItem.Kind
            switch ItemType(rawValue: record.type & 0xFFFF) {
            case .loginItem: kind = .loginItem
            case .agent: kind = .agent
            case .daemon: kind = .daemon
            // An app record is only a container, unless the app itself opens at login.
            case .app where enabled: kind = .app
            default: return nil
            }
            guard let identifier = record.identifier else { return nil }
            let location = absolute(record.url?.path, in: record)
            let plist = location.flatMap { $0.hasSuffix(".plist") ? $0 : nil }
            let developer = [record.developerName, record.container.flatMap { byIdentifier[$0]?.developerName }]
                .compactMap { $0 }.first { !$0.isEmpty && $0 != "Unknown Developer" }
            let label = plist.flatMap { NSDictionary(contentsOfFile: $0)?["Label"] as? String }
                ?? identifier.split(separator: ".", maxSplits: 1).last.map(String.init)
            return BackgroundItem(name: record.name ?? identifier, developer: developer, type: kind, enabled: enabled,
                                  identifier: identifier, plist: plist, executable: absolute(record.executablePath, in: record),
                                  label: kind == .agent || kind == .daemon ? label : nil,
                                  bundlePath: location.flatMap { $0.hasSuffix(".app") ? $0 : nil })
        }
    }

    /// Stands in for BTM's own classes while decoding; only the fields Sweep shows are read.
    @objc(SweepBTMRecordStore)
    final class RecordStore: NSObject, NSSecureCoding {
        static let supportsSecureCoding = true
        let records: [Record]

        init?(coder: NSCoder) {
            records = coder.decodeArrayOfObjects(ofClass: Record.self, forKey: "records") ?? []
        }

        func encode(with coder: NSCoder) {}
    }

    @objc(SweepBTMRecord)
    final class Record: NSObject, NSSecureCoding {
        static let supportsSecureCoding = true
        let identifier: String?
        let name: String?
        let developerName: String?
        let container: String?
        let url: URL?
        let executablePath: String?
        let type: Int
        let disposition: Int

        init?(coder: NSCoder) {
            identifier = coder.decodeObject(of: NSString.self, forKey: "identifier") as String?
            name = coder.decodeObject(of: NSString.self, forKey: "name") as String?
            developerName = coder.decodeObject(of: NSString.self, forKey: "developerName") as String?
            container = coder.decodeObject(of: NSString.self, forKey: "container") as String?
            url = coder.decodeObject(of: NSURL.self, forKey: "url") as URL?
            executablePath = coder.decodeObject(of: NSString.self, forKey: "executablePath") as String?
            type = coder.decodeInteger(forKey: "type")
            disposition = coder.decodeInteger(forKey: "disposition")
        }

        func encode(with coder: NSCoder) {}
    }
}
