import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HostTabStripTests {
    private func host(_ name: String) -> Host {
        Host(
            name: name,
            address: "10.0.0.8",
            username: "owner",
            keyID: "unused-in-this-test",
            defaultWorkdir: "/srv"
        )
    }

    @Test func tabUsesTheHostName() {
        let h = host("mac")
        let tab = HostTab(hostID: h.id, sessionName: nil)
        #expect(HostTabTitle.title(for: tab, hosts: [h]) == "mac")
    }

    @Test func namedSessionIsAppendedToTheHostName() {
        let h = host("mac")
        let tab = HostTab(hostID: h.id, sessionName: "build")
        #expect(HostTabTitle.title(for: tab, hosts: [h]) == "mac:build")
    }

    @Test func aTabWhoseHostVanishedStillRendersSomething() {
        let tab = HostTab(hostID: UUID(), sessionName: nil)
        #expect(HostTabTitle.title(for: tab, hosts: []) == "unknown host")
    }
}
