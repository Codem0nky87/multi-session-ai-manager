import SwiftUI
import AudioToolbox
import UIKit

public struct AppleIntelligenceView: View {
    public let activeTerminalText: () -> String?
    public let onInsertToTerminal: (String) -> Void
    public let onClose: () -> Void
    public let onApplyAction: ((AppAction) async throws -> Void)?
    public let onDismissAction: ((UUID) -> Void)?

    @State private var engine: AppleIntelligenceEngine
    @ObservedObject private var voiceEngine: VoiceDictationEngine
    @State private var inputText: String = ""
    @State private var attachedContext: String? = nil
    @State private var isVoicePressed: Bool = false

    public init(
        engine: AppleIntelligenceEngine = .shared,
        voiceEngine: VoiceDictationEngine = .shared,
        activeTerminalText: @escaping () -> String?,
        onInsertToTerminal: @escaping (String) -> Void,
        onClose: @escaping () -> Void,
        onApplyAction: ((AppAction) async throws -> Void)? = nil,
        onDismissAction: ((UUID) -> Void)? = nil
    ) {
        self._engine = State(initialValue: engine)
        self.voiceEngine = voiceEngine
        self.activeTerminalText = activeTerminalText
        self.onInsertToTerminal = onInsertToTerminal
        self.onClose = onClose
        self.onApplyAction = onApplyAction
        self.onDismissAction = onDismissAction
    }

    public static func lineCount(of text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.components(separatedBy: "\n").count
    }

    public static func placeholder(for state: AppleIntelligenceEngine.AvailabilityState) -> String {
        switch state {
        case .available:
            return "Ask Apple Intelligence..."
        case .downloading:
            return "Model assets are downloading..."
        case .notEnabled:
            return "Enable Apple Intelligence in Settings..."
        case .unsupported:
            return "Unavailable on this device"
        case .checking:
            return "Checking availability..."
        }
    }

    private var inputPlaceholder: String {
        Self.placeholder(for: engine.availability)
    }

    private var canSend: Bool {
        engine.availability.isReady &&
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !engine.isGenerating
    }

    private var isRecordingVoice: Bool {
        if case .listening = voiceEngine.state { return true }
        if case .processing = voiceEngine.state { return true }
        return false
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(HerdrTheme.selection)

            availabilityBanner

            messagesScrollView

            if let context = attachedContext {
                attachedContextPill(context: context)
            }

            Divider().background(HerdrTheme.selection)
            inputBar
        }
        .background(HerdrTheme.background)
        .onAppear {
            engine.checkAvailability()
        }
        .accessibilityIdentifier("msam.intelligence.view")
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HerdrTheme.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("Intelligence")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HerdrTheme.text)

                Text("Apple Foundation Models • Private")
                    .font(.caption2)
                    .foregroundStyle(HerdrTheme.subtext)
            }

            Spacer()

            if !engine.messages.isEmpty {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    engine.clearHistory()
                    attachedContext = nil
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(HerdrTheme.subtext)
                        .padding(6)
                        .background(HerdrTheme.panel, in: Circle())
                }
                .accessibilityLabel("Clear Conversation")
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .accessibilityLabel("Close Intelligence")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(HerdrTheme.panel)
    }

    // MARK: - Availability Banner
    @ViewBuilder
    private var availabilityBanner: some View {
        switch engine.availability {
        case .available, .checking:
            EmptyView()
        case .downloading(let reason):
            statusBanner(
                icon: "arrow.down.circle.fill",
                color: HerdrTheme.accent,
                reason: reason,
                showSpinner: true
            )
        case .notEnabled(let reason):
            statusBanner(
                icon: "gearshape.fill",
                color: HerdrTheme.yellow,
                reason: reason,
                showSpinner: false
            )
        case .unsupported(let reason):
            statusBanner(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                reason: reason,
                showSpinner: false
            )
        }
    }

    private func statusBanner(icon: String, color: Color, reason: String, showSpinner: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if showSpinner {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
            }

            Text(reason)
                .font(.caption)
                .foregroundStyle(HerdrTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                engine.checkAvailability()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HerdrTheme.subtext)
                    .padding(4)
            }
            .accessibilityLabel("Check Again")
        }
        .padding(10)
        .background(color.opacity(0.12))
        .overlay(Rectangle().stroke(color.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Messages View
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if engine.messages.isEmpty {
                    emptyStateView
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(engine.messages) { message in
                            AppleIntelligenceMessageView(
                                message: message,
                                onInsertToTerminal: onInsertToTerminal,
                                onApplyAction: onApplyAction,
                                onDismissAction: { id in
                                    if let onDismissAction {
                                        onDismissAction(id)
                                    } else {
                                        engine.dismissAction(for: id)
                                    }
                                }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
            }
            .onChange(of: engine.messages.count) { _, _ in
                if let lastID = engine.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: engine.messages.last?.content) { _, _ in
                if let lastID = engine.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            Image(systemName: "apple.intelligence")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(engine.availability.isReady ? HerdrTheme.accent : HerdrTheme.muted)

            Text("Local Apple Intelligence")
                .font(.headline)
                .foregroundStyle(engine.availability.isReady ? HerdrTheme.text : HerdrTheme.muted)

            Text("Ask questions, explain terminal output, or draft shell commands. All processing happens 100% on-device.")
                .font(.subheadline)
                .foregroundStyle(HerdrTheme.subtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                suggestionButton(icon: "terminal", title: "Explain terminal output", action: {
                    attachTerminalContext()
                    inputText = "Explain this terminal output and suggest the fix."
                })
                suggestionButton(icon: "magnifyingglass", title: "Find processes using high CPU", action: {
                    inputText = "What command shows top CPU consuming processes in Linux/macOS?"
                })
                suggestionButton(icon: "doc.badge.gearshape", title: "Write a cleanup script", action: {
                    inputText = "Write a one-liner to delete all dangling docker containers and images."
                })
            }
            .padding(.top, 10)
            .padding(.horizontal, 16)
            .opacity(engine.availability.isReady ? 1.0 : 0.45)
            .allowsHitTesting(engine.availability.isReady)

            Spacer(minLength: 40)
        }
    }

    private func suggestionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            guard engine.availability.isReady else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.accent)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!engine.availability.isReady)
    }

    // MARK: - Attached Context Pill
    private func attachedContextPill(context: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.caption)
                .foregroundStyle(HerdrTheme.accent)

            Text("Attached Context: \(Self.lineCount(of: context)) lines")
                .font(.caption.weight(.medium))
                .foregroundStyle(HerdrTheme.text)

            Spacer()

            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                attachedContext = nil
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .accessibilityLabel("Remove Attached Context")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(HerdrTheme.panel)
    }

    // MARK: - Input Bar
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Attach terminal context button
            Button(action: attachTerminalContext) {
                Image(systemName: attachedContext == nil ? "terminal" : "terminal.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        !engine.availability.isReady
                            ? HerdrTheme.muted
                            : (attachedContext == nil ? HerdrTheme.subtext : HerdrTheme.accent)
                    )
                    .frame(width: 32, height: 32)
                    .background(HerdrTheme.selection, in: Circle())
            }
            .disabled(!engine.availability.isReady)
            .accessibilityLabel("Attach Terminal Output")

            // Push-to-talk voice button
            voiceKey

            // Text input
            TextField(inputPlaceholder, text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.body)
                .foregroundStyle(engine.availability.isReady ? HerdrTheme.text : HerdrTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(HerdrTheme.selection, in: RoundedRectangle(cornerRadius: 12))
                .disabled(!engine.availability.isReady)
                .onSubmit {
                    if canSend {
                        sendMessage()
                    }
                }

            // Send / Stop button
            if engine.isGenerating {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.stopGeneration()
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Stop Generating")
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? HerdrTheme.accent : HerdrTheme.muted.opacity(0.5))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send Message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HerdrTheme.panel)
        .opacity(engine.availability.isReady ? 1.0 : 0.6)
    }

    // MARK: - Voice Push-To-Talk Button
    private var voiceKey: some View {
        Button(action: {}) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    !engine.availability.isReady
                        ? HerdrTheme.muted
                        : (isRecordingVoice ? Color.white : HerdrTheme.subtext)
                )
                .frame(width: 32, height: 32)
                .background(
                    isRecordingVoice ? Color.red.opacity(0.85) : HerdrTheme.selection,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(!engine.availability.isReady)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard engine.availability.isReady else { return }
                    if !isVoicePressed {
                        isVoicePressed = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task {
                            await voiceEngine.startRecording()
                        }
                    }
                }
                .onEnded { value in
                    guard engine.availability.isReady, isVoicePressed else { return }
                    isVoicePressed = false

                    if abs(value.translation.height) > 50 || abs(value.translation.width) > 50 {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        voiceEngine.cancelRecording()
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task {
                            if let text = await voiceEngine.stopRecording() {
                                if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    inputText = text
                                } else {
                                    inputText += " " + text
                                }
                            }
                        }
                    }
                }
        )
        .accessibilityLabel("Hold to Dictate")
    }

    // MARK: - Actions
    private func attachTerminalContext() {
        guard engine.availability.isReady else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let text = activeTerminalText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attachedContext = text
        }
    }

    private func sendMessage() {
        guard engine.availability.isReady else { return }
        let textToSend = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSend.isEmpty else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let contextToSend = attachedContext

        inputText = ""
        attachedContext = nil

        Task {
            await engine.sendPrompt(textToSend, terminalContext: contextToSend)
        }
    }
}
