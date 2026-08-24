import Testing
@testable import MultiSessionAIManager

private final class OwnedSSHClient {}

@Suite struct SSHConnectionOwnershipTests {
    @Test func newerAttemptRejectsOlderLateClientWithoutReplacingIt() {
        let ownership = SSHConnectionOwnership<OwnedSSHClient>()
        let firstAttempt = ownership.beginConnect()
        let secondAttempt = ownership.beginConnect()
        let firstClient = OwnedSSHClient()
        let secondClient = OwnedSSHClient()

        let stale = ownership.install(firstClient, for: firstAttempt)
        #expect(stale.staleClient === firstClient)
        #expect(ownership.current() == nil)

        let accepted = ownership.install(secondClient, for: secondAttempt)
        #expect(accepted.staleClient == nil)
        #expect(accepted.replacedClient == nil)
        #expect(ownership.current() === secondClient)
    }

    @Test func retireInvalidatesAnInFlightAttempt() {
        let ownership = SSHConnectionOwnership<OwnedSSHClient>()
        let attempt = ownership.beginConnect()
        let lateClient = OwnedSSHClient()

        #expect(ownership.retire() == nil)
        let result = ownership.install(lateClient, for: attempt)

        #expect(result.staleClient === lateClient)
        #expect(ownership.current() == nil)
    }
}
