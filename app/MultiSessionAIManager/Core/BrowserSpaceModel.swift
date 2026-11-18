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

    /// - Parameter grace: how long a pane that is no longer found stays drawn.
    ///   Herdr repaints in pieces, and a page that vanished for one of them
    ///   would flicker. Short enough that a Herdr menu gets its space at once.
    init(hostID: UUID, defaults: UserDefaults = .standard, grace: Duration = .milliseconds(120)) {
        self.defaults = defaults
        self.key = "msam.browser-spaces.\(hostID.uuidString.lowercased())"
        self.grace = grace
    }

    /// Takes what the terminal shows now.
    func show(_ located: [BrowserSpaceRegion]) {
        for region in located {
            leaving.removeValue(forKey: region.id)?.cancel()
            if let index = regions.firstIndex(where: { $0.id == region.id }) {
                if regions[index] != region { regions[index] = region }
            } else {
                regions.append(region)
            }
        }
        let visible = Set(located.map(\.id))
        for region in regions where !visible.contains(region.id) && leaving[region.id] == nil {
            let id = region.id
            leaving[id] = Task { [weak self, grace] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled, let self else { return }
                self.leaving[id] = nil
                self.regions.removeAll { $0.id == id }
            }
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
