import SwiftUI

/// Colours and surfaces for Disk Map. It sits on the app's dark background, so everything here is light-on-dark.
enum LensStyle {
    static func color(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// Teal → blue → violet, matching the module's theme.
    static let accent = [color(0x2FE0D3), color(0x3D6BFF), color(0x8F5CFF)]
    static var accentGradient: LinearGradient { LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing) }
    static let danger = [color(0xFF3D5A), color(0xFF8A5C)]
    static let warning = color(0xFFB830)
    static let success = color(0x14E3A1)

    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let stroke = LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Bubble colours, one per top-level item; vivid enough to glow on dark glass.
    static let bubblePalette: [Color] = [
        color(0x3D8BFF), color(0x8F5CFF), color(0xE25CFF), color(0xFF8A2A), color(0x2FE0D3),
        color(0x14E3A1), color(0x6C5CFF), color(0x5AC8FF), color(0xFF5E7E), color(0xFFB830),
    ]
}

extension View {
    /// Frosted dark glass panel.
    func lensGlass(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom)))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(SweepBrand.base[1].opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(LensStyle.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// Round glass icon button used in the Disk Map toolbar.
struct LensIconButton: View {
    let symbol: String
    var help: String = ""
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(LensPress())
            .disabled(disabled)
            .help(Text(help))
            .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }

    private var label: some View {
        let fill = Color.white.opacity(hovering && !disabled ? 0.16 : 0.08)
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.white.opacity(disabled ? 0.3 : 0.9))
            .frame(width: 32, height: 32)
            .background(SwiftUI.Circle().fill(fill))
            .overlay(SwiftUI.Circle().strokeBorder(LensStyle.stroke, lineWidth: 1))
    }
}

/// Capsule action button; `prominent` fills it with the accent gradient.
struct LensCapsuleButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var destructive = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 14, weight: prominent ? .bold : .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, prominent ? 22 : 16)
            .padding(.vertical, prominent ? 11 : 9)
            .background {
                if prominent {
                    Capsule().fill(destructive ? LinearGradient(colors: LensStyle.danger, startPoint: .leading, endPoint: .trailing)
                                               : LensStyle.accentGradient)
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
                } else {
                    Capsule().fill(.white.opacity(hovering ? 0.15 : 0.08))
                }
            }
            .overlay(Capsule().strokeBorder((prominent ? AnyShapeStyle(Color.white.opacity(0.4).edge) : AnyShapeStyle(LensStyle.stroke)), lineWidth: 1))
            .shadow(color: prominent ? (destructive ? LensStyle.danger[0] : LensStyle.accent[1]).opacity(hovering ? 0.8 : 0.5) : .clear,
                    radius: hovering ? 16 : 10, y: 4)
            .scaleEffect(hovering && !disabled ? 1.03 : 1)
        }
        .buttonStyle(LensPress())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { over in withAnimation(.spring(duration: 0.25)) { hovering = over } }
    }
}

struct LensPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Mark-for-removal checkbox: fills red-orange when marked.
struct MarkBox: View {
    let marked: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) { MarkBoxFace(marked: marked) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel("Mark for removal")
            .accessibilityValue(Text(marked ? "marked" : "not marked"))
    }
}

/// The box drawn by `MarkBox` and `DangerCheckboxStyle`.
struct MarkBoxFace: View {
    let marked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(marked ? AnyShapeStyle(LinearGradient(colors: LensStyle.danger, startPoint: .topLeading, endPoint: .bottomTrailing))
                             : AnyShapeStyle(.white.opacity(0.06)))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder((Color.white.opacity(marked ? 0.5 : 0.32)).edge, lineWidth: 1.2)
            if marked {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 17, height: 17)
        .shadow(color: marked ? LensStyle.danger[0].opacity(0.6) : .clear, radius: 5)
        .animation(.spring(duration: 0.25), value: marked)
    }
}

/// Checkbox for a choice that makes removal riskier, drawn like `MarkBox` instead of the system checkbox.
struct DangerCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                MarkBoxFace(marked: configuration.isOn)
                configuration.label.foregroundStyle(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(configuration.isOn ? "on" : "off"))
    }
}

extension Color {
    /// Border fill that is bright on top and fades toward the bottom. Solid-colour capsule and
    /// rounded borders render with stray edge lines in window snapshots; a gradient doesn't.
    var edge: LinearGradient {
        LinearGradient(colors: [self, opacity(0.55)], startPoint: .top, endPoint: .bottom)
    }
}
