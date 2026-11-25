import Foundation
import Testing
@testable import MultiSessionAIManager

/// A password saved for one host and typed into its terminal on request.
@MainActor
@Suite struct HostTerminalPasswordTests {
    private let host = UUID()
    private let other = UUID()

    private final class Typed: @unchecked Sendable {
        var bytes: [[UInt8]] = []
    }

    @Test func theSavedPasswordIsTypedExactlyAndNothingAfterIt() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        #expect(key.save("s3cr3t pä$$", for: host) == nil)

        let typed = Typed()
        let outcome = await key.type(for: host, named: "Build host") { typed.bytes.append($0) }

        #expect(outcome == .typed)
        // No Return: whoever tapped presses it, having seen where the cursor is.
        #expect(typed.bytes == [Array("s3cr3t pä$$".utf8)])
    }

    @Test func theDeviceOwnerIsAskedEveryTimeAndToldWhichHostItIsFor() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        _ = key.save("one", for: host)

        _ = await key.type(for: host, named: "Build host") { _ in }
        _ = await key.type(for: host, named: "Build host") { _ in }

        #expect(store.reasons.count == 2)
        #expect(store.reasons.allSatisfy { $0.contains("Build host") })
    }

    @Test func nothingIsTypedWhenTheOwnerCancels() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        _ = key.save("one", for: host)
        store.nextReveal = .cancelled

        let typed = Typed()
        let outcome = await key.type(for: host, named: "Build host") { typed.bytes.append($0) }

        #expect(outcome == .cancelled)
        #expect(typed.bytes.isEmpty)
    }

    @Test func nothingIsTypedWhenTheOwnerIsRefusedAndTheReasonIsSaid() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        _ = key.save("one", for: host)
        store.nextReveal = .refused

        let typed = Typed()
        let outcome = await key.type(for: host, named: "Build host") { typed.bytes.append($0) }

        #expect(typed.bytes.isEmpty)
        guard case .failed(let text) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(!text.isEmpty)
        #expect(!text.contains("one"), "a failure never repeats the password")
    }

    /// One host's password is never typed into another host's terminal.
    @Test func aPasswordSavedForOneHostIsNotTypedForAnother() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        _ = key.save("one", for: host)

        #expect(key.isSaved(for: host))
        #expect(!key.isSaved(for: other))

        let typed = Typed()
        let outcome = await key.type(for: other, named: "Other host") { typed.bytes.append($0) }

        #expect(typed.bytes.isEmpty)
        #expect(outcome == .failed("No password is saved for Other host."))
        // And nobody was asked for a face or a passcode for nothing.
        #expect(store.reasons.isEmpty)
    }

    @Test func anEmptyPasswordIsNotSaved() {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)

        #expect(key.save("", for: host) != nil)
        #expect(!key.isSaved(for: host))
    }

    @Test func aPasswordThatCannotBeSavedSaysSoAndIsNotCountedAsSaved() {
        let store = InMemoryHostTerminalPasswords()
        store.savingFails = true
        let key = HostTerminalPasswordKey(store: store)

        let failure = key.save("one", for: host)

        #expect(failure?.contains("passcode") == true)
        #expect(!key.isSaved(for: host))
    }

    @Test func savingAgainReplacesAndForgettingRemoves() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        _ = key.save("one", for: host)
        _ = key.save("two", for: host)

        let typed = Typed()
        _ = await key.type(for: host, named: "Build host") { typed.bytes.append($0) }
        #expect(typed.bytes == [Array("two".utf8)])

        key.forget(for: host)
        #expect(!key.isSaved(for: host))
        #expect(!store.hasPassword(for: host))
    }

    /// A second tap while the first question is still on screen asks nothing more
    /// and types nothing twice.
    @Test func aSecondTapWhileTheOwnerIsBeingAskedDoesNothing() async {
        let store = InMemoryHostTerminalPasswords()
        let key = HostTerminalPasswordKey(store: store)
        _ = key.save("one", for: host)
        let gate = store.holdNextReveal()

        let typed = Typed()
        let first = Task { await key.type(for: host, named: "Build host") { typed.bytes.append($0) } }
        // Let the first tap reach the question.
        for _ in 0..<200 where store.reasons.isEmpty { await Task.yield() }
        #expect(key.isAsking)

        let second = await key.type(for: host, named: "Build host") { typed.bytes.append($0) }
        #expect(second == .busy)

        gate.open()
        #expect(await first.value == .typed)
        #expect(typed.bytes.count == 1)
        #expect(store.reasons.count == 1)
        #expect(!key.isAsking)
    }
}
