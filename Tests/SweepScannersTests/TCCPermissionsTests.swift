import Foundation
import Testing
@testable import SweepCore
@testable import SweepScanners

/// TCC databases are built under the fake Mac in `.build/test-fixtures`; the real ones are never opened.
@Suite struct TCCPermissionsTests {
    /// The `access` columns the scan relies on, as macOS 27 (schema 36) lays them out.
    static let schema = """
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
            auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
            policy_id INTEGER, indirect_object_identifier_type INTEGER,
            indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB, flags INTEGER,
            last_modified INTEGER NOT NULL DEFAULT 0, pid INTEGER, pid_version INTEGER,
            boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT 0,
            one_time_reprompt_eligible INTEGER, reminder_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (service, client, client_type, indirect_object_identifier));
        CREATE TABLE admin (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL);
        INSERT INTO admin VALUES ('version', 36);
        """

    private func userDatabase(_ mac: FakeMac) -> String { mac.home + TCCPermissions.relativePath }
    private func systemDatabase(_ mac: FakeMac) -> String { mac.system + TCCPermissions.relativePath }

    private func grant(_ service: String, _ client: String, type: Int = 0, value: Int = 2, target: String = "UNUSED") -> String {
        "INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier) "
            + "VALUES ('\(service)', '\(client)', \(type), \(value), 4, 1, '\(target)');"
    }

    @Test func databasesFollowTheMacOSLayout() throws {
        let mac = try FakeMac()
        #expect(TCCPermissions.databases(home: mac.home, systemRoot: mac.system).isEmpty)

        // macOS 27: only the system database is where apps can find it.
        try makeDatabase(systemDatabase(mac), Self.schema)
        #expect(TCCPermissions.databases(home: mac.home, systemRoot: mac.system) == [systemDatabase(mac)])

        // macOS 26 and earlier: the user's database comes first.
        try makeDatabase(userDatabase(mac), Self.schema)
        #expect(TCCPermissions.databases(home: mac.home, systemRoot: mac.system) == [userDatabase(mac), systemDatabase(mac)])
    }

    @Test func linksAndFoldersAreNotDatabases() throws {
        let mac = try FakeMac()
        let elsewhere = mac.root + "/elsewhere.db"
        try makeDatabase(elsewhere, Self.schema + grant("kTCCServiceCamera", "com.planted.app"))
        try FileManager.default.createDirectory(atPath: (userDatabase(mac) as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: userDatabase(mac), withDestinationPath: elsewhere)
        try FileManager.default.createDirectory(atPath: systemDatabase(mac), withIntermediateDirectories: true)

        #expect(TCCPermissions.databases(home: mac.home, systemRoot: mac.system).isEmpty)
        #expect(TCCPermissions.allowed(home: mac.home, systemRoot: mac.system).isEmpty)
        #expect(TCCPermissions.allowed(inDatabaseAt: userDatabase(mac)).isEmpty)  // SQLite refuses the link too
    }

    @Test func onlyAllowedBundleGrantsAreListedOnce() throws {
        let mac = try FakeMac()
        try makeDatabase(systemDatabase(mac), Self.schema
            + grant("kTCCServiceScreenCapture", "com.recorder.app")
            + grant("kTCCServiceAccessibility", "com.recorder.app", value: 0)  // denied
            + grant("kTCCServiceSystemPolicyAllFiles", "/usr/libexec/helper", type: 1)  // a path, which tccutil can't reset
            + grant("kTCCServiceAccessibility", "com.keys.app"))
        // The user's database on older macOS: one row per Automation target, and a grant also in the system one.
        try makeDatabase(userDatabase(mac), Self.schema
            + grant("kTCCServiceCamera", "com.video.app")
            + grant("kTCCServiceMicrophone", "com.video.app", value: 3)  // limited, not allowed
            + grant("kTCCServiceAppleEvents", "com.script.app", target: "com.apple.finder")
            + grant("kTCCServiceAppleEvents", "com.script.app", target: "com.apple.mail")
            + grant("kTCCServiceAccessibility", "com.keys.app"))

        let allowed = TCCPermissions.allowed(home: mac.home, systemRoot: mac.system)
        #expect(allowed.map { "\($0.client) \($0.service)" } == [
            "com.keys.app kTCCServiceAccessibility",
            "com.recorder.app kTCCServiceScreenCapture",
            "com.script.app kTCCServiceAppleEvents",
            "com.video.app kTCCServiceCamera",
        ])
        #expect(allowed.map { TCCPermissions.label($0.service) } == ["Accessibility", "Screen Recording", "Automation", "Camera"])
    }

    @Test func olderSchemasAndBrokenFilesAreHandled() throws {
        let mac = try FakeMac()
        // The four columns the scan reads are all an older database needs.
        try makeDatabase(userDatabase(mac), """
            CREATE TABLE access(service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER);
            INSERT INTO access VALUES ('kTCCServicePhotos', 'com.photo.app', 0, 2);
            """)
        // Not a database at all, and a database without the table.
        try mac.file(systemDatabase(mac), contents: Data("not a database".utf8))
        let empty = mac.root + "/empty.db"
        try makeDatabase(empty, "CREATE TABLE other(id INTEGER);")

        #expect(TCCPermissions.allowed(home: mac.home, systemRoot: mac.system)
                == [TCCPermissions.Entry(service: "kTCCServicePhotos", client: "com.photo.app")])
        #expect(TCCPermissions.allowed(inDatabaseAt: empty).isEmpty)
        #expect(TCCPermissions.allowed(inDatabaseAt: mac.root + "/missing.db").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mac.root + "/missing.db"))  // never created
    }

    @Test func readingLeavesTheDatabaseUntouched() throws {
        let mac = try FakeMac()
        let path = systemDatabase(mac)
        try makeDatabase(path, Self.schema + grant("kTCCServiceScreenCapture", "com.recorder.app"))
        let folder = (path as NSString).deletingLastPathComponent
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder))

        #expect(TCCPermissions.allowed(home: mac.home, systemRoot: mac.system).count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder)) == files)  // no journal or WAL left behind
    }

    @Test func protectionListsSystemGrants() throws {
        let mac = try FakeMac()
        try makeDatabase(systemDatabase(mac), Self.schema + grant("kTCCServiceScreenCapture", "com.recorder.app"))
        let scanner = ProtectionScanner(environment: mac.environment(), rules: nil, run: CommandLog().run)
        let group = try #require(scanner.scan().category("privacy")?.groups.first { $0.id == "privacy:tcc" })
        #expect(group.items.map(\.title) == ["com.recorder.app"])
        #expect(group.items.map(\.subtitle) == ["Allowed: Screen Recording"])
        #expect(group.items.first?.action == .custom(kind: "revokePermission", payload: ["kTCCServiceScreenCapture", "com.recorder.app"]))
    }
}
