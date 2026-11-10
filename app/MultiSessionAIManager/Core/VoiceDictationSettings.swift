//
//  VoiceDictationSettings.swift
//  MultiSessionAIManager
//
//  Persisted settings and audio/language helpers for on-device Afrikaans + English
//  Push-to-Talk voice dictation.
//

import Foundation
import AVFoundation
import Combine

// MARK: - Language Mode

public enum DictationLanguageMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case autoAfEn = "auto_af_en"
    case afrikaans = "af"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoAfEn:
            return "Auto (Afrikaans + English)"
        case .afrikaans:
            return "Afrikaans"
        case .english:
            return "English"
        }
    }

    public var shortBadge: String {
        switch self {
        case .autoAfEn:
            return "AF/EN"
        case .afrikaans:
            return "AF"
        case .english:
            return "EN"
        }
    }
}

// MARK: - Whisper Model Variant

public enum WhisperModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case largeV3Turbo = "openai_whisper-large-v3_turbo"
    case small = "openai_whisper-small"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .largeV3Turbo:
            return "Large v3 Turbo (Recommended)"
        case .small:
            return "Small (Compact)"
        }
    }

    public var sizeDescription: String {
        switch self {
        case .largeV3Turbo:
            return "~600 MB • Best Afrikaans + English accuracy"
        case .small:
            return "~240 MB • Faster download"
        }
    }
}

// MARK: - Settings Store & Pure Helpers

@MainActor
public final class VoiceDictationSettings: ObservableObject {
    public static let shared = VoiceDictationSettings()

    private static let languageModeKey = "voiceDictation.languageMode"
    private static let modelVariantKey = "voiceDictation.modelVariant"

    private let defaults: UserDefaults

    @Published public private(set) var languageMode: DictationLanguageMode
    @Published public private(set) var modelVariant: WhisperModelVariant

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawLang = defaults.string(forKey: Self.languageModeKey),
           let parsedLang = DictationLanguageMode(rawValue: rawLang) {
            self.languageMode = parsedLang
        } else {
            self.languageMode = .autoAfEn
        }

        if let rawModel = defaults.string(forKey: Self.modelVariantKey),
           let parsedModel = WhisperModelVariant(rawValue: rawModel) {
            self.modelVariant = parsedModel
        } else {
            self.modelVariant = .largeV3Turbo
        }
    }

    public func setLanguageMode(_ mode: DictationLanguageMode) {
        guard languageMode != mode else { return }
        languageMode = mode
        defaults.set(mode.rawValue, forKey: Self.languageModeKey)
    }

    public func setModelVariant(_ variant: WhisperModelVariant) {
        guard modelVariant != variant else { return }
        modelVariant = variant
        defaults.set(variant.rawValue, forKey: Self.modelVariantKey)
    }

    // MARK: - Pure Static Helpers

    /// Selects strictly between Afrikaans ("af") and English ("en").
    /// In `.autoAfEn` mode, ignores Dutch ("nl") or other third-language false positives
    /// by comparing `P("af")` directly against `P("en")`.
    public nonisolated static func selectBilingualLanguage(
        from languageProbs: [String: Float],
        mode: DictationLanguageMode
    ) -> String {
        switch mode {
        case .afrikaans:
            return "af"
        case .english:
            return "en"
        case .autoAfEn:
            let afProb = languageProbs["af"] ?? 0.0
            let enProb = languageProbs["en"] ?? 0.0
            if afProb > 0.0 && afProb >= enProb {
                return "af"
            }
            return "en"
        }
    }

    /// Rejects sub-250ms clips or near-silent recordings so Whisper does not hallucinate
    /// filler phrases ("Dankie", "Thank you", "[BLANK_AUDIO]") on accidental taps.
    public nonisolated static func isSilentOrTooShort(
        samples: [Float],
        sampleRate: Double = 16_000
    ) -> Bool {
        let minSamples = Int(sampleRate * 0.25)
        guard samples.count >= minSamples else { return true }

        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        for s in samples {
            guard !s.isNaN && !s.isInfinite else { continue }
            let absVal = abs(s)
            if absVal > peak { peak = absVal }
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        return rms < 0.002 && peak < 0.01
    }

    /// Strips Whisper special tokens (`<|...|>`) and non-speech annotations (`[BLANK_AUDIO]`, `(music)`, `[Stilte]`).
    public nonisolated static func cleanWhisperText(_ raw: String) -> String? {
        var cleaned = raw
        if let specialTokenRegex = try? NSRegularExpression(pattern: #"<\|[^|>]+?\|>"#) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = specialTokenRegex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        if let bracketAnnotationRegex = try? NSRegularExpression(pattern: #"(\[[A-Za-z0-9_\s]+\]|\([A-Za-z0-9_\s]+\))"#) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = bracketAnnotationRegex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Resamples an arbitrary `AVAudioPCMBuffer` into 16 kHz mono `Float` samples for Whisper.
    public nonisolated static func extract16kHzMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let frameLength = Int(buffer.frameLength)
        let inputRate = buffer.format.sampleRate
        guard frameLength > 0, inputRate > 0 else { return [] }

        if abs(inputRate - 16_000.0) < 1.0 {
            return Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        }

        let ratio = inputRate / 16_000.0
        let outputLength = max(1, Int(Double(frameLength) / ratio))
        var result = [Float]()
        result.reserveCapacity(outputLength)

        for i in 0..<outputLength {
            let srcPos = Double(i) * ratio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            if idx + 1 < frameLength {
                let s0 = channelData[idx]
                let s1 = channelData[idx + 1]
                result.append(s0 + frac * (s1 - s0))
            } else if idx < frameLength {
                result.append(channelData[idx])
            }
        }
        return result
    }
}
