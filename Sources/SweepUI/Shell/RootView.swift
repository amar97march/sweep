import SwiftUI
import SweepCore

/// Main window: dark glass sidebar on the left, the selected module on the right.
public struct RootView: View {
    @Bindable var state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state)
                .frame(width: 252)
                .layoutPriority(1)
            ModuleDetail(state: state, kind: state.selection)
                .id(state.selection)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        }
        .background(LinearGradient(colors: Palette.base, startPoint: .top, endPoint: .bottom))
        .animation(.spring(duration: 0.4), value: state.selection)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .frame(minWidth: 1040, minHeight: 680)
    }
}

struct Sidebar: View {
    @Bindable var state: AppState
    @Namespace private var pill

    var body: some View {
        // Twelve rows need about 820 points at full spacing; shorter windows (down to 680) pack them tighter.
        GeometryReader { proxy in
            content(density: proxy.size.height >= 880 ? .roomy : proxy.size.height >= 760 ? .regular : .compact)
        }
    }

    private func content(density: SidebarDensity) -> some View {
        let compact = density != .roomy
        return VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: 10) {
                GradientIcon(symbol: "sparkles", theme: ModuleKind.checkup.theme, size: 30, glowing: true)
                Text("Sweep").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.top, compact ? 38 : 46)
            .padding(.bottom, density == .compact ? 8 : compact ? 12 : 18)

            row(.checkup, density: density)
            header("Free Up Space", density: density)
            ForEach([ModuleKind.cleanup, .declutter, .diskMap, .cloudFiles], id: \.self) { row($0, density: density) }
            header("Protect & Maintain", density: density)
            ForEach([ModuleKind.protection, .performance, .applications, .updater], id: \.self) { row($0, density: density) }
            header("Monitor", density: density)
            ForEach([ModuleKind.assistant, .activity], id: \.self) { row($0, density: density) }
            Spacer(minLength: 0)
            SettingsLink {
                Label("Settings", systemImage: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .padding(.bottom, compact ? 6 : 12)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 1) }
    }

    private func header(_ title: String, density: SidebarDensity) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 14)
            .padding(.top, density.headerTop)
            .padding(.bottom, density == .roomy ? 4 : 2)
    }

    private func row(_ kind: ModuleKind, density: SidebarDensity) -> some View {
        SidebarRow(kind: kind, selected: state.selection == kind, badge: state.badge(for: kind), namespace: pill,
                   rowPadding: density.rowPadding) {
            state.selection = kind
        }
    }
}

/// How tightly the sidebar packs its rows, by window height.
enum SidebarDensity {
    case compact, regular, roomy

    var spacing: CGFloat { self == .roomy ? 4 : 2 }
    var rowPadding: CGFloat { switch self { case .compact: 4; case .regular: 6; case .roomy: 7 } }
    var headerTop: CGFloat { switch self { case .compact: 8; case .regular: 12; case .roomy: 16 } }
}

struct SidebarRow: View {
    let kind: ModuleKind
    let selected: Bool
    let badge: String?
    let namespace: Namespace.ID
    var rowPadding: CGFloat = 7
    let action: () -> Void
    @State private var hovering = false
    /// Bumped when the row becomes selected, so its icon bounces.
    @State private var bounce = 0

    var body: some View {
        let theme = kind.theme
        Button(action: action) {
            HStack(spacing: 11) {
                GradientIcon(symbol: theme.symbol, theme: theme, size: 28, glowing: selected, bounce: bounce)
                Text(theme.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .lineLimit(1)
                        .fixedSize()
                        .background(Capsule().fill(theme.gradient.opacity(0.85)))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, rowPadding)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [theme.colors[0].opacity(0.32), theme.colors[1].opacity(0.16)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((Color.white.opacity(0.14)).edge))
                        .shadow(color: theme.glow.opacity(0.35), radius: 10)
                        .matchedGeometryEffect(id: "pill", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovering = over } }
        .onChange(of: selected) { _, now in if now { bounce += 1 } }
        .animation(.badgeSpring, value: badge)
    }
}

extension Animation {
    static let badgeSpring = Animation.spring(duration: 0.35, bounce: 0.3)
}

struct ModuleDetail: View {
    var state: AppState
    let kind: ModuleKind

    var body: some View {
        Group {
            if let catalog = state.catalog(for: kind) {
                CatalogModuleView(model: catalog) {
                    if [.cleanup, .protection].contains(kind) && !state.hasFullDiskAccess { FullDiskAccessNote() }
                    if kind == .protection { ScanDepthPicker(settings: state.settings) }
                }
            } else if kind == .diskMap {
                DiskMapView(model: state.diskMap, state: state)
            } else if kind == .checkup {
                CheckupView(model: state.checkup)
            } else if kind == .updater {
                UpdaterView(model: state.updater)
            } else if kind == .activity {
                ActivityView(model: state.activity, alerts: state.alerts)
            } else {
                AssistantView(model: state.assistant, state: state)
            }
        }
    }
}

struct ScanDepthPicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("Scan", selection: $settings.protectionDeepScan) {
            Text("Quick — startup items, apps, Downloads").tag(false)
            Text("Deep — everything in your home folder").tag(true)
        }
        .pickerStyle(.radioGroup)
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }
}

struct FullDiskAccessNote: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Color(hex: 0xFFB830))
            Text("Allow Full Disk Access to also check Mail, Safari and other protected folders.")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            } label: {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xFFE66B), Color(hex: 0xFFB830)], startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(PressScale())
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().strokeBorder(Palette.stroke))
    }
}
