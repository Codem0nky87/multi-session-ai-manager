import SwiftUI

@main
struct MultiSessionAIManagerApp: App {
    @State private var hostStore: HostStore
    @State private var tabStore: HostTabStore
    @State private var terminalSettings = TerminalSettings()
    @State private var tabs: HostTabsModel

    init() {
        let hosts = HostStore()
        _hostStore = State(initialValue: hosts)
        let openTabs = HostTabStore()
        _tabStore = State(initialValue: openTabs)
        _tabs = State(initialValue: HostTabsModel(
            hostStore: hosts,
            tabStore: openTabs,
            keyStore: KeyStore(backing: RealKeychain()),
            knownHosts: KnownHostsStore()
        ))
    }

    var body: some Scene {
        WindowGroup("Herdr") {
            RootView(
                hostStore: hostStore,
                tabStore: tabStore,
                tabs: tabs,
                terminalSettings: terminalSettings
            )
        }
    }
}
