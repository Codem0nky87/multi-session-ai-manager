# iPad Push-to-Talk Voice Input Design

**Date:** 2026-10-28  
**Status:** Approved  
**Author:** Pair Programming Agent  

---

## 1. Problem Statement

MultiSessionAIManager connects users on iPadOS (and iOS) to remote AI agent sessions (OpenAI Codex, Anthropic Claude Code, Google Antigravity `agy`, Hermes, etc.) running in Herdr workspaces over SSH.

While interactive agents support runtime `/voice` slash commands, the agent CLI executes on the remote host (e.g. headless Linux server `forge` or remote Mac), which has no physical microphone attached and does not receive audio through standard SSH PTY connections.

Furthermore, typing long prompts or instructions on an iPad screen or hardware keyboard can be slow and cumbersome.

## 2. Goals & Success Criteria

1. **Push-to-Talk (Hold-to-Speak):** Users press and hold a dedicated 🎙️ key on the bottom `TerminalQuickKeyBar` to speak, and releasing the key completes the recording.
2. **On-Device Apple Speech Recognition:** Uses iOS `Speech.framework` (`SFSpeechRecognizer`) with on-device recognition (`requiresOnDeviceRecognition = true`) on Apple Silicon M-series iPads for zero latency and private, instantaneous transcription.
3. **Live Transcription HUD:** As the user speaks, a floating transcription pill hovers above the quick-key bar, showing real-time transcribed words and an animated audio level indicator.
4. **Insert Only (No Auto-Submit):** On release, the transcribed text is injected directly into the active Herdr terminal session at the cursor via standard PTY input bytes, allowing the user to review or edit before hitting Enter.
5. **Universal Compatibility:** Works across all agents (Codex, Claude Code, Antigravity, bash, etc.) on any remote machine without requiring remote audio drivers or daemons.
6. **Robust Permissions & Feedback:** Transparently handles iOS microphone and speech recognition permission flows with clear error toasts if restricted or denied.

---

## 3. Architecture & Components

```
┌─────────────────────────────────────────────────────────────┐
│                       Herdr Terminal                        │
│   claude > fix the bug in server.py█                        │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ 🔴 ılıı "fix the bug in server.py" (Release to insert)│   │  <- VoiceTranscriptionHUD
│   └─────────────────────────────────────────────────────┘   │
│ [esc] [tab] [ctrl] [shift] [fn] [🎙️] [▲] [▼] [◀] [▶] [⌨️]  │  <- TerminalQuickKeyBar
└─────────────────────────────────────────────────────────────┘
```

### Component Details

### 3.1 `VoiceDictationEngine.swift` (`Core/Voice`)
Responsible for managing audio capture, speech recognition, and state publishing:

```swift
public enum VoiceDictationState: Equatable, Sendable {
    case idle
    case requestingPermissions
    case listening(liveText: String, audioLevel: Float)
    case processing
    case error(String)
}
```

* **Audio Capture:** Uses `AVAudioEngine` with an audio tap on `inputNode` (`installTap(onBus: 0, bufferSize: 1024, format: ...)`).
* **Audio Session Configuration:**
  - Category: `.playAndRecord`
  - Mode: `.measurement`
  - Options: `[.duckOthers, .defaultToSpeaker, .allowBluetooth]`
* **Speech Recognition:**
  - `SFSpeechAudioBufferRecognitionRequest` configured with:
    - `shouldReportPartialResults = true`
    - `requiresOnDeviceRecognition = true` (with fallback to online if on-device model not available).
    - `taskHint = .dictation`
* **Audio Level Metering:** Computes normalized RMS amplitude from PCM buffer to drive waveform animations in the UI (0.0 to 1.0).
* **Thread Safety & Lifecycle:** Runs on `@MainActor` with actor-isolated recognition state and proper teardown on stop/cancel/error.

### 3.2 `VoiceTranscriptionHUD.swift` (`UI/Terminal`)
A SwiftUI floating pill presented directly above the bottom quick-key bar when `state` is `.listening` or `.processing`:

* Visual Elements:
  - Pulsing red recording dot (`Circle().fill(.red)`).
  - Mini 4-bar dynamic audio equalizer driven by `audioLevel`.
  - Formatted partial transcription text (scrollable or horizontally expanding).
  - Subtitle: "Release to insert in terminal".
* Styling:
  - Background: `HerdrTheme.panel.opacity(0.95)` with `HerdrTheme.selection` stroke border.
  - Shadow: Soft dark drop shadow to float cleanly over terminal text.
  - Transitions: `.scale.combined(with: .opacity)` animation.

### 3.3 `TerminalQuickKeyBar.swift` (`UI/Terminal`)
Integrates the push-to-talk button:

* Key Placement: Located between `fn` and `left arrow`.
* Icon: `Image(systemName: isRecording ? "mic.fill" : "mic")`.
* State Styling: Glowing active accent background and pulsating border when recording.
* Gesture Handling:
  - Implements a `DragGesture(minimumDistance: 0)`:
    - `onChanged`: Triggers haptic feedback (`UIImpactFeedbackGenerator(style: .medium)`) and starts `VoiceDictationEngine.shared.startRecording()`.
    - `onEnded`: Stops recording, triggers completion haptic, and passes final text to `onInputBytes(Array(text.utf8))`.
* Disabled when `session.status != .live`.

### 3.4 `App/Info.plist` & `project.yml`
Configures necessary iOS privacy usage descriptions:

* `NSMicrophoneUsageDescription`: `"AI Manager uses the microphone for push-to-talk voice input into your terminal sessions."`
* `NSSpeechRecognitionUsageDescription`: `"AI Manager uses speech recognition to convert your voice into text for your terminal sessions."`

---

## 4. Error Handling & Edge Cases

1. **Permission Denied or Restricted:**
   - If user denies Microphone or Speech Recognition access, transition to `.error(...)` and post a `toastCenter.error("Microphone/Speech permission denied. Enable in Settings.")`.
2. **Empty or Inaudible Utterance:**
   - If user holds the button but doesn't speak, or background noise produces no recognized tokens, no empty text is injected into the terminal.
3. **Audio Interruption (Phone Call / Alarm):**
   - Handles `AVAudioSession.interruptionNotification` to cancel gracefully without crash.
4. **Rapid Press / Tap:**
   - Minimum threshold of 300ms to avoid accidental micro-touches firing empty speech tasks.

---

## 5. Verification & Testing Strategy

1. **Unit Tests (`VoiceDictationEngineTests.swift`):**
   - Test state machine transitions (`idle` -> `listening` -> `processing` -> `idle`).
   - Test text trimming, empty utterance filtering, and UTF-8 byte conversion.
   - Test permission denial handling.
2. **UI Tests (`TerminalQuickKeyBarTests.swift` & `VoiceTranscriptionHUDTests.swift`):**
   - Verify 🎙️ key presence in quick-key bar.
   - Verify HUD rendering when state is `.listening`.
3. **Full Suite on Mac Simulator (`iPad Pro 13-inch (M5)`):**
   - Run complete `xcodebuild test` to ensure 0 regressions across all 789+ tests.
4. **Live Verification & TestFlight Release:**
   - Archive and deploy beta build via Fastlane.
