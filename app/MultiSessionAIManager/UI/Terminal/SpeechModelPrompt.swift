//
//  SpeechModelPrompt.swift
//  MultiSessionAIManager
//
//  What a Push-to-Talk key does while dictation is unavailable. A mic key that
//  cannot record must look unavailable and say why when touched -- a press that
//  silently does nothing is the failure this replaces. When the fix is fetching
//  the Whisper model, the key offers that download itself, stating the size and
//  waiting for a yes: the model is hundreds of megabytes and is never fetched
//  behind the user's back.
//

import SwiftUI
import UIKit

extension VoiceDictationAvailability {
    /// The glyph a mic key shows in place of `mic.fill` while it is unavailable.
    var micKeySymbol: String {
        switch self {
        case .ready:
            return "mic.fill"
        case .modelNotDownloaded, .modelFailed:
            return "mic.slash.fill"
        case .modelDownloading:
            return "arrow.down.circle"
        case .modelLoading:
            return "hourglass"
        }
    }

    /// Answers a touch on an unavailable mic key: offer the download when that is
    /// the fix, otherwise say what the key is waiting for.
    @MainActor
    func explainUnavailableMicKey(showingPrompt: Binding<Bool>, toasts: ToastCenter?) {
        guard !isReady else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if offersDownload {
            showingPrompt.wrappedValue = true
        } else if let statusText {
            toasts?.info(statusText)
        }
    }
}

/// The download offer raised by an unavailable mic key.
private struct SpeechModelPrompt: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject private var settings: VoiceDictationSettings = .shared
    @ObservedObject private var manager: WhisperModelManager = .shared

    private var failureMessage: String? {
        if case .failed(let message) = manager.state { return message }
        return nil
    }

    private var message: String {
        let variant = settings.modelVariant
        let offer = "Afrikaans dictation runs entirely on this device and needs a one-time download of the Whisper speech model (\(variant.displayName), \(variant.approximateSize)). English dictation works without it."
        if let failureMessage {
            return "The last attempt failed: \(failureMessage)\n\n\(offer)"
        }
        return offer
    }

    func body(content: Content) -> some View {
        content.alert(
            failureMessage == nil ? "Download the speech model?" : "Speech model not ready",
            isPresented: $isPresented
        ) {
            Button(failureMessage == nil ? "Download (\(settings.modelVariant.approximateSize))" : "Try Again") {
                manager.downloadSelectedModel()
            }
            Button("Use English Only") {
                settings.setLanguageMode(.english)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

extension View {
    /// Attach once next to a mic key; present it via `explainUnavailableMicKey`.
    func speechModelPrompt(isPresented: Binding<Bool>) -> some View {
        modifier(SpeechModelPrompt(isPresented: isPresented))
    }
}
