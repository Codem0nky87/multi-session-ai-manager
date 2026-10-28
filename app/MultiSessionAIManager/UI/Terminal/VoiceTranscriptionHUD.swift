//
//  VoiceTranscriptionHUD.swift
//  MultiSessionAIManager
//
//  Floating transcription pill shown directly above the terminal quick-key bar
//  during push-to-talk voice dictation. Shows a pulsating recording indicator,
//  dynamic audio level equalizer, and real-time partial transcript preview.
//

import SwiftUI

public struct VoiceTranscriptionHUD: View {
    @ObservedObject var engine: VoiceDictationEngine

    public init(engine: VoiceDictationEngine = .shared) {
        self.engine = engine
    }

    // MARK: - Static Helpers for Testability

    public static func shouldDisplay(for state: VoiceDictationState) -> Bool {
        switch state {
        case .listening, .processing:
            return true
        case .idle, .requestingPermissions, .error:
            return false
        }
    }

    public static func displayText(for state: VoiceDictationState) -> String {
        switch state {
        case .listening(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Listening…" : trimmed
        case .processing:
            return "Inserting…"
        case .idle, .requestingPermissions, .error:
            return ""
        }
    }

    public static func barHeight(forIndex index: Int, level: Float) -> CGFloat {
        let base: CGFloat = 6.0
        let multipliers: [CGFloat] = [1.0, 1.4, 1.2, 0.8]
        let factor = index < multipliers.count ? multipliers[index] : 1.0
        let clamped = CGFloat(min(max(level, 0.0), 1.0))
        let dynamic = clamped * 14.0 * factor
        return min(max(base + dynamic, 4.0), 24.0)
    }

    // MARK: - View Body

    public var body: some View {
        if Self.shouldDisplay(for: engine.state) {
            let currentLevel: Float = {
                if case .listening(_, let level) = engine.state { return level }
                return 0.0
            }()

            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    // Recording pulsing dot
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .scaleEffect(engine.state == .processing ? 0.8 : 1.1)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: engine.state)

                    // Audio level equalizer waveform
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<4, id: \.self) { idx in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.red.opacity(0.85))
                                .frame(width: 3, height: Self.barHeight(forIndex: idx, level: currentLevel))
                                .animation(.easeOut(duration: 0.1), value: currentLevel)
                        }
                    }
                    .frame(height: 24)

                    // Live transcription preview
                    Text(Self.displayText(for: engine.state))
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // Helper release caption
                Text("Release to insert in terminal")
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                HerdrTheme.panel.opacity(0.95),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(HerdrTheme.selection, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .opacity
            ))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: engine.state)
        }
    }
}
