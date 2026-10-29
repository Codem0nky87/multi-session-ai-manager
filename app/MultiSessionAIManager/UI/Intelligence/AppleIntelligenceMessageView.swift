import SwiftUI

public struct AppleIntelligenceMessageView: View {
    public let message: AppleIntelligenceEngine.ChatMessage
    public let onInsertToTerminal: (String) -> Void

    @State private var copiedCodeID: String? = nil

    public init(
        message: AppleIntelligenceEngine.ChatMessage,
        onInsertToTerminal: @escaping (String) -> Void
    ) {
        self.message = message
        self.onInsertToTerminal = onInsertToTerminal
    }

    public var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            // Role Header
            HStack(spacing: 6) {
                if message.role == .user {
                    Spacer()
                    Text("You")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(HerdrTheme.subtext)
                    Image(systemName: "person.circle.fill")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.subtext)
                } else {
                    Image(systemName: "apple.intelligence")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.accent)
                    Text("Apple Intelligence")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(HerdrTheme.subtext)
                    Spacer()
                }
            }

            // Attached context badge if present on user message
            if let context = message.attachedTerminalContext, !context.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "terminal.fill")
                        .font(.caption2)
                    let lineCount = context.components(separatedBy: "\n").count
                    Text("Attached Terminal Output (\(lineCount) lines)")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(HerdrTheme.panel.opacity(0.8), in: Capsule())
                .foregroundStyle(HerdrTheme.subtext)
            }

            // Message Bubble Content
            if message.role == .user {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(HerdrTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            } else {
                assistantMessageContent
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var assistantMessageContent: some View {
        let segments = CodeBlockExtractor.parse(markdown: message.content)

        VStack(alignment: .leading, spacing: 10) {
            if segments.isEmpty && message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Thinking...")
                        .font(.subheadline)
                        .foregroundStyle(HerdrTheme.subtext)
                }
                .padding(8)
            } else {
                ForEach(segments, id: \.id) { segment in
                    Group {
                        switch segment.type {
                        case .text(let text):
                            Text(LocalizedStringKey(text))
                                .font(.body)
                                .foregroundStyle(HerdrTheme.text)
                                .textSelection(.enabled)
                        case .codeBlock(let code, let language):
                            codeBlockView(code: code, language: language, id: segment.id)
                        }
                    }
                }

                if message.isStreaming {
                    Circle()
                        .fill(HerdrTheme.accent)
                        .frame(width: 8, height: 8)
                        .opacity(0.8)
                }
            }
        }
        .padding(12)
        .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func codeBlockView(code: String, language: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with language, Copy button, and Insert into Terminal button
            HStack(spacing: 8) {
                Text((language ?? "code").uppercased())
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(HerdrTheme.muted)

                Spacer()

                // Copy button
                Button {
                    UIPasteboard.general.string = code
                    copiedCodeID = id
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if copiedCodeID == id { copiedCodeID = nil }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedCodeID == id ? "checkmark" : "doc.on.doc")
                        Text(copiedCodeID == id ? "Copied" : "Copy")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(HerdrTheme.subtext)
                }
                .buttonStyle(.plain)

                // Insert into Terminal button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onInsertToTerminal(code)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                        Text("Insert")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HerdrTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(HerdrTheme.selection, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HerdrTheme.selection.opacity(0.5))

            Divider()

            // Code body
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(HerdrTheme.mono(.footnote))
                    .foregroundStyle(HerdrTheme.text)
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(HerdrTheme.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(HerdrTheme.selection, lineWidth: 1))
    }
}
