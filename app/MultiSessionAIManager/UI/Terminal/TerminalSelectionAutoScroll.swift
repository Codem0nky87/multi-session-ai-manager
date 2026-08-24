import CoreGraphics

/// Edge auto-scroll for a selection drag.
///
/// Selection mode disables scrollback panning (see `TerminalTouchPolicy`), so a
/// drag can otherwise only select what is already on screen -- dragging past the
/// bottom edge does nothing. This reveals more rows while the drag is held near
/// an edge, which is the behaviour every text selector has.
///
/// Pure geometry so it can be tested without a view: the caller feeds the drag's
/// y in viewport coordinates and applies the returned delta to its scroll offset.
enum TerminalSelectionAutoScroll {
    /// How close to an edge the drag must be before scrolling starts.
    static let edgeZone: CGFloat = 40

    /// Points per tick at the very edge. Applied per display tick, so this is a
    /// rate, not a distance.
    static let maximumPointsPerTick: CGFloat = 14

    /// Scroll delta for a drag at `y` within a viewport of `viewportHeight`.
    /// Positive scrolls toward the end of the content (drag near the bottom),
    /// negative toward the start. Zero away from both edges.
    static func velocity(atY y: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }

        // A short pane must not let the two zones overlap into contradictory
        // answers, so each zone gets at most half the viewport.
        let zone = min(edgeZone, viewportHeight / 2)
        guard zone > 0 else { return 0 }

        if y <= zone {
            // ramps from 0 at the zone's inner edge to full speed at (or past) 0
            let depth = min(zone - y, zone)
            return -maximumPointsPerTick * (depth / zone)
        }
        let bottomThreshold = viewportHeight - zone
        if y >= bottomThreshold {
            let depth = min(y - bottomThreshold, zone)
            return maximumPointsPerTick * (depth / zone)
        }
        return 0
    }

    /// Apply `delta` to `current`, held inside `0...maximum`. `maximum` is the
    /// furthest valid offset (content height minus viewport height); it is
    /// negative or zero when the content is shorter than the viewport, in which
    /// case there is nothing to scroll.
    static func clampedOffset(current: CGFloat, delta: CGFloat, maximum: CGFloat) -> CGFloat {
        guard maximum > 0 else { return 0 }
        return min(max(current + delta, 0), maximum)
    }
}
