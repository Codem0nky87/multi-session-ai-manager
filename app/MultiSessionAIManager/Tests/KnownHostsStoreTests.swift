import Testing
import Foundation
@testable import MultiSessionAIManager

@Test func tofuPinsAndDetectsMismatch() {
    let suite = "msam.knownhosts.\(#function)"
    UserDefaults().removePersistentDomain(forName: suite)
    let store = KnownHostsStore(defaults: UserDefaults(suiteName: suite)!)
    #expect(store.verify(host: "mac", fingerprint: "AAchild") == .trustedNew)
    store.pin(host: "mac", fingerprint: "AAchild")
    #expect(store.verify(host: "mac", fingerprint: "AAchild") == .match)
    #expect(store.verify(host: "mac", fingerprint: "EVIL") == .mismatch)
}

@Test func hostKnownHostsKeySeparatesNonDefaultPorts() {
    let defaultSSH = Host(name: "Mac",
                          address: "192.0.2.10",
                          port: 22,
                          username: "alice",
                          keyID: "key",
                          defaultWorkdir: "")
    let hermesSSH = Host(name: "Hermes",
                         address: "192.0.2.10",
                         port: 2222,
                         username: "hermes",
                         keyID: "key",
                         defaultWorkdir: "")

    #expect(defaultSSH.knownHostsKey == "192.0.2.10")
    #expect(hermesSSH.knownHostsKey == "[192.0.2.10]:2222")
    #expect(defaultSSH.knownHostsKey != hermesSSH.knownHostsKey)
}
