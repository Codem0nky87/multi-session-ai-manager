import Foundation
import Observation

/// The browser spaces of one host tab: which are on screen, their pages, and
/// the address each showed last.
@MainActor
@Observable
final class BrowserSpaceModel {
    static let savedLimit = 12

    /// The browser panes to draw now.
    private(set) var regions: [BrowserSpaceRegion] = []

    @ObservationIgnored private var pages: [String: HostBrowserPage] = [:]
    @ObservationIgnored private var leaving: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let grace: Duration
    @ObservationIgnored private let resizeHold: Duration
    /// Until when a pane that is not found is one the host has yet to redraw.
    @ObservationIgnored private var redrawExpectedUntil: ContinuousClock.Instant?

    /// - Parameters:
    ///   - grace: how long a pane that is no longer found stays drawn. Herdr
    ///     repaints in pieces, and a page that vanished for one of them would
    ///     flicker. Short enough that a Herdr menu gets its space at once.
    ///   - resizeHold: how long it stays after the terminal changed size. The
    ///     placeholder on screen is then cut off or too small until the host
    ///     has drawn it again, which takes a round trip: over a local network
    ///     0.1 to 0.25 seconds were measured, longer than `grace`.
    init(hostID: UUID, defaults: UserDefaults = .standard, grace: Duration = .milliseconds(120),
         resizeHold: Duration = .milliseconds(1500)) {
        self.defaults = defaults
        self.key = "msam.browser-spaces.\(hostID.uuidString.lowercased())"
        self.grace = grace
        self.resizeHold = resizeHold
    }

    /// Takes what the terminal shows now.
    func show(_ located: [BrowserSpaceRegion]) {
        for region in located {
            if let wasLeaving = leaving.removeValue(forKey: region.id) {
                wasLeaving.cancel()
                // The host has drawn it again: whatever goes missing from now
                // on is not the change of size any more.
                redrawExpectedUntil = nil
            }
            if let index = regions.firstIndex(where: { $0.id == region.id }) {
                if regions[index] != region { regions[index] = region }
            } else {
                regions.append(region)
            }
        }
        let visible = Set(located.map(\.id))
        for region in regions where !visible.contains(region.id) && leaving[region.id] == nil {
            drop(region.id, after: patience)
        }
    }

    /// The terminal has a new size, so the host is about to draw every pane
    /// again. Until it has, a browser stays where it was: dropping it takes the
    /// keyboard from the page or the address bar that raised it, the keyboard
    /// goes away, and the terminal changes size once more.
    ///
    /// - Parameter whileItHasTheKeyboard: the terminal itself is being typed
    ///   into. That follows a tap on Herdr, which may be what takes the space
    ///   off the screen, so the browser gets out of the way as fast as ever.
    func terminalResized(whileItHasTheKeyboard: Bool) {
        redrawExpectedUntil = whileItHasTheKeyboard ? nil : ContinuousClock.now + resizeHold
        // A pane already counted as missing is given the same time.
        for id in Array(leaving.keys) {
            leaving.removeValue(forKey: id)?.cancel()
            drop(id, after: patience)
        }
    }

    /// How long a pane that is not found now stays drawn.
    private var patience: Duration {
        guard let redrawExpectedUntil else { return grace }
        return max(grace, redrawExpectedUntil - ContinuousClock.now)
    }

    private func drop(_ id: String, after delay: Duration) {
        leaving[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.leaving[id] = nil
            self.regions.removeAll { $0.id == id }
        }
    }

    /// The page of a space, kept while its space is off screen.
    func page(for id: String) -> HostBrowserPage {
        if let page = pages[id] { return page }
        let page = HostBrowserPage()
        pages[id] = page
        return page
    }

    // MARK: Addresses, oldest first

    private var saved: [[String]] {
        (defaults.array(forKey: key) as? [[String]] ?? []).filter { $0.count == 2 }
    }

    /// The address a space showed last, also after a relaunch.
    func savedAddress(for id: String) -> String? {
        saved.last { $0[0] == id }?[1]
    }

    func remember(address: String, for id: String) {
        let entries = saved
        // Nothing to write when it is already the newest entry.
        if let newest = entries.last, newest == [id, address] { return }
        let updated = entries.filter { $0[0] != id } + [[id, address]]
        defaults.set(Array(updated.suffix(Self.savedLimit)), forKey: key)
    }
}
