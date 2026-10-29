import Foundation

public enum HerdrWindowCommands {
    public static let pathPrefix: String = "PATH=\"$HOME/.local/bin:$PATH\"; export PATH"

    public static func makeSplitPaneCommand(direction: SplitDirection) -> String {
        "\(pathPrefix); herdr pane split --direction \(direction.rawValue) --focus"
    }

    public static func makeCreateTabCommand(label: String) -> String {
        "\(pathPrefix); herdr tab create --label \(POSIXShell.quote(label)) --focus"
    }

    public static func makeClosePaneCommand() -> String {
        "\(pathPrefix); herdr pane close"
    }

    public static func makeZoomPaneCommand() -> String {
        "\(pathPrefix); herdr pane zoom"
    }
}

@MainActor
public protocol AppActionHandling: Sendable {
    func dispatch(_ action: AppAction) async throws
}

@MainActor
public final class AppActionDispatcher: AppActionHandling {
    public enum ActionError: LocalizedError, Equatable {
        case hostNotConnected
        case tabNotFound(String)
        case hostNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .hostNotConnected:
                return "Host session is not connected."
            case .tabNotFound(let name):
                return "Host tab '\(name)' is not currently open."
            case .hostNotFound(let name):
                return "Host '\(name)' was not found."
            }
        }
    }

    private let tabStore: HostTabStore
    private let hostStore: HostStore
    private let getActiveSession: () -> HerdrHostSession?
    private let onOpenSheet: (AppSheetType) -> Void

    init(
        tabStore: HostTabStore,
        hostStore: HostStore,
        getActiveSession: @escaping () -> HerdrHostSession?,
        onOpenSheet: @escaping (AppSheetType) -> Void
    ) {
        self.tabStore = tabStore
        self.hostStore = hostStore
        self.getActiveSession = getActiveSession
        self.onOpenSheet = onOpenSheet
    }

    public func dispatch(_ action: AppAction) async throws {
        switch action {
        case .switchHostTab(let name):
            let match = tabStore.tabs.first { tab in
                let title = HostTabTitle.title(for: tab, hosts: hostStore.hosts)
                if title.localizedCaseInsensitiveContains(name) {
                    return true
                }
                if let host = hostStore.hosts.first(where: { $0.id == tab.hostID }),
                   host.name.localizedCaseInsensitiveContains(name) {
                    return true
                }
                if let session = tab.sessionName, session.localizedCaseInsensitiveContains(name) {
                    return true
                }
                return false
            }
            guard let targetTab = match else {
                throw ActionError.tabNotFound(name)
            }
            tabStore.select(targetTab.id)

        case .openHostTab(let hostName):
            let existing = tabStore.tabs.first { tab in
                let title = HostTabTitle.title(for: tab, hosts: hostStore.hosts)
                if title.localizedCaseInsensitiveContains(hostName) {
                    return true
                }
                if let host = hostStore.hosts.first(where: { $0.id == tab.hostID }),
                   host.name.localizedCaseInsensitiveContains(hostName) {
                    return true
                }
                return false
            }
            if let existing {
                tabStore.select(existing.id)
                return
            }

            guard let targetHost = hostStore.hosts.first(where: {
                $0.name.localizedCaseInsensitiveContains(hostName)
            }) else {
                throw ActionError.hostNotFound(hostName)
            }
            tabStore.open(hostID: targetHost.id, sessionName: nil)

        case .openAppSheet(let sheet):
            onOpenSheet(sheet)

        case .splitPane(let direction, let stagedCommand):
            guard let session = getActiveSession(), session.status == .live else {
                throw ActionError.hostNotConnected
            }
            let cmd = HerdrWindowCommands.makeSplitPaneCommand(direction: direction)
            _ = try await session.connection.service.run(cmd)
            if let stagedCommand, !stagedCommand.isEmpty {
                session.terminal.feedInputToPTY(Array(stagedCommand.utf8))
            }

        case .createHerdrTab(let label, let stagedCommand):
            guard let session = getActiveSession(), session.status == .live else {
                throw ActionError.hostNotConnected
            }
            let cmd = HerdrWindowCommands.makeCreateTabCommand(label: label)
            _ = try await session.connection.service.run(cmd)
            if let stagedCommand, !stagedCommand.isEmpty {
                session.terminal.feedInputToPTY(Array(stagedCommand.utf8))
            }

        case .closePane:
            guard let session = getActiveSession(), session.status == .live else {
                throw ActionError.hostNotConnected
            }
            let cmd = HerdrWindowCommands.makeClosePaneCommand()
            _ = try await session.connection.service.run(cmd)

        case .zoomPane:
            guard let session = getActiveSession(), session.status == .live else {
                throw ActionError.hostNotConnected
            }
            let cmd = HerdrWindowCommands.makeZoomPaneCommand()
            _ = try await session.connection.service.run(cmd)
        }
    }
}
