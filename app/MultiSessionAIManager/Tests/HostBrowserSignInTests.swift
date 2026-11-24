import Foundation
import Testing
@testable import MultiSessionAIManager

/// What the browser does when a site wants proof of who is asking.
@Suite struct HostBrowserChallengeTests {
    @Test func aSiteThatWantsANameAndPasswordIsAskedAboutEachTime() {
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodNTLM, isProxy: false, failures: 0) == .ask(.windows))
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodHTTPDigest, isProxy: false, failures: 0) == .ask(.digest))
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodHTTPBasic, isProxy: false, failures: 0) == .ask(.basic))
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodDefault, isProxy: false, failures: 0) == .ask(.basic))
        // A password that was turned down is asked for again, by the user.
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodNTLM, isProxy: false, failures: 3) == .ask(.windows))
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodHTTPBasic, isProxy: false, failures: 1) == .ask(.basic))
    }

    @Test func kerberosIsPassedOverSoTheWindowsSignInComesUp() {
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodNegotiate, isProxy: false, failures: 0) == .tryTheNextOffer)
    }

    @Test func aCertificateIsLeftToTheSystem() {
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodServerTrust, isProxy: false, failures: 0) == .leaveAlone)
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodServerTrust, isProxy: false, failures: 2) == .leaveAlone)
    }

    @Test func theAppsOwnProxyIsNotTheUsersToAnswerFor() {
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodHTTPBasic, isProxy: true, failures: 0) == .leaveAlone)
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodNTLM, isProxy: true, failures: 0) == .leaveAlone)
    }

    /// Left to itself after a refusal, the system sends the refused answer
    /// again without end, which locks a Windows account out.
    @Test func nothingIsTriedAgainUnaskedOnceASiteHasSaidNo() {
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodNegotiate, isProxy: false, failures: 1) == .giveUp)
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodClientCertificate, isProxy: false, failures: 1) == .giveUp)
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodHTTPBasic, isProxy: true, failures: 1) == .giveUp)
        #expect(HostBrowserChallenge.of(method: "something new", isProxy: false, failures: 4) == .giveUp)
        // Before any refusal there is nothing to repeat.
        #expect(HostBrowserChallenge.of(method: NSURLAuthenticationMethodClientCertificate, isProxy: false, failures: 0) == .leaveAlone)
        #expect(HostBrowserChallenge.of(method: "something new", isProxy: false, failures: 0) == .leaveAlone)
    }
}

@Suite struct HostBrowserSignInRequestTests {
    private func request(host: String = "console.internal.example", port: Int, usesTLS: Bool,
                         kind: HostBrowserSignInRequest.Kind) -> HostBrowserSignInRequest {
        HostBrowserSignInRequest(id: 1, host: host, port: port, usesTLS: usesTLS, kind: kind)
    }

    @Test func theSiteIsNamedAsItsAddressNamesIt() {
        #expect(request(port: 443, usesTLS: true, kind: .windows).site == "console.internal.example")
        #expect(request(port: 80, usesTLS: false, kind: .windows).site == "console.internal.example")
        #expect(request(port: 8443, usesTLS: true, kind: .windows).site == "console.internal.example:8443")
        // The usual port of the other scheme is not the usual one here.
        #expect(request(port: 80, usesTLS: true, kind: .windows).site == "console.internal.example:80")
        #expect(request(host: "192.0.2.30", port: 443, usesTLS: true, kind: .windows).title == "Sign in to 192.0.2.30")
    }

    @Test func aWindowsSignInSaysHowToWriteADomainAccount() {
        let asked = request(port: 443, usesTLS: true, kind: .windows)
        #expect(asked.message == "This site asks for a Windows account. Write a domain account as DOMAIN\\name.")
        #expect(!asked.isSentUnprotected)
    }

    @Test func onlyAPasswordThatWouldTravelReadableIsWarnedAbout() {
        let plain = request(port: 80, usesTLS: false, kind: .basic)
        #expect(plain.isSentUnprotected)
        #expect(plain.message == "This site asks for a user name and password. It does not use HTTPS, so the password is sent without encryption.")

        let encrypted = request(port: 443, usesTLS: true, kind: .basic)
        #expect(!encrypted.isSentUnprotected)
        #expect(encrypted.message == "This site asks for a user name and password.")

        // These two answer a challenge and never send the password itself.
        #expect(!request(port: 80, usesTLS: false, kind: .digest).isSentUnprotected)
        #expect(!request(port: 80, usesTLS: false, kind: .windows).isSentUnprotected)
    }
}

@Suite @MainActor struct HostBrowserSignInsTests {
    /// What the sites were told, in the order they were told it.
    @MainActor private final class Told {
        var answers: [String] = []

        func site(_ name: String) -> @MainActor @Sendable (HostBrowserSignInReply) -> Void {
            { [self] reply in
                switch reply {
                case .credentials(let user, let password): answers.append("\(name): \(user) / \(password)")
                case .nothing: answers.append("\(name): nothing")
                }
            }
        }
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func nothingIsShownUntilASiteAsks() {
        #expect(HostBrowserSignIns().current == nil)
    }

    @Test func theAnswerGoesToTheSiteThatIsShownAndTheNextOneIsShownAfterIt() {
        let told = Told()
        var signIns = HostBrowserSignIns()
        signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows, reply: told.site("console"))
        signIns.ask(host: "files", port: 80, usesTLS: false, kind: .basic, reply: told.site("files"))

        #expect(signIns.current?.site == "console")
        #expect(signIns.current?.kind == .windows)

        signIns.answer(.credentials(user: "CORP\\operator", password: "first"))
        #expect(told.answers == ["console: CORP\\operator / first"])
        #expect(signIns.current?.site == "files")
        #expect(signIns.current?.isSentUnprotected == true)

        signIns.answer(.nothing)
        #expect(told.answers == ["console: CORP\\operator / first", "files: nothing"])
        #expect(signIns.current == nil)

        // With nothing shown there is nothing to answer.
        signIns.answer(.credentials(user: "late", password: "late"))
        #expect(told.answers.count == 2)
    }

    @Test func everyQuestionIsItsOwn() {
        var signIns = HostBrowserSignIns()
        signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows) { _ in }
        let first = signIns.current?.id
        signIns.answer(.nothing)
        signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows) { _ in }
        #expect(signIns.current?.id != first)
    }

    @Test func aRefusedSignInSaysSoAndKeepsTheNameThatWasTried() {
        var signIns = HostBrowserSignIns()
        signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows, failures: 1, user: "CORP\\operator") { _ in }
        #expect(signIns.current?.wasRefused == true)
        #expect(signIns.current?.user == "CORP\\operator")
    }

    @Test func aFirstQuestionSuggestsNoName() {
        var signIns = HostBrowserSignIns()
        // What the system proposes for a first try is not something the user chose here.
        signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows, failures: 0, user: "someone") { _ in }
        #expect(signIns.current?.wasRefused == false)
        #expect(signIns.current?.user == "")
    }

    @Test func leavingThePageAnswersEverySiteWithNothing() {
        let told = Told()
        var signIns = HostBrowserSignIns()
        signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows, reply: told.site("console"))
        signIns.ask(host: "files", port: 443, usesTLS: true, kind: .basic, reply: told.site("files"))

        signIns.abandonAll()

        #expect(told.answers == ["console: nothing", "files: nothing"])
        #expect(signIns.current == nil)
    }

    @Test func aQuestionIsAnsweredOnce() {
        let told = Told()
        let question = HostBrowserSignInQuestion(
            request: HostBrowserSignInRequest(id: 1, host: "console", port: 443, usesTLS: true, kind: .windows),
            reply: told.site("console"))
        question.answer(.credentials(user: "operator", password: "first"))
        question.answer(.nothing)
        #expect(told.answers == ["console: operator / first"])
    }

    /// WebKit raises an exception for a challenge that is let go unanswered.
    @Test func aQuestionThatIsDroppedUnansweredStillAnswers() async {
        let told = Told()
        do {
            var signIns = HostBrowserSignIns()
            signIns.ask(host: "console", port: 443, usesTLS: true, kind: .windows, reply: told.site("console"))
            signIns.ask(host: "files", port: 443, usesTLS: true, kind: .basic, reply: told.site("files"))
            signIns.answer(.credentials(user: "operator", password: "first"))
        }
        await eventually("the dropped question's answer") { told.answers.count == 2 }
        #expect(told.answers == ["console: operator / first", "files: nothing"])
    }
}

/// The site the sign-in tests are held against is only worth something if it
/// checks a password the way a Windows server does.
@Suite struct SignInTestSiteTests {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func itsDigestIsTheOneWindowsKeepsPasswordsAs() {
        // RFC 1320, appendix A.5.
        #expect(hex(SignInTestSite.md4(Data())) == "31d6cfe0d16ae931b73c59d7e0c089c0")
        #expect(hex(SignInTestSite.md4(Data("abc".utf8))) == "a448017aaf21d8525fc10ae87aa6729d")
        #expect(hex(SignInTestSite.md4(Data("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8)))
                == "e33b4ddc9c38f2199c3e7b164fcc0536")
    }

    @Test func itsSecretForAUserIsTheOneInMicrosoftsWorkedExample() {
        // [MS-NLMP] 4.2.4.1.1: user "User", domain "Domain", password "Password".
        #expect(hex(SignInTestSite.secret(user: "User", domain: "Domain", password: "Password")) == "0c868a403bfd7a93a3001ef22ef02e3f")
    }
}
