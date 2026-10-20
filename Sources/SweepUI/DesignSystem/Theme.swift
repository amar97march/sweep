import SwiftUI
import SweepLens

extension Color {
    /// `Color(hex: 0x7B5CFF)`
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// App-wide colours. The window is always dark; modules bring their own light.
enum Palette {
    /// Sweep's base, top to bottom.
    static let base = SweepBrand.base
    static let sidebar = SweepBrand.sidebar
    static let card = Color.white.opacity(0.06)
    static let cardHighlight = Color.white.opacity(0.10)
    static let stroke = LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
}

/// Look of one module: hero symbol, three-stop gradient, glow, and copy for the intro screen.
public struct ModuleTheme: Sendable {
    public let title: String
    public let tagline: String
    public let symbol: String
    /// Three vivid stops: main, secondary, highlight.
    public let colors: [Color]

    public var accent: Color { colors[0] }
    public var glow: Color { colors[0] }
    public var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    public var buttonGradient: LinearGradient {
        LinearGradient(colors: [colors[0].mix(with: colors[2], by: 0.3), colors[0], colors[1].mix(with: .black, by: 0.08)],
                       startPoint: .leading, endPoint: .trailing)
    }
    public var textGradient: LinearGradient {
        LinearGradient(colors: [.white, colors[2].mix(with: .white, by: 0.35)], startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    /// Blend toward another colour (0 = self, 1 = other).
    func mix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(.sRGB, red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
                     opacity: Double(a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t))
    }
}

/// Every module in the sidebar, in order.
public enum ModuleKind: String, CaseIterable, Identifiable, Sendable {
    case checkup, cleanup, protection, performance, applications, declutter, diskMap, cloudFiles, updater, assistant, activity

    public var id: String { rawValue }

    public var theme: ModuleTheme {
        switch self {
        case .checkup:
            ModuleTheme(title: "Checkup", tagline: "One scan for junk, threats, speed and updates.",
                        symbol: "checkmark.seal.fill", colors: SweepBrand.signature)
        case .cleanup:
            ModuleTheme(title: "Junk Files", tagline: "Remove caches, logs and other junk your Mac doesn't need.",
                        symbol: "trash.fill", colors: [Color(hex: 0x14E3A1), Color(hex: 0x12A8D6), Color(hex: 0x9BF56B)])
        case .protection:
            ModuleTheme(title: "Security", tagline: "Find malware, risky startup items and privacy traces.",
                        symbol: "shield.lefthalf.filled", colors: [Color(hex: 0xFF3D7F), Color(hex: 0xA83CFF), Color(hex: 0xFF8A5C)])
        case .performance:
            ModuleTheme(title: "Maintenance", tagline: "Run maintenance and manage what starts with your Mac.",
                        symbol: "gauge.with.dots.needle.67percent", colors: [Color(hex: 0xFF8A2A), Color(hex: 0xFF4D7A), Color(hex: 0xFFD04A)])
        case .applications:
            ModuleTheme(title: "Apps", tagline: "Uninstall apps completely, update them, remove leftovers.",
                        symbol: "square.stack.3d.up.fill", colors: [Color(hex: 0x3D8BFF), Color(hex: 0x6C5CFF), Color(hex: 0x33E0FF)])
        case .declutter:
            ModuleTheme(title: "Declutter", tagline: "Duplicates, look-alike photos and big files you've forgotten.",
                        symbol: "square.on.square.dashed", colors: [Color(hex: 0xFFB830), Color(hex: 0xFF5E7E), Color(hex: 0xFFE66B)])
        case .diskMap:
            ModuleTheme(title: "Disk Map", tagline: "See what takes up space, folder by folder.",
                        symbol: "circle.hexagongrid.fill", colors: [Color(hex: 0x2FE0D3), Color(hex: 0x3D6BFF), Color(hex: 0x8F5CFF)])
        case .cloudFiles:
            ModuleTheme(title: "Cloud Files", tagline: "Free local space taken by iCloud, Google Drive, OneDrive and more.",
                        symbol: "icloud.fill", colors: [Color(hex: 0x5AC8FF), Color(hex: 0x4A6BFF), Color(hex: 0xB58BFF)])
        case .updater:
            ModuleTheme(title: "Updates", tagline: "Every app update in one list: from developers, the App Store and Homebrew.",
                        symbol: "arrow.down.app.fill", colors: [Color(hex: 0x4FA3FF), Color(hex: 0xB45CFF), Color(hex: 0x7DF9FF)])
        case .assistant:
            ModuleTheme(title: "Health", tagline: "Your Mac's health score and what to do next.",
                        symbol: "heart.text.square.fill", colors: [Color(hex: 0xE25CFF), Color(hex: 0x7A5CFF), Color(hex: 0xFF7AB8)])
        case .activity:
            ModuleTheme(title: "Activity", tagline: "Who used your camera and microphone, what runs in the background, and what drains the battery.",
                        symbol: "waveform.path.ecg", colors: [Color(hex: 0x2EC5B6), Color(hex: 0x5856D6), Color(hex: 0x8CF0E6)])
        }
    }
}

extension Color {
    /// Border fill that is bright on top and fades toward the bottom. Solid-colour capsule and
    /// rounded borders render with stray edge lines in window snapshots; a gradient doesn't.
    var edge: LinearGradient {
        LinearGradient(colors: [self, opacity(0.55)], startPoint: .top, endPoint: .bottom)
    }
}
