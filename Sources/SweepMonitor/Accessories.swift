import Foundation

/// A Bluetooth accessory that reports its battery: AirPods (each bud and the case), a Magic Mouse, keyboard or
/// trackpad, headphones, game controllers.
public struct Accessory: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    /// What macOS calls it: "Headphones", "Mouse", "Keyboard", "Gamepad"…
    public let kind: String
    /// Percentages by part: "Main", "Left", "Right", "Case".
    public let levels: [String: Int]

    public init(name: String, kind: String, levels: [String: Int]) {
        self.name = name
        self.kind = kind
        self.levels = levels
    }

    public var id: String { name }
    /// The part that will run out first (the case doesn't count: it isn't in use).
    public var lowest: Int? { levels.filter { $0.key != "Case" }.values.min() ?? levels.values.min() }

    public var symbol: String {
        let kind = kind.lowercased(), name = name.lowercased()
        if name.contains("airpods") { return "airpods" }
        if kind.contains("mouse") { return "magicmouse.fill" }
        if kind.contains("keyboard") { return "keyboard.fill" }
        if kind.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if kind.contains("gamepad") { return "gamecontroller.fill" }
        if kind.contains("speaker") { return "hifispeaker.fill" }
        return "headphones"
    }
}

public enum AccessoryReader {
    public typealias Run = @Sendable (String, [String]) -> String?

    /// Connected accessories that report a battery level (read-only, from System Information's Bluetooth report).
    public static func read(run: Run = SensorLog.runCommand) -> [Accessory] {
        run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]).map(parse) ?? []
    }

    static func parse(_ output: String) -> [Accessory] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var found: [Accessory] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let properties = value as? [String: Any] else { continue }
                    var levels: [String: Int] = [:]
                    for (key, text) in properties where key.hasPrefix("device_batteryLevel") {
                        let part = String(key.dropFirst("device_batteryLevel".count))
                        if let percent = Int((text as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                            levels[part.isEmpty ? "Main" : part] = percent
                        }
                    }
                    guard !levels.isEmpty else { continue }
                    found.append(Accessory(name: name, kind: properties["device_minorType"] as? String ?? "", levels: levels))
                }
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// When to warn about an accessory running low: once when it falls to the threshold, and again only after it has
/// been charged.
public struct AccessoryAlerts: Codable, Sendable, Equatable {
    public private(set) var warned: Set<String> = []

    public init() {}

    /// Accessories that just fell to `threshold` or below.
    public mutating func check(_ accessories: [Accessory], threshold: Int) -> [Accessory] {
        var due: [Accessory] = []
        for accessory in accessories {
            guard let level = accessory.lowest else { continue }
            if level <= threshold {
                if warned.insert(accessory.id).inserted { due.append(accessory) }
            } else if level >= threshold + 10 {
                warned.remove(accessory.id)
            }
        }
        return due
    }
}
