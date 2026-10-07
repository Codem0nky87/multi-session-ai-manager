import SwiftUI
import UIKit

/// Shared chrome for the metrics-bar popovers.
///
/// The detail views are fixed-width with unbounded height, which on a short
/// landscape window (e.g. an ultra-wide iPad) grows taller than the popover
/// area and gets clipped. This caps the content to a fraction of the screen
/// height and lets anything longer scroll instead of overflowing.
enum MetricsPopoverMetrics {
    /// Fraction of the screen height a popover may occupy. Leaves room for the
    /// status bar, the metrics bar itself, and the popover arrow/margins.
    static let maxHeightFraction: CGFloat = 0.78
    static let minHeight: CGFloat = 240

    /// Height cap derived from the live screen, so a landscape ultra-wide gets
    /// a short cap and a portrait window a tall one. In any orientation the
    /// vertical extent is the shorter screen dimension.
    static var maxHeight: CGFloat {
        let vertical = min(UIScreen.main.bounds.height, UIScreen.main.bounds.width)
        return max(minHeight, vertical * maxHeightFraction)
    }
}

extension View {
    /// Wraps a metrics detail view in a width-fixed, screen-height-capped,
    /// scrollable popover body so long panels always fit on short windows.
    func metricsPopoverBody(width: CGFloat) -> some View {
        ScrollView(.vertical) {
            self
                .frame(width: width)
                .background(HerdrTheme.background)
        }
        .frame(width: width, maxHeight: MetricsPopoverMetrics.maxHeight)
        .background(HerdrTheme.background)
    }
}
