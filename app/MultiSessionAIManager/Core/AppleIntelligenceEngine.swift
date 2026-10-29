import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

public protocol LanguageModelBackend: Sendable {
    func checkAvailability() -> AppleIntelligenceEngine.AvailabilityState
    func streamResponse(
        to prompt: String,
        context: String?,
        history: [AppleIntelligenceEngine.ChatMessage]
    ) -> AsyncThrowingStream<String, Error>
}

public final class AppleFoundationModelsBackend: LanguageModelBackend, @unchecked Sendable {
    public init() {}

    public func checkAvailability() -> AppleIntelligenceEngine.AvailabilityState {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unsupported(
                        reason: "Apple Intelligence is required for on-device foundation models. Available on M-series iPads and iPhone 15 Pro / iPhone 16+."
                    )
                case .appleIntelligenceNotEnabled:
                    return .notEnabled(
                        reason: "Apple Intelligence is turned off. Turn it on in Settings > Apple Intelligence & Siri to use Apple Intelligence."
                    )
                case .modelNotReady:
                    return .downloading(
                        reason: "Apple Intelligence model assets are downloading or preparing. Connect to Wi-Fi and power to complete download."
                    )
                @unknown default:
                    return .unsupported(
                        reason: "Apple Intelligence foundation model is unavailable: \(reason)"
                    )
                }
            }
        }
        #endif
        return .unsupported(
            reason: "Apple Intelligence is required for on-device foundation models. Available on M-series iPads and iPhone 15 Pro / iPhone 16+."
        )
    }

    public func streamResponse(
        to prompt: String,
        context: String?,
        history: [AppleIntelligenceEngine.ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let session = LanguageModelSession()
                        var combinedPrompt = ""
                        if let context, !context.isEmpty {
                            combinedPrompt += "Active terminal output context:\n```\n\(context)\n```\n\n"
                        }
                        combinedPrompt += prompt

                        let response = try await session.respond(to: combinedPrompt)
                        continuation.yield(response.content)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        #endif
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: NSError(
                    domain: "AppleIntelligence",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence Foundation Models are not available on this device."]
                )
            )
        }
    }
}

@MainActor
@Observable
public final class AppleIntelligenceEngine {
    public static let shared = AppleIntelligenceEngine()

    public enum AvailabilityState: Equatable, Sendable {
        case checking
        case available
        case downloading(reason: String)
        case notEnabled(reason: String)
        case unsupported(reason: String)

        public var isReady: Bool {
            self == .available
        }
    }

    public struct ChatMessage: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let role: Role
        public var content: String
        public let timestamp: Date
        public var attachedTerminalContext: String?
        public var isStreaming: Bool

        public enum Role: String, Sendable {
            case user
            case assistant
            case system
        }

        public init(
            id: UUID = UUID(),
            role: Role,
            content: String,
            timestamp: Date = Date(),
            attachedTerminalContext: String? = nil,
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.timestamp = timestamp
            self.attachedTerminalContext = attachedTerminalContext
            self.isStreaming = isStreaming
        }
    }

    public private(set) var availability: AvailabilityState = .checking
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isGenerating: Bool = false

    private let backend: LanguageModelBackend
    private var generationTask: Task<Void, Never>?

    public init(backend: LanguageModelBackend = AppleFoundationModelsBackend()) {
        self.backend = backend
        checkAvailability()
    }

    public func checkAvailability() {
        availability = backend.checkAvailability()
    }

    public func sendPrompt(_ text: String, terminalContext: String? = nil) async {
        guard availability.isReady else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(
            role: .user,
            content: trimmed,
            attachedTerminalContext: terminalContext
        )
        messages.append(userMessage)

        let assistantMessageID = UUID()
        let assistantMessage = ChatMessage(
            id: assistantMessageID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        messages.append(assistantMessage)
        isGenerating = true

        generationTask = Task {
            do {
                let stream = backend.streamResponse(
                    to: trimmed,
                    context: terminalContext,
                    history: messages
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    if let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                        messages[index].content += chunk
                    }
                }
            } catch {
                if let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                    if messages[index].content.isEmpty {
                        messages[index].content = "⚠️ Unable to generate response: \(error.localizedDescription)"
                    }
                }
            }

            if let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                messages[index].isStreaming = false
            }
            isGenerating = false
        }

        await generationTask?.value
    }

    public func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        if let lastIndex = messages.indices.last, messages[lastIndex].isStreaming {
            messages[lastIndex].isStreaming = false
        }
    }

    public func clearHistory() {
        stopGeneration()
        messages.removeAll()
    }
}
