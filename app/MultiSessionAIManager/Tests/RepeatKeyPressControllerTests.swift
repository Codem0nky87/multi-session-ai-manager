import Testing
@testable import MultiSessionAIManager

@MainActor
@Test func repeatKeyPressSendsImmediatelyAndStopsCleanly() async throws {
    let repeater = RepeatKeyPressController(
        initialDelayNanoseconds: 10_000_000,
        repeatIntervalNanoseconds: 10_000_000
    )
    var sends = 0

    repeater.start { sends += 1 }
    try await Task.sleep(nanoseconds: 35_000_000)
    repeater.stop()
    let stoppedCount = sends
    try await Task.sleep(nanoseconds: 25_000_000)

    #expect(stoppedCount >= 3)
    #expect(sends == stoppedCount)
}
