import SwiftUI

enum ProviderBrandColor {
    static let claude = Color(red: 217 / 255.0, green: 119 / 255.0, blue: 87 / 255.0) // #D97757
    static let codex = Color(red: 32 / 255.0, green: 40 / 255.0, blue: 32 / 255.0)   // #202820
    static let antigravity = Color(red: 66 / 255.0, green: 133 / 255.0, blue: 244 / 255.0) // Google Blue
    static let hermes = Color(red: 121 / 255.0, green: 82 / 255.0, blue: 144 / 255.0) // Purple
}

struct ClaudeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 32.0
        let sy = rect.height / 32.0

        // Outer body: M6 6h20v3h4v12h-4v3h-4v4h-4v-4h-4v4h-4v-4H6v-3H2V9h4z
        path.move(to: CGPoint(x: 6 * sx, y: 6 * sy))
        path.addLine(to: CGPoint(x: 26 * sx, y: 6 * sy))
        path.addLine(to: CGPoint(x: 26 * sx, y: 9 * sy))
        path.addLine(to: CGPoint(x: 30 * sx, y: 9 * sy))
        path.addLine(to: CGPoint(x: 30 * sx, y: 21 * sy))
        path.addLine(to: CGPoint(x: 26 * sx, y: 21 * sy))
        path.addLine(to: CGPoint(x: 26 * sx, y: 24 * sy))
        path.addLine(to: CGPoint(x: 22 * sx, y: 24 * sy))
        path.addLine(to: CGPoint(x: 22 * sx, y: 28 * sy))
        path.addLine(to: CGPoint(x: 18 * sx, y: 28 * sy))
        path.addLine(to: CGPoint(x: 18 * sx, y: 24 * sy))
        path.addLine(to: CGPoint(x: 14 * sx, y: 24 * sy))
        path.addLine(to: CGPoint(x: 14 * sx, y: 28 * sy))
        path.addLine(to: CGPoint(x: 10 * sx, y: 28 * sy))
        path.addLine(to: CGPoint(x: 10 * sx, y: 24 * sy))
        path.addLine(to: CGPoint(x: 6 * sx, y: 24 * sy))
        path.addLine(to: CGPoint(x: 6 * sx, y: 21 * sy))
        path.addLine(to: CGPoint(x: 2 * sx, y: 21 * sy))
        path.addLine(to: CGPoint(x: 2 * sx, y: 9 * sy))
        path.addLine(to: CGPoint(x: 6 * sx, y: 9 * sy))
        path.closeSubpath()

        // Eye 1: M10 11v6h3v-6z
        let eye1 = CGRect(x: 10 * sx, y: 11 * sy, width: 3 * sx, height: 6 * sy)
        path.addRect(eye1)

        // Eye 2: M19 11v6h3v-6z
        let eye2 = CGRect(x: 19 * sx, y: 11 * sy, width: 3 * sx, height: 6 * sy)
        path.addRect(eye2)

        return path
    }
}

struct ProviderIconView: View {
    let providerName: String
    var size: CGFloat = 16

    init(providerName: String, size: CGFloat = 16) {
        self.providerName = providerName
        self.size = size
    }

    var body: some View {
        let key = providerName.lowercased()
        if key.contains("claude") {
            ClaudeIconShape()
                .fill(ProviderBrandColor.claude, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        } else if key.contains("codex") {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(ProviderBrandColor.codex)
                    .frame(width: size, height: size)
                Path { p in
                    let sx = size / 32.0
                    let sy = size / 32.0
                    // >
                    p.move(to: CGPoint(x: 7 * sx, y: 9 * sy))
                    p.addLine(to: CGPoint(x: 14 * sx, y: 16 * sy))
                    p.addLine(to: CGPoint(x: 7 * sx, y: 23 * sy))
                    // _
                    p.move(to: CGPoint(x: 17 * sx, y: 23 * sy))
                    p.addLine(to: CGPoint(x: 25 * sx, y: 23 * sy))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
        } else if key.contains("anti") || key.contains("agy") {
            Image(systemName: "atom")
                .resizable()
                .scaledToFit()
                .foregroundStyle(ProviderBrandColor.antigravity)
                .frame(width: size, height: size)
        } else if key.contains("hermes") {
            Image(systemName: "bolt.horizontal.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(ProviderBrandColor.hermes)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "cpu")
                .resizable()
                .scaledToFit()
                .foregroundStyle(HerdrTheme.subtext)
                .frame(width: size, height: size)
        }
    }
}
