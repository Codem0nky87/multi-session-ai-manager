import SwiftUI

@main
struct MultiSessionAIManagerApp: App {
    @State private var hostStore: HostStore
    @State private var tabStore: HostTabStore
    @State private var terminalSettings = TerminalSettings()
    @State private var tabs: HostTabsModel
    @State private var portForwarding: PortForwardingManager

    init() {
        let hosts = HostStore()
        _hostStore = State(initialValue: hosts)
        let openTabs = HostTabStore()
        _tabStore = State(initialValue: openTabs)
        let keyStore = KeyStore(backing: RealKeychain())
        let knownHosts = KnownHostsStore()
        _tabs = State(initialValue: HostTabsModel(
            hostStore: hosts,
            tabStore: openTabs,
            keyStore: keyStore,
            knownHosts: knownHosts
        ))
        _portForwarding = State(initialValue: PortForwardingManager(
            keyStore: keyStore,
            knownHosts: knownHosts
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
            .environment(portForwarding)
        }
    }
}
