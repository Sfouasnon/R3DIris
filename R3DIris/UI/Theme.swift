//  Theme.swift — R3DIris / UI
//  R3DIris's own visual identity (2026-07-17, replacing the V3-derived look):
//  neutral graphite surfaces — no blue cast — with an iris duotone accent
//  (teal → violet) drawn from the tool's namesake. Hairline borders, wide-
//  tracked micro-labels, mono numerals. Both tabs share this language.

import SwiftUI

enum Theme {
    // MARK: Palette — graphite neutrals
    static let bg0     = Color(hex: 0x0e0f11)   // window
    static let bg1     = Color(hex: 0x141519)
    static let panel   = Color(hex: 0x1b1d22)
    static let panel2  = Color(hex: 0x16181c)
    static let panel3  = Color(hex: 0x24262d)

    static let ink     = Color(hex: 0xf2f3f5)
    static let ink2    = Color(hex: 0x9aa0ab)
    static let ink3    = Color(hex: 0x5d636e)
    static let line    = Color(hex: 0x262931)
    static let line2   = Color(hex: 0x33363f)

    // MARK: Iris duotone + state colors
    static let accent  = Color(hex: 0x3fd8c7)   // iris teal
    static let accent2 = Color(hex: 0x8f7bff)   // iris violet (gradient partner)
    static let good    = Color(hex: 0x46d68c)
    static let warn    = Color(hex: 0xe5b054)
    static let danger  = Color(hex: 0xf06a5e)
    static let idle    = Color(hex: 0x596070)

    static let accentBG = Color(hex: 0x3fd8c7, alpha: 0.12)
    static let goodBG   = Color(hex: 0x46d68c, alpha: 0.12)
    static let warnBG   = Color(hex: 0xe5b054, alpha: 0.13)
    static let dangerBG = Color(hex: 0xf06a5e, alpha: 0.12)
    static let idleBG   = Color(hex: 0x596070, alpha: 0.16)

    static var irisGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Metrics
    static let radius:   CGFloat = 10
    static let radiusSm: CGFloat = 6

    // MARK: Fonts
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Background — near-black with a faint iris glow top-left (where the
    // logo lives), the identity's one indulgence.
    static var appBackground: some View {
        ZStack {
            bg0
            RadialGradient(
                gradient: Gradient(colors: [accent.opacity(0.05), accent2.opacity(0.02), .clear]),
                center: UnitPoint(x: 0.04, y: -0.05),
                startRadius: 0,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Logo

/// The R3DIris mark: six iris blades (trimmed arcs) sweeping teal → violet
/// around a gray sphere — the tool in one glyph.
struct IrisMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .trim(from: 0.03, to: 0.135)
                    .stroke(bladeColor(i), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(Double(i) * 60))
            }
            Circle()
                .fill(
                    RadialGradient(colors: [Color(hex: 0xc9ccd2), Color(hex: 0x6f747d)],
                                   center: UnitPoint(x: 0.38, y: 0.34),
                                   startRadius: 0, endRadius: size * 0.30))
                .frame(width: size * 0.42, height: size * 0.42)
        }
        .frame(width: size, height: size)
    }

    private func bladeColor(_ i: Int) -> Color {
        // Interpolate teal → violet across the six blades.
        let t = Double(i) / 5.0
        return Color(
            .sRGB,
            red:   0.247 + t * (0.561 - 0.247),
            green: 0.847 + t * (0.482 - 0.847),
            blue:  0.780 + t * (1.000 - 0.780),
            opacity: 1)
    }
}

/// Logo + wordmark for the top bar.
struct IrisWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            IrisMark(size: 22)
            HStack(spacing: 0) {
                Text("R3D")
                    .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.irisGradient)
                Text("IRIS")
                    .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ink)
            }
            .tracking(1.4)
        }
    }
}

// MARK: - Reusable bits (R3DIris idioms)

/// Section header: accent tick · wide-tracked micro-label · mono count.
struct GroupHeader: View {
    let title: String
    let count: String
    var warn: Bool = false
    var danger: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tickFill)
                .frame(width: 3, height: 12)
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Theme.ink2)
            if !count.isEmpty {
                Text(count)
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(countInk)
            }
            Spacer(minLength: 0)
        }
    }

    private var tickFill: AnyShapeStyle {
        if danger { return AnyShapeStyle(Theme.danger) }
        if warn { return AnyShapeStyle(Theme.warn) }
        return AnyShapeStyle(Theme.irisGradient)
    }
    private var countInk: Color { danger ? Theme.danger : warn ? Theme.warn : Theme.ink3 }
}

/// Status dot with a soft glow — link/sphere state at a glance.
struct StatusDot: View {
    enum Level { case ok, fail, warn, off }
    let level: Level
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: level == .off ? .clear : color.opacity(0.7), radius: 3)
    }
    private var color: Color {
        switch level {
        case .ok:   return Theme.good
        case .fail: return Theme.danger
        case .warn: return Theme.warn
        case .off:  return Theme.idle
        }
    }
}

/// R3DIris button: flat capsule, hairline border; prominent = iris accent.
struct DarkButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.65 : 1)))
            .overlay(Capsule().stroke(border, lineWidth: 1))
            .foregroundStyle(ink)
            .contentShape(Capsule())
    }

    private var fill: Color { destructive ? Theme.dangerBG : prominent ? Theme.accentBG : Theme.panel3 }
    private var border: Color { destructive ? Theme.danger.opacity(0.45) : prominent ? Theme.accent.opacity(0.5) : Theme.line2 }
    private var ink: Color { destructive ? Theme.danger : prominent ? Theme.accent : Theme.ink }
}

/// Dark text-field look for toolbars/panels.
struct DarkFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).stroke(Theme.line, lineWidth: 1))
    }
}

/// Panel card — the section container both tabs use.
struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.panel.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func darkField() -> some View { modifier(DarkFieldStyle()) }
    func panelCard() -> some View { modifier(PanelCard()) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue:  Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}
