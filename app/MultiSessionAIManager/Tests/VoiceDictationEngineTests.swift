import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct VoiceDictationEngineTests {

    @Test func voiceDictationStateEquality() {
        #expect(VoiceDictationState.idle == VoiceDictationState.idle)
        #expect(VoiceDictationState.requestingPermissions == VoiceDictationState.requestingPermissions)
        #expect(VoiceDictationState.processing == VoiceDictationState.processing)
        #expect(VoiceDictationState.error("denied") == VoiceDictationState.error("denied"))
        #expect(VoiceDictationState.error("denied") != VoiceDictationState.error("failed"))
        #expect(VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5) ==
                VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5))
        #expect(VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5) !=
                VoiceDictationState.listening(liveText: "world", audioLevel: 0.5))
        #expect(VoiceDictationState.listening(liveText: "hello", audioLevel: 0.5) !=
                VoiceDictationState.listening(liveText: "hello", audioLevel: 0.8))
    }

    @Test func cleanTranscriptionTextTrimsAndRejectsEmpty() {
        #expect(VoiceDictationEngine.cleanTranscriptionText("   hello world   ") == "hello world")
        #expect(VoiceDictationEngine.cleanTranscriptionText("\n\n  \t") == nil)
        #expect(VoiceDictationEngine.cleanTranscriptionText("") == nil)
        #expect(VoiceDictationEngine.cleanTranscriptionText("ls -la") == "ls -la")
    }

    @Test func normalizeAudioLevelClampsBetweenZeroAndOne() {
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: -1.0) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 0.0) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 0.5) == 0.5)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 1.0) == 1.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: 2.5) == 1.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: Float.nan) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: Float.infinity) == 0.0)
        #expect(VoiceDictationEngine.normalizeAudioLevel(rms: -Float.infinity) == 0.0)
    }

    @Test func convertTextToTerminalBytesPreservesUTF8() {
        let text = "claude --dangerously-skip-permissions"
        let bytes = VoiceDictationEngine.convertTextToTerminalBytes(text)
        #expect(bytes == Array(text.utf8))
    }

    @MainActor
    @Test func engineStateTransitionsWithMockService() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = true
        mock.transcribedResult = "git status"

        let engine = VoiceDictationEngine(service: mock)
        #expect(engine.state == .idle)

        await engine.startRecording()
        #expect(engine.state == .listening(liveText: "", audioLevel: 0.0))

        mock.simulatePartialText("git stat")
        #expect(engine.state == .listening(liveText: "git stat", audioLevel: 0.0))

        mock.simulateAudioLevel(0.75)
        #expect(engine.state == .listening(liveText: "git stat", audioLevel: 0.75))

        let result = await engine.stopRecording()
        #expect(result == "git status")
        #expect(engine.state == .idle)
    }

    @MainActor
    @Test func engineHandlesPermissionDenied() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = false

        let engine = VoiceDictationEngine(service: mock)
        await engine.startRecording()

        if case .error(let message) = engine.state {
            #expect(message.contains("permission") || message.contains("Permission"))
        } else {
            Issue.record("Expected .error state when permission denied, got \(engine.state)")
        }
    }

    @MainActor
    @Test func engineHandlesCancelRecording() async {
        let mock = MockSpeechRecognitionService()
        mock.permissionGranted = true

        let engine = VoiceDictationEngine(service: mock)
        await engine.startRecording()
        #expect(mock.isRecording)

        engine.cancelRecording()
        #expect(!mock.isRecording)
        #expect(engine.state == .idle)
    }
}
