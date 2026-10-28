# iPad Push-to-Talk Voice Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device Push-to-Talk (PTT) voice input feature to MultiSessionAIManager on iPadOS (and iOS) that transcribes spoken user prompts in real time and types them directly into the active Herdr terminal session at the cursor without auto-submitting.

**Architecture:** A `@MainActor` `VoiceDictationEngine` coordinates `AVAudioEngine`, `AVAudioSession`, and `SFSpeechRecognizer` with on-device dictation enabled. A sleek floating `VoiceTranscriptionHUD` hovers over the bottom `TerminalQuickKeyBar`, displaying an audio level waveform and live transcribed words while the user holds the 🎙️ key. Releasing the key stops recording and passes the UTF-8 text to `onInputBytes` in the active terminal session.

**Tech Stack:** Swift 6.0, SwiftUI, Speech.framework (`SFSpeechRecognizer`), AVFoundation (`AVAudioEngine`, `AVAudioSession`), XcodeGen, Fastlane.

**Spec:** `docs/superpowers/specs/2026-10-28-ipad-push-to-talk-voice-input-design.md`

## Global Constraints

- Platform target: iOS 17.0+ (Universal iPad and iPhone).
- Architecture: Works for all AI agents (Codex, Claude Code, Antigravity, Hermes, bash) running in Herdr without remote host dependencies.
- Audio privacy: Strictly require explicit user consent via `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- On-device speech recognition: Prioritize on-device speech processing (`requiresOnDeviceRecognition = true`) on Apple Silicon.
- Insertion behavior: Insert only (no auto-submit / Enter key appended).
- Test suite: All 789+ existing Swift tests must remain green.

---

### Task 1: Permissions & Project Configuration (`project.yml`)

**Files:**
- Modify: `app/MultiSessionAIManager/project.yml:50-58`

**Interfaces:**
- Produces: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` in generated `Info.plist`.

- [ ] **Step 1: Add privacy usage descriptions to `project.yml`**

Add the keys under `targets.MultiSessionAIManager.info.properties`:
```yaml
        NSMicrophoneUsageDescription: "AI Manager uses the microphone for push-to-talk voice input into your terminal sessions."
        NSSpeechRecognitionUsageDescription: "AI Manager uses speech recognition to convert your voice into text for your terminal sessions."
```

- [ ] **Step 2: Regenerate Xcode project on Mac**

Run on Mac via SSH:
```bash
ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodegen generate"
```

- [ ] **Step 3: Commit changes**

```bash
git add app/MultiSessionAIManager/project.yml
git commit -m "chore(config): add microphone and speech recognition permissions to project.yml"
```

---

### Task 2: Core Voice Dictation Engine (`VoiceDictationEngine.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/Core/VoiceDictationEngine.swift`
- Create: `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum VoiceDictationState: Equatable, Sendable {
      case idle
      case requestingPermissions
      case listening(liveText: String, audioLevel: Float)
      case processing
      case error(String)
  }

  @MainActor
  public final class VoiceDictationEngine: ObservableObject {
      public static let shared: VoiceDictationEngine
      @Published public private(set) var state: VoiceDictationState
      public func startRecording() async
      public func stopRecording() async -> String?
      public func cancelRecording()
  }
  ```

- [ ] **Step 1: Write unit tests for `VoiceDictationState` and engine lifecycle**

Create `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift` testing:
1. Initial state is `.idle`.
2. State transitions and equality checks.
3. Audio level normalization clamping between 0.0 and 1.0.
4. Text trimming and discarding whitespace-only results.

- [ ] **Step 2: Run Swift tests on Mac to verify test fails**

Run:
```bash
ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests"
```
Expected: Compilation failure (missing `VoiceDictationEngine`).

- [ ] **Step 3: Implement `VoiceDictationEngine.swift`**

Implement:
- Permission checking: `AVAudioSession.sharedInstance().recordPermission` and `SFSpeechRecognizer.authorizationStatus()`.
- Audio session setup: category `.playAndRecord`, mode `.measurement`, options `[.duckOthers, .defaultToSpeaker, .allowBluetooth]`.
- `AVAudioEngine` input tap with RMS level computation.
- `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true` and `shouldReportPartialResults = true`.
- Clean teardown on stop and cancel.

- [ ] **Step 4: Run Swift tests on Mac to verify PASS**

Run:
```bash
ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests"
```
Expected: PASS.

- [ ] **Step 5: Commit changes**

```bash
git add app/MultiSessionAIManager/Core/VoiceDictationEngine.swift app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift
git commit -m "feat(core): implement VoiceDictationEngine with on-device speech recognition"
```

---

### Task 3: Live Voice Transcription HUD (`VoiceTranscriptionHUD.swift`)

**Files:**
- Create: `app/MultiSessionAIManager/UI/Terminal/VoiceTranscriptionHUD.swift`
- Create: `app/MultiSessionAIManager/Tests/VoiceTranscriptionHUDTests.swift`

**Interfaces:**
- Consumes: `VoiceDictationState`
- Produces: `VoiceTranscriptionHUD` SwiftUI view.

- [ ] **Step 1: Write unit tests for `VoiceTranscriptionHUD`**

Create `app/MultiSessionAIManager/Tests/VoiceTranscriptionHUDTests.swift` testing:
1. Visibility checks based on state (visible on `.listening` and `.processing`, hidden on `.idle`).
2. Text presentation formatting.

- [ ] **Step 2: Implement `VoiceTranscriptionHUD.swift`**

Build SwiftUI view:
- Centered floating pill with `HerdrTheme.panel` background and `HerdrTheme.selection` border.
- Pulsing red indicator dot.
- Mini 4-bar equalizer reacting to `audioLevel`.
- Scrolling live transcript text.
- Helper subtitle: "Release to insert in terminal".

- [ ] **Step 3: Run Swift tests on Mac to verify PASS**

Run:
```bash
ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:MultiSessionAIManagerTests/VoiceTranscriptionHUDTests"
```
Expected: PASS.

- [ ] **Step 4: Commit changes**

```bash
git add app/MultiSessionAIManager/UI/Terminal/VoiceTranscriptionHUD.swift app/MultiSessionAIManager/Tests/VoiceTranscriptionHUDTests.swift
git commit -m "feat(ui): add VoiceTranscriptionHUD floating live transcription pill"
```

---

### Task 4: Push-to-Talk Integration in `TerminalQuickKeyBar.swift` & `RootView.swift`

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Terminal/TerminalQuickKeyBar.swift:55-75`
- Modify: `app/MultiSessionAIManager/UI/RootView.swift:650-670`
- Modify: `app/MultiSessionAIManager/Tests/HostSoftwareTests.swift` or `RootViewModelTests.swift`

**Interfaces:**
- Connects Push-to-Talk button to `VoiceDictationEngine.shared` and routes transcribed text to `onInputBytes`.

- [ ] **Step 1: Update `TerminalQuickKeyBar.swift`**

1. Inject `@ObservedObject var voiceEngine = VoiceDictationEngine.shared`.
2. Add the microphone key between `fn` and `arrow.left`:
   - Visual: `mic.fill` with active tint and subtle pulse when recording.
   - Gesture: Push-to-talk press/release handling using `DragGesture(minimumDistance: 0)`:
     - On touch down: triggers medium haptic and `Task { await voiceEngine.startRecording() }`.
     - On touch up: triggers light haptic, awaits `voiceEngine.stopRecording()`, and if text is present, sends `onInputBytes(Array(text.utf8))`.
3. Render `VoiceTranscriptionHUD` hovering directly above the bar when active.

- [ ] **Step 2: Run full Swift test suite on Mac**

Run:
```bash
ssh rufus@Rufuss-MacBook-Air.local "cd ~/Projects/multi-session-ai-manager/app/MultiSessionAIManager && xcodebuild test -scheme MultiSessionAIManager -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'"`
```
Expected: All tests PASS.

- [ ] **Step 3: Commit changes**

```bash
git add app/MultiSessionAIManager/UI/Terminal/TerminalQuickKeyBar.swift app/MultiSessionAIManager/UI/RootView.swift
git commit -m "feat(ui): integrate push-to-talk voice key into TerminalQuickKeyBar"
```

---

### Task 5: End-to-End Verification & TestFlight Delivery

**Files:**
- Fastlane deployment to TestFlight.

- [ ] **Step 1: Push commits to GitHub `origin/main`**
- [ ] **Step 2: Run `fastlane beta` on Mac**
- [ ] **Step 3: Confirm TestFlight build processing on App Store Connect**
- [ ] **Step 4: Clean up any Mac build observers and release machine**
