//
//  WhisperModelManager.swift
//  MultiSessionAIManager
//
//  On-demand download, local caching, CoreML Neural Engine loading, and bilingual
//  (Afrikaans + English) transcription using WhisperKit.
//

import Foundation
import Combine
import WhisperKit

private final class WhisperKitBox: @unchecked Sendable {
    nonisolated(unsafe) let kit: WhisperKit
    nonisolated init(_ kit: WhisperKit) {
        self.kit = kit
    }
}

@MainActor
public final class WhisperModelManager: ObservableObject {
    public static let shared = WhisperModelManager()

    public enum ModelState: Equatable, Sendable {
        case notDownloaded
        case downloading(progress: Double)
        case loading
        case ready(variant: WhisperModelVariant)
        case failed(String)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published public private(set) var state: ModelState = .notDownloaded

    private let settings: VoiceDictationSettings
    private let baseDirectory: URL
    private var whisperKitBox: WhisperKitBox?
    private var loadedVariant: WhisperModelVariant?
    private var downloadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        settings: VoiceDictationSettings = .shared,
        baseDirectory: URL? = nil
    ) {
        self.settings = settings
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport.appendingPathComponent("WhisperModels", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        refreshLocalState()

        settings.$modelVariant
            .dropFirst()
            .sink { [weak self] newVariant in
                guard let self else { return }
                self.handleVariantChange(to: newVariant)
            }
            .store(in: &cancellables)
    }

    // MARK: - Directory Inspection

    public nonisolated static let requiredModelBundles = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc"
    ]

    public nonisolated static func isModelDirectoryComplete(_ directory: URL) -> Bool {
        let fm = FileManager.default
        for bundle in requiredModelBundles {
            var isDir: ObjCBool = false
            let path = directory.appendingPathComponent(bundle, isDirectory: true).path
            if !fm.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                return false
            }
        }
        return true
    }

    public func localModelFolder(for variant: WhisperModelVariant) -> URL? {
        let fm = FileManager.default
        let directCandidate = baseDirectory.appendingPathComponent(variant.rawValue, isDirectory: true)
        if Self.isModelDirectoryComplete(directCandidate) {
            return directCandidate
        }

        let hubCandidate = baseDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
        if Self.isModelDirectoryComplete(hubCandidate) {
            return hubCandidate
        }

        if let enumerator = fm.enumerator(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == variant.rawValue && Self.isModelDirectoryComplete(url) {
                    return url
                }
            }
        }
        return nil
    }

    public func isModelDownloaded(_ variant: WhisperModelVariant) -> Bool {
        localModelFolder(for: variant) != nil
    }

    public var isSelectedModelReadyOrDownloaded: Bool {
        if case .ready(let v) = state, v == settings.modelVariant {
            return true
        }
        return isModelDownloaded(settings.modelVariant)
    }

    public func refreshLocalState() {
        let variant = settings.modelVariant
        if loadedVariant == variant, whisperKitBox != nil {
            state = .ready(variant: variant)
            return
        }
        if isModelDownloaded(variant) {
            state = .ready(variant: variant)
        } else {
            state = .notDownloaded
        }
    }

    private func handleVariantChange(to newVariant: WhisperModelVariant) {
        downloadTask?.cancel()
        downloadTask = nil
        if loadedVariant != newVariant {
            whisperKitBox = nil
            loadedVariant = nil
        }
        refreshLocalState()
    }

    // MARK: - Nonisolated Progress Callback Bridge

    private nonisolated static func makeDownloadProgressCallback(
        onProgress: @MainActor @Sendable @escaping (Double) -> Void
    ) -> @Sendable (Progress) -> Void {
        return { progress in
            let fraction = min(max(progress.fractionCompleted, 0.0), 1.0)
            Task { @MainActor in
                onProgress(fraction)
            }
        }
    }

    private nonisolated static func downloadAndInitializeWhisperKitNonisolated(
        variantName: String,
        downloadBase: URL,
        existingFolder: URL?,
        onProgress: @MainActor @Sendable @escaping (Double) -> Void,
        onLoading: @MainActor @Sendable @escaping () -> Void
    ) async throws -> WhisperKitBox {
        let resolvedFolder: URL
        if let existingFolder {
            resolvedFolder = existingFolder
        } else {
            let callback = makeDownloadProgressCallback(onProgress: onProgress)
            resolvedFolder = try await WhisperKit.download(
                variant: variantName,
                downloadBase: downloadBase,
                useBackgroundSession: false,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: callback
            )
        }

        await onLoading()

        let config = WhisperKitConfig(
            downloadBase: downloadBase,
            modelFolder: resolvedFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        return WhisperKitBox(kit)
    }

    // MARK: - Download / Load / Delete

    public func downloadSelectedModel() {
        guard downloadTask == nil else { return }
        let variant = settings.modelVariant
        let baseDir = baseDirectory
        let existing = localModelFolder(for: variant)

        state = existing != nil ? .loading : .downloading(progress: 0.0)

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let box = try await Self.downloadAndInitializeWhisperKitNonisolated(
                    variantName: variant.rawValue,
                    downloadBase: baseDir,
                    existingFolder: existing,
                    onProgress: { [weak self] fraction in
                        guard let self else { return }
                        if case .downloading = self.state {
                            self.state = .downloading(progress: fraction)
                        }
                    },
                    onLoading: { [weak self] in
                        self?.state = .loading
                    }
                )
                guard !Task.isCancelled else { return }
                self.whisperKitBox = box
                self.loadedVariant = variant
                self.state = .ready(variant: variant)
            } catch is CancellationError {
                self.refreshLocalState()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
            self.downloadTask = nil
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshLocalState()
    }

    public func deleteSelectedModel() {
        downloadTask?.cancel()
        downloadTask = nil
        let variant = settings.modelVariant
        if loadedVariant == variant {
            whisperKitBox = nil
            loadedVariant = nil
        }
        while let folder = localModelFolder(for: variant) {
            try? FileManager.default.removeItem(at: folder)
        }
        state = .notDownloaded
    }

    // MARK: - Transcription

    private func ensureLoadedWhisperKit() async throws -> WhisperKitBox {
        let variant = settings.modelVariant
        if let box = whisperKitBox, loadedVariant == variant {
            return box
        }
        guard let folder = localModelFolder(for: variant) else {
            throw NSError(
                domain: "VoiceDictation",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey: "Download the on-device Whisper model in MSAM Settings → Voice Dictation to use Afrikaans dictation."
                ]
            )
        }

        state = .loading
        do {
            let box = try await Self.downloadAndInitializeWhisperKitNonisolated(
                variantName: variant.rawValue,
                downloadBase: baseDirectory,
                existingFolder: folder,
                onProgress: { _ in },
                onLoading: {}
            )
            self.whisperKitBox = box
            self.loadedVariant = variant
            self.state = .ready(variant: variant)
            return box
        } catch {
            self.state = .failed(error.localizedDescription)
            throw error
        }
    }

    private nonisolated static func runWhisperTranscriptionNonisolated(
        box: WhisperKitBox,
        samples: [Float],
        mode: DictationLanguageMode
    ) async throws -> String? {
        let kit = box.kit
        let targetLanguage: String
        switch mode {
        case .afrikaans:
            targetLanguage = "af"
        case .english:
            targetLanguage = "en"
        case .autoAfEn:
            if let detected = try? await kit.detectLangauge(audioArray: samples) {
                targetLanguage = VoiceDictationSettings.selectBilingualLanguage(
                    from: detected.langProbs,
                    mode: .autoAfEn
                )
            } else {
                targetLanguage = "af"
            }
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: targetLanguage,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true
        )

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let combined = results.map(\.text).joined(separator: " ")
        return VoiceDictationSettings.cleanWhisperText(combined)
    }

    public func transcribeSamples(
        _ samples: [Float],
        languageMode: DictationLanguageMode
    ) async throws -> String? {
        guard !VoiceDictationSettings.isSilentOrTooShort(samples: samples) else {
            return nil
        }
        let box = try await ensureLoadedWhisperKit()
        return try await Self.runWhisperTranscriptionNonisolated(
            box: box,
            samples: samples,
            mode: languageMode
        )
    }
}
