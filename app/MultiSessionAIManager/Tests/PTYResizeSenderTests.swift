import Foundation
import Testing
@testable import MultiSessionAIManager

/// The text size shown in Settings was sometimes not the one the host was laid out
/// for. Each resize left the app in its own unordered task, so of two sizes computed
/// milliseconds apart the older could arrive last and stay in force.
@Suite struct PTYResizeSenderTests {

    @Test func sizesReachTheRemoteInOrderAndEndOnTheNewest() async throws {
        let remote = RemotePTY()
        let sender = PTYResizeSender(opened: size(80, 24)) { try await remote.changeSize($0) }

        await remote.hold()
        sender.request(cols: 100, rows: 30)
        try await waitUntil { await remote.received.count == 1 }
        // Both arrive while the first is still on its way: only the last matters.
        sender.request(cols: 110, rows: 30)
        sender.request(cols: 120, rows: 40)
        await remote.release()
        try await waitUntil { sender.isIdle }

        #expect(await remote.received == [size(100, 30), size(120, 40)])
    }

    @Test func aBurstOfSizesNeverLeavesAnOlderOneInForce() async throws {
        let remote = RemotePTY(jitter: true)
        let sender = PTYResizeSender(opened: size(80, 24)) { try await remote.changeSize($0) }

        // A pinch: a new size on every frame, each a column wider than the last.
        for cols in 81...280 {
            sender.request(cols: cols, rows: 50)
            if cols % 7 == 0 { await Task.yield() }
        }
        try await waitUntil { sender.isIdle }

        let received = await remote.received
        #expect(received.last == size(280, 50), "the newest size is the one in force")
        #expect(received.map(\.cols) == received.map(\.cols).sorted(), "never out of order")
        #expect(received.count < 200, "a burst collapses instead of sending every step")
    }

    @Test func aSizeTheRemoteAlreadyHasIsNotSentAgain() async throws {
        let remote = RemotePTY()
        let sender = PTYResizeSender(opened: size(80, 24)) { try await remote.changeSize($0) }

        sender.request(cols: 80, rows: 24)
        try await waitUntil { sender.isIdle }
        #expect(await remote.received.isEmpty, "the PTY was opened at this size")

        sender.request(cols: 90, rows: 24)
        try await waitUntil { sender.isIdle }
        sender.request(cols: 90, rows: 24)
        try await waitUntil { sender.isIdle }
        #expect(await remote.received == [size(90, 24)])
    }

    @Test func aChannelThatFailsStopsTheSenderAndALaterRequestTriesAgain() async throws {
        let remote = RemotePTY()
        let sender = PTYResizeSender(opened: size(80, 24)) { try await remote.changeSize($0) }

        await remote.fail(true)
        sender.request(cols: 100, rows: 30)
        try await waitUntil { sender.isIdle }
        #expect(await remote.received.isEmpty)

        await remote.fail(false)
        sender.request(cols: 100, rows: 30)
        try await waitUntil { sender.isIdle }
        #expect(await remote.received == [size(100, 30)], "never delivered, so it is sent")
    }

    private func size(_ cols: Int, _ rows: Int) -> TerminalGridSize {
        TerminalGridSize(cols: cols, rows: rows)
    }

    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the sender")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// The host end of the PTY: records each window-change it is given.
private actor RemotePTY {
    private(set) var received: [TerminalGridSize] = []
    private let jitter: Bool
    private var holding = false
    private var held: CheckedContinuation<Void, Never>?
    private var failing = false

    init(jitter: Bool = false) {
        self.jitter = jitter
    }

    func hold() { holding = true }

    func release() {
        holding = false
        held?.resume()
        held = nil
    }

    func fail(_ failing: Bool) { self.failing = failing }

    func changeSize(_ size: TerminalGridSize) async throws {
        if failing { throw SSHTransportError.notConnected }
        if jitter, size.cols % 3 == 0 {
            // A slower round trip for some: the old code let later sizes overtake these.
            try await Task.sleep(for: .milliseconds(1))
        }
        received.append(size)
        if holding {
            await withCheckedContinuation { held = $0 }
        }
    }
}
