import Testing
@testable import MultiSessionAIManager

@Test func classifiesConnectFailures() {
    #expect(SSHFailure.classify(message: "Connection timed out") == .unreachable)
    #expect(SSHFailure.classify(message: "Connection refused") == .unreachable)
    #expect(SSHFailure.classify(message: "authentication failed") == .authRejected)
    #expect(SSHFailure.classify(message: "permission denied (publickey)") == .authRejected)
    #expect(SSHFailure.classify(message: "host key mismatch") == .hostKeyMismatch)
    #expect(SSHFailure.classify(message: "something else") == .unknown)
}
@Test func classifiesHostKeyChangeVariants() {
    #expect(SSHFailure.classify(message: "Host key verification failed") == .hostKeyMismatch)
    #expect(SSHFailure.classify(message: "REMOTE HOST IDENTIFICATION HAS CHANGED") == .hostKeyMismatch)
    #expect(SSHFailure.classify(message: "server host key changed") == .hostKeyMismatch)
    #expect(SSHFailure.classify(message: "host key mismatch") == .hostKeyMismatch) // still works
}
@Test func userMessageIsActionable() {
    #expect(SSHFailure.unreachable.userMessage.contains("WARP"))
}
