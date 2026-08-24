import Foundation
import Observation

/// Shared state for modal text selection, so the app's top bar and the terminal
/// can act on one selection without the terminal having to hoist its cell
/// anchors out of the view.
///
/// The terminal owns the anchors (`selStart`/`selEnd`, in renderer cell
/// coordinates) and publishes only whether a selection exists; the top bar reads
/// that to enable Copy, and asks for a copy by bumping `copyRequest` rather than
/// reaching into the terminal.
@MainActor
@Observable
final class TerminalSelectionModel {
    /// Selection mode. While true the terminal disables scrollback panning, stops
    /// forwarding touches to the remote pane, and treats a plain drag as a
    /// selection -- see `TerminalTouchPolicy`.
    var isSelecting = false

    /// True once a drag has produced a range. Drives whether Copy is actionable.
    private(set) var hasSelection = false

    /// Bumped to ask the terminal to copy the current selection. A counter rather
    /// than a Bool so two copies in a row are two distinct events.
    private(set) var copyRequest = 0

    /// Called by the terminal as its anchors change.
    func setHasSelection(_ value: Bool) {
        guard hasSelection != value else { return }
        hasSelection = value
    }

    /// Called by the top bar's Copy button.
    func requestCopy() {
        guard hasSelection else { return }
        copyRequest &+= 1
    }

    /// Leave selection mode and forget any range. Called on copy, on cancel, and
    /// when the selected tab changes -- a tab must never be left unscrollable and
    /// deaf to the remote because it was abandoned mid-selection.
    func exit() {
        isSelecting = false
        hasSelection = false
    }
}
