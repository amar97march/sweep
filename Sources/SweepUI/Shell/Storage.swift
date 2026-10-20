import Foundation
import UserNotifications

/// Histories Sweep keeps between launches, as JSON files in ~/Library/Application Support/Sweep/Activity.
/// Test and screenshot runs keep them in memory, like `Preferences`.
enum Storage {
    static let folder: URL? = Preferences.isThrowaway ? nil
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sweep/Activity", isDirectory: true)

    private static let memory = MemoryFiles()

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let data: Data?
        if let folder { data = try? Data(contentsOf: folder.appendingPathComponent(name + ".json")) } else { data = memory.data(name) }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        guard let folder else { return memory.set(data, name) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private final class MemoryFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data] = [:]
        func data(_ name: String) -> Data? { lock.withLock { files[name] } }
        func set(_ data: Data, _ name: String) { lock.withLock { files[name] = data } }
    }
}

/// Notifications from scheduled work and watchers. Only from the app bundle, and never in test or screenshot runs.
enum Notifier {
    static var canNotify: Bool { AutomationModel.canOpenAtLogin && !Preferences.isThrowaway }

    static func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
