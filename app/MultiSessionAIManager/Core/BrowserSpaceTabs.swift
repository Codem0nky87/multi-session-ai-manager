import Foundation
import Observation

/// One page of a browser space.
@MainActor
@Observable
final class BrowserSpaceTab: Identifiable {
    nonisolated let id = UUID()
    let page = HostBrowserPage()
    /// What the tab showed when the app last ran. It is opened when the tab is
    /// first shown, so a relaunch does not load every tab of every space.
    @ObservationIgnored let restored: String

    init(restored: String = "") {
        self.restored = restored
    }

    /// The address the tab is on, or will open when it is shown.
    var address: String {
        page.currentAddress.isEmpty ? restored : page.currentAddress
    }

    var label: String {
        Self.label(title: page.title, address: address)
    }

    /// A tab is named after its page, then after its site.
    nonisolated static func label(title: String, address: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let host = URL(string: address)?.host(), !host.isEmpty { return host }
        return "New Tab"
    }
}

/// The pages of one browser space. One of them is shown; "+" opens another.
/// Every tab keeps its own page, so going back to one shows it as it was left.
@MainActor
@Observable
final class BrowserSpaceTabs {
    /// Each tab is a web view of its own, and they all stay in memory.
    static let limit = 8

    private(set) var tabs: [BrowserSpaceTab]
    private(set) var selectedID: UUID
    /// Called after a tab was opened, closed or chosen, so it can be remembered.
    @ObservationIgnored var onChange: () -> Void = {}

    /// - Parameters:
    ///   - addresses: what each tab showed last, in order. None gives one empty tab.
    ///   - selected: which of them was shown.
    init(addresses: [String] = [], selected: Int = 0) {
        let restored = addresses.prefix(Self.limit).map { BrowserSpaceTab(restored: $0) }
        let tabs = restored.isEmpty ? [BrowserSpaceTab()] : restored
        self.tabs = tabs
        self.selectedID = (tabs.indices.contains(selected) ? tabs[selected] : tabs[0]).id
    }

    var selected: BrowserSpaceTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    var selectedIndex: Int {
        tabs.firstIndex { $0.id == selectedID } ?? 0
    }

    var canAdd: Bool {
        tabs.count < Self.limit
    }

    /// Opens an empty tab at the end and shows it. Nil at the limit.
    @discardableResult
    func add() -> BrowserSpaceTab? {
        guard canAdd else { return nil }
        let tab = BrowserSpaceTab()
        tabs.append(tab)
        selectedID = tab.id
        onChange()
        return tab
    }

    func select(_ id: UUID) {
        guard id != selectedID, tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        onChange()
    }

    /// Closes a tab. When it was the one shown, the tab that takes its place is
    /// shown, or the one before it. A browser always has a page: closing the
    /// only tab leaves an empty one.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index).page.stopLoading()
        if tabs.isEmpty { tabs = [BrowserSpaceTab()] }
        if id == selectedID { selectedID = tabs[min(index, tabs.count - 1)].id }
        onChange()
    }
}
