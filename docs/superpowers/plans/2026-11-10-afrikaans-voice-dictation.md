# On-Device Afrikaans & Bilingual Voice Dictation Implementation Plan

> **Withdrawn 2026-11-10.** This plan was executed and the feature was then removed the same day; see the status note in `docs/superpowers/specs/2026-11-10-afrikaans-voice-dictation-design.md`. Do not execute it again.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 100% on-device Afrikaans (`af`) and bilingual (`af` + `en`) Push-to-Talk voice dictation on iPad/iPhone using `WhisperKit` CoreML models with constrained `af`/`en` language detection, on-demand model downloads, and settings/HUD controls.

**Architecture:** We add `VoiceDictationSettings` (persisted language mode `.autoAfEn` / `.afrikaans` / `.english`, model variant `.largeV3Turbo` / `.small`, and constrained `af`/`en` probability selector plus 16 kHz audio resampling & silence filtering) and `WhisperModelManager` (on-demand HuggingFace CoreML model download/load/delete in `Application Support/WhisperModels`). `WhisperSpeechRecognitionService` captures 16 kHz mono samples via `nonisolated` CoreAudio tap callbacks, performs bilingual `af`/`en` detection + transcription on `WhisperKit`, and falls back to `AppleSpeechRecognitionService` when `English` is pinned and no Whisper model is downloaded yet.

**Tech Stack:** Swift 6.0, SwiftUI, AVFoundation, Speech.framework, WhisperKit (`argmaxinc/WhisperKit` `1.1.1`), Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-11-10-afrikaans-voice-dictation-design.md`

## Global Constraints

- Minimum deployment target: `iOS: "17.0"`, `SWIFT_VERSION: "6.0"`.
- Package dependency: `WhisperKit` from `https://github.com/argmaxinc/WhisperKit.git` (`from: 1.1.1`).
- Spoken-language transcription only (`DecodingTask.transcribe`); never translate Afrikaans into English.
- In `.autoAfEn` mode, choose strictly between `"af"` and `"en"` using `languageProbs["af"]` vs `languageProbs["en"]` so Afrikaans is never misclassified as Dutch (`"nl"`).
- All Objective-C / CoreAudio / progress closures passed across thread boundaries must be created in `nonisolated` functions and hop to `@MainActor` via `Task { @MainActor in ... }`.

---

### Task 1: VoiceDictationSettings, Bilingual `af`/`en` Selector & Audio Resampler

**Files:**
- Create: `app/MultiSessionAIManager/Core/VoiceDictationSettings.swift`
- Modify: `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift`

**Interfaces:**
- Consumes: `Foundation`, `AVFoundation`, `Combine`
- Produces:
  - `public enum DictationLanguageMode: String, CaseIterable, Codable, Sendable` (`.autoAfEn`, `.afrikaans`, `.english`, `displayName`, `shortBadge`)
  - `public enum WhisperModelVariant: String, CaseIterable, Codable, Sendable` (`.largeV3Turbo`, `.small`, `displayName`, `sizeDescription`)
  - `@MainActor public final class VoiceDictationSettings: ObservableObject` (`shared`, `languageMode`, `modelVariant`, `selectBilingualLanguage(from:mode:)`, `isSilentOrTooShort(samples:sampleRate:)`, `resampleTo16kHzMono(buffer:)`, `cleanWhisperText(_:)`)

- [ ] **Step 1: Write the failing tests in `VoiceDictationEngineTests.swift`**

Append tests to `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift` verifying:
1. `VoiceDictationSettings` defaults to `.autoAfEn` and `.largeV3Turbo`, and persists changes to a custom `UserDefaults` suite.
2. `VoiceDictationSettings.selectBilingualLanguage(from:mode:)` picks `"af"` when `P("af") >= P("en")` even if `"nl"` has 0.80 probability, picks `"en"` when `P("en") > P("af")`, and returns `"af"` / `"en"` when pinned.
3. `VoiceDictationSettings.isSilentOrTooShort(samples:sampleRate:)` rejects buffers under 0.25s (`< 4000` samples at 16 kHz) or near-zero RMS energy, and accepts speech-level buffers.
4. `VoiceDictationSettings.cleanWhisperText(_:)` strips `[BLANK_AUDIO]`, `(music)`, and `<|...|>` special tokens.

- [ ] **Step 2: Run test on `IronMentorMac` to verify it fails**

Run: `xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests`
Expected: FAIL with unresolved identifier `VoiceDictationSettings`, `DictationLanguageMode`, `WhisperModelVariant`.

- [ ] **Step 3: Write minimal implementation in `app/MultiSessionAIManager/Core/VoiceDictationSettings.swift`**

Implement `DictationLanguageMode`, `WhisperModelVariant`, and `VoiceDictationSettings` with `selectBilingualLanguage`, `isSilentOrTooShort`, `resampleTo16kHzMono`, and `cleanWhisperText`.

- [ ] **Step 4: Run test on `IronMentorMac` to verify it passes**

Run: `xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/MultiSessionAIManager/Core/VoiceDictationSettings.swift app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift
git commit -m "feat: add VoiceDictationSettings and bilingual af/en selector"
```

---

### Task 2: WhisperKit Dependency, `WhisperModelManager` & `WhisperSpeechRecognitionService`

**Files:**
- Modify: `app/MultiSessionAIManager/project.yml`
- Create: `app/MultiSessionAIManager/Core/WhisperModelManager.swift`
- Modify: `app/MultiSessionAIManager/Core/VoiceDictationEngine.swift`
- Modify: `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift`

**Interfaces:**
- Consumes: `VoiceDictationSettings`, `DictationLanguageMode`, `WhisperModelVariant`, `WhisperKit`
- Produces:
  - `@MainActor public final class WhisperModelManager: ObservableObject` (`shared`, `state: ModelState`, `isModelDownloaded(_:)`, `refreshLocalState()`, `downloadSelectedModel()`, `deleteSelectedModel()`, `transcribeSamples(_:languageMode:)`)
  - `@MainActor public final class CompositeSpeechRecognitionService: SpeechRecognitionService` (routes between `WhisperSpeechRecognitionService` and `AppleSpeechRecognitionService` fallback)

- [ ] **Step 1: Write the failing tests in `VoiceDictationEngineTests.swift`**

Add unit tests in `VoiceDictationEngineTests.swift` verifying:
1. `WhisperModelManager.isModelDirectoryComplete(_:)` returns `false` when `.mlmodelc` folders (`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `MelSpectrogram.mlmodelc`) are missing and `true` when all three exist inside a temporary model directory.
2. `CompositeSpeechRecognitionService` uses the fallback `SpeechRecognitionService` (`AppleSpeechRecognitionService` mock) when Whisper is not ready and `languageMode == .english`, throws an actionable error mentioning `"MSAM Settings → Voice Dictation"` when Whisper is not ready and `languageMode` is `.autoAfEn` or `.afrikaans`, and uses the primary Whisper `SpeechRecognitionService` when Whisper is ready.

- [ ] **Step 2: Run test on `IronMentorMac` to verify it fails**

Run: `xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests`
Expected: FAIL with unresolved `WhisperModelManager` / `CompositeSpeechRecognitionService`.

- [ ] **Step 3: Add `WhisperKit` to `project.yml`, implement `WhisperModelManager.swift`, and wire `CompositeSpeechRecognitionService` in `VoiceDictationEngine.swift`**

1. Add `WhisperKit` package (`https://github.com/argmaxinc/WhisperKit.git`, `from: 1.1.1`) to `app/MultiSessionAIManager/project.yml`.
2. Create `app/MultiSessionAIManager/Core/WhisperModelManager.swift` implementing on-demand download (`WhisperKit.download`), model directory validation, model loading (`WhisperKit(WhisperKitConfig(...))`), deletion, and `transcribeSamples(_:languageMode:)` using `detectLangauge(audioArray:)` + `VoiceDictationSettings.selectBilingualLanguage(from:mode:)` + `transcribe(audioArray:decodeOptions:)`.
3. Add `WhisperSpeechRecognitionService` and `CompositeSpeechRecognitionService` in `VoiceDictationEngine.swift`, making `CompositeSpeechRecognitionService` the default service for `VoiceDictationEngine.shared`.

- [ ] **Step 4: Run test on `IronMentorMac` to verify it passes**

Run: `xcodegen generate && xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/MultiSessionAIManager/project.yml app/MultiSessionAIManager/Core/WhisperModelManager.swift app/MultiSessionAIManager/Core/VoiceDictationEngine.swift app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift
git commit -m "feat: integrate WhisperKit model manager and bilingual speech recognition service"
```

---

### Task 3: Voice Dictation Settings Section & HUD Language Badge

**Files:**
- Modify: `app/MultiSessionAIManager/UI/Settings/TerminalPreferencesSection.swift`
- Modify: `app/MultiSessionAIManager/UI/Terminal/VoiceTranscriptionHUD.swift`
- Modify: `app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift`

**Interfaces:**
- Consumes: `VoiceDictationSettings`, `WhisperModelManager`, `VoiceDictationEngine`
- Produces:
  - `"Voice Dictation"` section inside `TerminalPreferencesSection` with Language picker (`Auto (Afrikaans + English)`, `Afrikaans`, `English`), Model variant picker (`Large v3 Turbo`, `Small`), and Download/Progress/Delete controls.
  - `VoiceTranscriptionHUD.languageBadgeText(for:)` and language badge capsule in `VoiceTranscriptionHUD`.

- [ ] **Step 1: Write the failing test in `VoiceDictationEngineTests.swift`**

Add a test verifying `VoiceTranscriptionHUD.languageBadgeText(for:)` returns `"AF/EN"`, `"AF"`, and `"EN"` for `.autoAfEn`, `.afrikaans`, and `.english`.

- [ ] **Step 2: Run test on `IronMentorMac` to verify it fails**

Run: `xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests`
Expected: FAIL with missing `VoiceTranscriptionHUD.languageBadgeText(for:)`.

- [ ] **Step 3: Implement UI updates in `VoiceTranscriptionHUD.swift` and `TerminalPreferencesSection.swift`**

1. Add `VoiceTranscriptionHUD.languageBadgeText(for:)` and render the compact language badge (`AF/EN`, `AF`, `EN`) in `VoiceTranscriptionHUD`.
2. Add the `"Voice Dictation"` settings section in `TerminalPreferencesSection.swift` bound to `VoiceDictationSettings.shared` and `WhisperModelManager.shared`.

- [ ] **Step 4: Run test on `IronMentorMac` to verify it passes**

Run: `xcodebuild test -project MultiSessionAIManager.xcodeproj -scheme MultiSessionAIManager -destination "platform=iOS Simulator,name=iPad Pro 13-inch (M5)" -only-testing:MultiSessionAIManagerTests/VoiceDictationEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/MultiSessionAIManager/UI/Settings/TerminalPreferencesSection.swift app/MultiSessionAIManager/UI/Terminal/VoiceTranscriptionHUD.swift app/MultiSessionAIManager/Tests/VoiceDictationEngineTests.swift
git commit -m "feat: add Afrikaans voice dictation settings and HUD language badge"
```
