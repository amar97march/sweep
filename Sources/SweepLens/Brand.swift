import SwiftUI

/// Sweep's own colours, shared by the main window (SweepUI) and Disk Map: deep teal ink lit with aqua and mint.
public enum SweepBrand {
    /// Window background, top to bottom.
    public static let base = [hex(0x0B2624), hex(0x071A19), hex(0x040E0E)]
    /// Sidebar fill, laid over the window background.
    public static let sidebar = hex(0x081C1B, 0.84)
    /// Sweep's signature colours (main, secondary, highlight): Checkup, the brand mark and the finish streak.
    public static let signature = [hex(0x1FD8B4), hex(0x0E9FD8), hex(0xA8F5C8)]

    static func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: opacity)
    }
}
