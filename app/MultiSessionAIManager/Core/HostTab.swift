import Foundation
import Observation

/// One open host tab: a host plus an optional named Herdr session.
struct HostTab: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var hostID: UUID
    var sessionName: String?
}

/// Persists the open host tabs and which one is selected, so a relaunch
/// reattaches to the same set of remote Herdr sessions.
@MainActor
@Observable
final class HostTabStore {
    private let defaults: UserDefaults
    private let tabsKey = "msam.hostTabs"
    private let selectionKey = "msam.hostTabs.selected"

    private(set) var tabs: [HostTab] = []
    private(set) var selectedTabID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: tabsKey),
           let decoded = try? JSONDecoder().decode([HostTab].self, from: data) {
            tabs = decoded
        }
        if let raw = defaults.string(forKey: selectionKey), let id = UUID(uuidString: raw),
           tabs.contains(where: { $0.id == id }) {
            selectedTabID = id
        } else {
            selectedTabID = tabs.first?.id
        }
    }

    @discardableResult
    func open(hostID: UUID, sessionName: String?) -> HostTab {
        let trimmed = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tab = HostTab(
            hostID: hostID,
            sessionName: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )
        tabs.append(tab)
        selectedTabID = tab.id
        save()
        return tab
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            let neighbour = min(index, tabs.count - 1)
            selectedTabID = tabs.isEmpty ? nil : tabs[neighbour].id
        }
        save()
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        save()
    }

    /// Drop tabs whose host no longer exists, so a deleted host cannot strand a
    /// permanently unopenable tab.
    func prune(existingHostIDs: Set<UUID>) {
        let survivors = tabs.filter { existingHostIDs.contains($0.hostID) }
        guard survivors.count != tabs.count else { return }
        tabs = survivors
        if let selected = selectedTabID, !tabs.contains(where: { $0.id == selected }) {
            selectedTabID = tabs.first?.id
        } else if selectedTabID == nil {
            selectedTabID = tabs.first?.id
        }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(tabs), forKey: tabsKey)
        defaults.set(selectedTabID?.uuidString, forKey: selectionKey)
    }
}
