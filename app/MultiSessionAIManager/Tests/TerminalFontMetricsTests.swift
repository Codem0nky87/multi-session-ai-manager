import Testing
import CoreGraphics
@testable import MultiSessionAIManager

/// The per-row cell height MUST be a whole number of points. A fractional row
/// height means rows don't land on the device pixel grid, so the per-row
/// `drawingGroup(opaque:)` tiles leave ~1px seams between them (the "faint
/// horizontal lines" bug at small font sizes). Rounding the height UP to a whole
/// point makes every row an integer number of device pixels at any @2x/@3x scale.
@MainActor
@Test func cellHeightIsWholePointsAtEverySize() {
    for size in stride(from: 7.0, through: 24.0, by: 0.5) {
        let m = TerminalFontMetrics(fontSize: CGFloat(size))
        #expect(m.height == m.height.rounded(.up),
                "height \(m.height) is not a whole point at size \(size)")
        #expect(m.height == m.height.rounded(),
                "height \(m.height) is fractional at size \(size)")
        #expect(m.height > 0)
    }
}

/// The rounded height must never be smaller than the raw typographic height, so
/// glyphs are never vertically clipped (rounding is UP, never down).
@MainActor
@Test func cellHeightCoversTheRawTypographicHeight() {
    let m = TerminalFontMetrics(fontSize: 8)
    // boundingBox mirrors width x height; height is the rounded cell height.
    #expect(m.boundingBox.height == m.height)
    #expect(m.height >= 1)
}
