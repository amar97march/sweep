import Foundation
import MachO

/// Saved settings and history. Test and screenshot runs keep them in memory instead,
/// so they never change the user's real preferences.
enum Preferences {
    /// True under `swift test` and screenshot runs.
    static let isThrowaway = ProcessInfo.processInfo.environment["SWEEP_SNAPSHOT_DIR"] != nil || testBundleIsLoaded

    /// Whether a test bundle is loaded, whichever runner loaded it (`swiftpm-testing-helper` doesn't
    /// register it with `Bundle`).
    private static var testBundleIsLoaded: Bool {
        (0..<_dyld_image_count()).contains { index in
            _dyld_get_image_name(index).map { String(cString: $0).contains(".xctest/") } ?? false
        }
    }

    private static let memory: Memory? = isThrowaway ? Memory() : nil

    static func object(forKey key: String) -> Any? {
        if let memory { return memory.value(forKey: key) }
        return UserDefaults.standard.object(forKey: key)
    }

    static func set(_ value: Any?, forKey key: String) {
        if let memory { return memory.set(value, forKey: key) }
        UserDefaults.standard.set(value, forKey: key)
    }

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]

        func value(forKey key: String) -> Any? { lock.withLock { values[key] } }
        func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    }
}
