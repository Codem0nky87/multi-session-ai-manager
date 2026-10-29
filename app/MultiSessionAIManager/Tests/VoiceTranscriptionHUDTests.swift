import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct VoiceTranscriptionHUDTests {

    @Test func shouldDisplayHUDOnlyWhenActive() {
        #expect(!VoiceTranscriptionHUD.shouldDisplay(for: .idle))
        #expect(!VoiceTranscriptionHUD.shouldDisplay(for: .requestingPermissions))
        #expect(!VoiceTranscriptionHUD.shouldDisplay(for: .error("mic denied")))
        #expect(VoiceTranscriptionHUD.shouldDisplay(for: .listening(liveText: "", audioLevel: 0.0)))
        #expect(VoiceTranscriptionHUD.shouldDisplay(for: .listening(liveText: "claude help", audioLevel: 0.8)))
        #expect(VoiceTranscriptionHUD.shouldDisplay(for: .processing))
    }

    @Test func displayTextFormatting() {
        #expect(VoiceTranscriptionHUD.displayText(for: .listening(liveText: "", audioLevel: 0.0)) == "Listening…")
        #expect(VoiceTranscriptionHUD.displayText(for: .listening(liveText: "   ", audioLevel: 0.0)) == "Listening…")
        #expect(VoiceTranscriptionHUD.displayText(for: .listening(liveText: "codex --yolo", audioLevel: 0.4)) == "codex --yolo")
        #expect(VoiceTranscriptionHUD.displayText(for: .processing) == "Inserting…")
    }

    @Test func barHeightCalculationsStayWithinBounds() {
        for barIndex in 0..<4 {
            let heightMin = VoiceTranscriptionHUD.barHeight(forIndex: barIndex, level: 0.0)
            let heightMid = VoiceTranscriptionHUD.barHeight(forIndex: barIndex, level: 0.5)
            let heightMax = VoiceTranscriptionHUD.barHeight(forIndex: barIndex, level: 1.0)

            #expect(heightMin >= 4.0 && heightMin <= 8.0)
            #expect(heightMid >= heightMin)
            #expect(heightMax >= heightMid && heightMax <= 24.0)
        }
        #expect(VoiceTranscriptionHUD.barHeight(forIndex: 0, level: Float.nan) == 4.0)
        #expect(VoiceTranscriptionHUD.barHeight(forIndex: 0, level: Float.infinity) == 4.0)
    }
}
