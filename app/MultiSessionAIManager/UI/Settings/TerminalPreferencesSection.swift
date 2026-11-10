import SwiftUI

struct TerminalPreferencesSection: View {
    @Bindable var settings: TerminalSettings
    @ObservedObject private var voiceSettings: VoiceDictationSettings = .shared
    @ObservedObject private var whisperManager: WhisperModelManager = .shared

    var body: some View {
        Section("Terminal") {
            Picker("Theme", selection: Binding(
                get: { settings.themeID },
                set: { settings.setThemeID($0) }
            )) {
                ForEach(TerminalTheme.all) { theme in
                    HStack {
                        Text(theme.name)
                        Spacer()
                        themeSwatches(for: theme)
                    }
                    .tag(theme.id)
                }
            }
            .accessibilityIdentifier("settings.terminal.theme")

            HStack {
                Text("Text size")
                Spacer()
                Button {
                    settings.step(-1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Decrease terminal text size")
                .accessibilityIdentifier("settings.terminal.decrease")
                .buttonStyle(.borderless)

                Text("\(Int(settings.fontSize)) pt")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 52)

                Button {
                    settings.step(1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Increase terminal text size")
                .accessibilityIdentifier("settings.terminal.increase")
                .buttonStyle(.borderless)
            }

            Button("Reset to \(Int(TerminalSettings.defaultSize)) pt") {
                settings.setFontSize(TerminalSettings.defaultSize)
            }
        }

        Section("Voice Dictation (On-Device Whisper)") {
            Picker("Language", selection: Binding(
                get: { voiceSettings.languageMode },
                set: { voiceSettings.setLanguageMode($0) }
            )) {
                ForEach(DictationLanguageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.voice.language")

            Picker("Whisper Model", selection: Binding(
                get: { voiceSettings.modelVariant },
                set: { voiceSettings.setModelVariant($0) }
            )) {
                ForEach(WhisperModelVariant.allCases) { variant in
                    VStack(alignment: .leading) {
                        Text(variant.displayName)
                        Text(variant.sizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(variant)
                }
            }
            .accessibilityIdentifier("settings.voice.model")

            whisperModelStatusRow
        }
    }

    @ViewBuilder
    private var whisperModelStatusRow: some View {
        switch whisperManager.state {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    whisperManager.downloadSelectedModel()
                } label: {
                    Label("Download On-Device Model", systemImage: "arrow.down.circle.fill")
                }
                .accessibilityIdentifier("settings.voice.download")

                Text(voiceSettings.modelVariant.sizeDescription + " • Runs locally on iPad Neural Engine for Afrikaans & English.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Downloading \(voiceSettings.modelVariant.displayName)…")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                Button("Cancel Download", role: .cancel) {
                    whisperManager.cancelDownload()
                }
                .font(.footnote)
            }

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Preparing model on Apple Neural Engine…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .ready(let variant):
            HStack {
                Label("Ready on device (\(variant.displayName))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Spacer()
                Button("Delete", role: .destructive) {
                    whisperManager.deleteSelectedModel()
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.voice.delete")
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Download failed: \(message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button {
                    whisperManager.downloadSelectedModel()
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise.circle.fill")
                }
            }
        }
    }

    private func themeSwatches(for theme: TerminalTheme) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(theme.previewColors.prefix(5).enumerated()), id: \.offset) { _, uiColor in
                Circle()
                    .fill(Color(uiColor))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
