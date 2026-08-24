import SwiftUI

/// The app's design language: a dark "command-center" aesthetic with a
/// cyan→indigo→violet neon accent. All colors are semantic tokens so screens
/// never hardcode hex. Tuned for high contrast (WCAG AA) on near-black surfaces.
enum Theme {

    // MARK: Surfaces (near-black, layered by elevation)
    static let bg          = Color(hex: 0x0A0B0F)   // app background
    static let bgElevated  = Color(hex: 0x111319)   // cards / sheets
    static let surface     = Color(hex: 0x161922)   // inputs / rows
    static let surfaceHi    = Color(hex: 0x1E2230)   // hovered / selected

    // MARK: Text
    static let textPrimary   = Color(hex: 0xF4F6FB)
    static let textSecondary = Color(hex: 0x9BA3B4)
    static let textMuted     = Color(hex: 0x636B7E)

    // MARK: Accents
    static let accent     = Color(hex: 0x6EA8FF)   // primary accent (readable on dark)
    static let accentCyan = Color(hex: 0x35E0E8)
    static let accentViolet = Color(hex: 0xA78BFA)

    // MARK: Semantic
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)
    static let danger  = Color(hex: 0xF87171)

    static let hairline = Color.white.opacity(0.08)

    // MARK: Gradients
    static let brandGradient = LinearGradient(
        colors: [accentCyan, accent, accentViolet],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func glow(_ color: Color, radius: CGFloat = 18) -> some View {
        color.opacity(0.55).blur(radius: radius)
    }

    // MARK: Type scale (SF Rounded for UI; monospaced for technical data)
    static func display(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func label(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func mono(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    // MARK: Spacing / radii
    enum Space { static let xs: CGFloat = 6, sm: CGFloat = 10, md: CGFloat = 16, lg: CGFloat = 24, xl: CGFloat = 36 }
    enum Radius { static let sm: CGFloat = 10, md: CGFloat = 16, lg: CGFloat = 22 }

    // Standard spring for navigation / state transitions.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let springSnappy = Animation.spring(response: 0.30, dampingFraction: 0.80)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Reusable surfaces & modifiers

/// A glassy elevated card: dark surface, hairline stroke, soft depth.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.md
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

/// App background: near-black with a faint radial brand glow at the top.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.14), .clear],
                           center: .top, startRadius: 8, endRadius: 420)
                .ignoresSafeArea()
                .blendMode(.screen)
        }
    }
}

extension View {
    /// Scale-down press feedback for tappable cards/buttons (HIG/MD scale-feedback).
    func pressable(_ scale: CGFloat = 0.97) -> some View { modifier(PressableModifier(scale: scale)) }
}

private struct PressableModifier: ViewModifier {
    let scale: CGFloat
    @GestureState private var pressed = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1)
            .animation(Theme.springSnappy, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, s, _ in s = true }
            )
    }
}
