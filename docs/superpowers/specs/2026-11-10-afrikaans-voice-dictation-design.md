# On-Device Afrikaans & Bilingual Voice Dictation Design

**Date:** 2026-11-10  
**Target:** `MultiSessionAIManager` (iOS / iPadOS 17.0+)  
**Status:** Approved for Spec Review

---

## 1. Context & Problem Statement

Apple's built-in iOS/iPadOS speech recognition frameworks (`SFSpeechRecognizer`, `SpeechTranscriber`, and `DictationTranscriber`) support South African English (`en-ZA`) and Dutch (`nl-NL`, `nl-BE`), but do **not** include an acoustic or language model for Afrikaans (`af` / `af-ZA`). In addition, Apple's on-device `FoundationModels` (`SystemLanguageModel.default`) accepts only text and image attachments (`Transcript.Attachment.image`), not raw microphone audio buffers.

To support Afrikaans Push-to-Talk dictation natively on the iPad (for both terminal prompt input in `TerminalQuickKeyBar` and Apple Intelligence chat input in `AppleIntelligenceView`) without requiring a remote host helper, the app will integrate on-device CoreML Whisper models via `WhisperKit` with bilingual (`af` + `en`) constrained language detection and on-demand model downloads.

---

## 2. Goals & Non-Goals

### Goals
1. **100% On-Device Afrikaans + English Dictation:** Run quantized CoreML Whisper models (`openai_whisper-large-v3_turbo` and `openai_whisper-small`) locally on the iPad Neural Engine / GPU via `WhisperKit`.
2. **Spoken-Language Transcription (`task: .transcribe`):** Always transcribe in the language spoken (`Afrikaans -> Afrikaans`, `English -> English`) without forcing translation.
3. **Constrained Auto-Detection (`af` vs `en`):** Default to automatic bilingual detection between Afrikaans (`"af"`) and English (`"en"`), comparing `P("af")` vs `P("en")` directly so Whisper never misclassifies short Afrikaans phrases as Dutch (`"nl"`).
4. **Manual Language Pinning:** Allow pinning the dictation language to `Auto (Afrikaans + English)`, `Afrikaans`, or `English` in MSAM Settings.
5. **On-Demand Model Delivery:** Keep the TestFlight IPA small by downloading the selected Whisper CoreML model on demand into `Application Support/WhisperModels` with progress reporting and ability to delete/switch models.
6. **Seamless Fallback:** Use `AppleSpeechRecognitionService` (`en-ZA`) when `English` is explicitly pinned and no Whisper model is downloaded yet, or surface a clear actionable error when `Auto (AF/EN)` or `Afrikaans` is used before the Whisper model is downloaded.

### Non-Goals
- Bundling multi-hundred-megabyte CoreML weights directly inside the app binary / TestFlight IPA.
- Requiring an active SSH connection or remote host GPU (`spark-stt`) for voice dictation.

---

## 3. Architecture & Components

### 3.1 Package Dependency (`project.yml`)
- Add `WhisperKit` (`https://github.com/argmaxinc/WhisperKit.git`, `from: 1.1.1`) to `packages:` and link the `WhisperKit` product to the `MultiSessionAIManager` target in `app/MultiSessionAIManager/project.yml`.

### 3.2 `VoiceDictationSettings` (`Core/VoiceDictationSettings.swift`)
A `@MainActor` `ObservableObject` (also singleton `VoiceDictationSettings.shared` backed by `UserDefaults`) managing:
- `DictationLanguageMode` (`String`, `CaseIterable`, `Codable`, `Sendable`):
  - `.autoAfEn` (`"auto_af_en"`) — **Default**. Automatically selects between Afrikaans (`"af"`) and English (`"en"`) per utterance. Display label: `"Auto (Afrikaans + English)"`, short badge: `"AF/EN"`.
  - `.afrikaans` (`"af"`) — Pinned to Afrikaans (`"af"`). Display label: `"Afrikaans"`, short badge: `"AF"`.
  - `.english` (`"en"`) — Pinned to English (`"en"`). Display label: `"English"`, short badge: `"EN"`.
- `WhisperModelVariant` (`String`, `CaseIterable`, `Codable`, `Sendable`):
  - `.largeV3Turbo` (`"openai_whisper-large-v3_turbo"`) — **Default**. Best accuracy for Afrikaans and mixed Afrikaans/English technical terminology (~600 MB).
  - `.small` (`"openai_whisper-small"`) — Compact multilingual option (~240 MB).
- Static helper `selectBilingualLanguage(from languageProbs: [String: Float], mode: DictationLanguageMode) -> String`:
  - For `.afrikaans`: returns `"af"`.
  - For `.english`: returns `"en"`.
  - For `.autoAfEn`: compares `languageProbs["af"] ?? 0` against `languageProbs["en"] ?? 0` and returns `"af"` when `P("af") >= P("en")` and `P("af") > 0`, otherwise `"en"` (completely ignoring `"nl"`, `"de"`, etc.).

### 3.3 `WhisperModelManager` (`Core/WhisperModelManager.swift`)
A `@MainActor` `ObservableObject` responsible for downloading, caching, loading, and deleting CoreML Whisper models under `<Application Support>/WhisperModels`:
- Published state `ModelState: Equatable, Sendable`:
  - `.notDownloaded`
  - `.downloading(progress: Double)`
  - `.loading`
  - `.ready(variant: WhisperModelVariant)`
  - `.failed(String)`
- Checks local disk on initialization to see if the selected `WhisperModelVariant` directory already exists and contains compiled `.mlmodelc` bundles (`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `MelSpectrogram.mlmodelc`, and config files).
- `downloadModel(_ variant: WhisperModelVariant) async`:
  - Uses `WhisperKit.download(variant: variant.rawValue, downloadBase: modelsDirectory, progressCallback: ...)` to stream model files from `argmaxinc/whisperkit-coreml` on HuggingFace and updates `.downloading(progress:)`.
  - Initializes and warms up the `WhisperKit` instance upon completion, transitioning to `.ready(variant:)`.
- `deleteModel(_ variant: WhisperModelVariant) throws`:
  - Unloads any active `WhisperKit` pipeline for that variant, removes its directory from `Application Support/WhisperModels`, and resets state to `.notDownloaded`.

### 3.4 `WhisperSpeechRecognitionService` & Routing in `VoiceDictationEngine`
- `WhisperSpeechRecognitionService` conforms to `SpeechRecognitionService`:
  - Captures microphone audio via `AVAudioEngine` using the existing `nonisolated` tap bridge (`AppleSpeechRecognitionService.makeAudioTapBlock` pattern) so Swift 6 `@MainActor` isolation is never violated on CoreAudio realtime threads.
  - Converts incoming `AVAudioPCMBuffer` frames to 16 kHz mono `Float` samples in a thread-safe sample accumulator while computing RMS audio levels for `VoiceTranscriptionHUD`.
  - When `WhisperModelManager.shared` has a loaded `WhisperKit` instance:
    - Periodically runs lightweight live preview transcription on accumulated samples (if recording exceeds ~1.2s) and emits `onPartialResult`.
    - On `stopRecognition()`, resolves the target language:
      - If `languageMode == .afrikaans`, passes `language: "af"`, `task: .transcribe`.
      - If `languageMode == .english`, passes `language: "en"`, `task: .transcribe`.
      - If `languageMode == .autoAfEn`, runs `whisperKit.detectLanguage(audioArray: samples)` to obtain `languageProbs`, picks `"af"` vs `"en"` via `VoiceDictationSettings.selectBilingualLanguage(from:mode:)`, and transcribes with that language (`task: .transcribe`).
  - **Fallback routing**:
    - If the selected Whisper model is not yet downloaded and `languageMode == .english`, `CompositeSpeechRecognitionService` delegates transparently to `AppleSpeechRecognitionService(locale: Locale(identifier: "en-ZA"))`.
    - If the selected Whisper model is not yet downloaded and `languageMode` is `.autoAfEn` or `.afrikaans`, `startRecognition` throws a descriptive error: `"Download the on-device Whisper model in MSAM Settings → Voice Dictation to use Afrikaans dictation."`

### 3.5 Settings & HUD UI Updates
1. **`TerminalPreferencesSection.swift` / `MSAMSettingsView.swift`**:
   - Add a `"Voice Dictation"` section with:
     - `Picker("Dictation Language", ...)` (`Auto (Afrikaans + English)`, `Afrikaans`, `English`).
     - `Picker("Whisper Model", ...)` (`Large v3 Turbo (~600 MB, Recommended)`, `Small (~240 MB)`).
     - Status & Action row showing:
       - `"Download Model"` button when `.notDownloaded` or `.failed`.
       - `ProgressView(value: progress)` with percentage and `"Cancel"` button when `.downloading`.
       - `"Preparing model on Neural Engine…"` spinner when `.loading`.
       - `"Ready on device"` badge + `"Delete Model"` button when `.ready`.
2. **`VoiceTranscriptionHUD.swift`**:
   - Display a compact language capsule (`AF/EN`, `AF`, or `EN`) next to the waveform so the user always sees which dictation mode is active while holding the microphone button.

---

## 4. Error Handling & Edge Cases
- **Swift 6 Concurrency Safety:** All `AVAudioNodeTapBlock`, permission callbacks, and `WhisperKit` progress callbacks are formed in `nonisolated` functions and hop to `@MainActor` explicitly via `Task { @MainActor in ... }`.
- **Short / Silent Audio Clips:** If the recorded 16 kHz sample buffer is shorter than 0.25 seconds (4,000 samples) or peak/RMS energy is near-silent, skip Whisper inference and return `nil` cleanly without inserting hallucinated Whisper tokens (such as `"Dankie"` or `"Thank you"`).
- **Network Interruption During Model Download:** Partial or failed downloads transition `WhisperModelManager` to `.failed(message)` with a `"Retry Download"` button.

---

## 5. Verification & Testing Plan
1. **Unit Tests (`VoiceDictationEngineTests.swift`)**:
   - `VoiceDictationSettings` persistence and default values (`.autoAfEn`, `.largeV3Turbo`).
   - `VoiceDictationSettings.selectBilingualLanguage(from:mode:)` verifying:
     - Higher `"af"` probability selects `"af"` even when `"nl"` has a high score (`["nl": 0.65, "af": 0.25, "en": 0.05] -> "af"`).
     - Higher `"en"` probability selects `"en"` (`["en": 0.70, "af": 0.10] -> "en"`).
     - Explicit `.afrikaans` and `.english` modes always return `"af"` and `"en"`.
   - `CompositeSpeechRecognitionService` fallback routing when Whisper model is not downloaded (allows `.english` via `AppleSpeechRecognitionService`, throws actionable error for `.afrikaans` / `.autoAfEn`).
   - 16 kHz mono PCM resampling and silence/hallucination guard on empty/sub-250ms buffers.
2. **Build & Simulator Verification on `IronMentorMac`**:
   - Regenerate Xcode project via `xcodegen generate`, run `MultiSessionAIManagerTests/VoiceDictationEngineTests`, and verify full Release archive compilation.
