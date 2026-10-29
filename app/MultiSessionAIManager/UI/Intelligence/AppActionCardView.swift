import SwiftUI

public struct AppActionCardView: View {
    public enum State: Equatable, Sendable {
        case pending
        case executing
        case applied
        case failed(String)
    }

    public let action: AppAction
    public let onApply: () async throws -> Void
    public let onDismiss: () -> Void

    @SwiftUI.State public var state: State

    public init(
        action: AppAction,
        initialState: State = .pending,
        onApply: @escaping () async throws -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.action = action
        self._state = SwiftUI.State(initialValue: initialState)
        self.onApply = onApply
        self.onDismiss = onDismiss
    }

    public static func title(for action: AppAction) -> String {
        switch action {
        case .splitPane(let dir, _):
            return dir == .right ? "Split Pane Right" : "Split Pane Down"
        case .closePane:
            return "Close Pane"
        case .zoomPane:
            return "Toggle Pane Zoom"
        case .createHerdrTab(let label, _):
            return "Create Tab: \(label)"
        case .switchHostTab(let name):
            return "Switch to \(name)"
        case .openHostTab(let hostName):
            return "Open Tab: \(hostName)"
        case .openAppSheet(let sheet):
            return "Open \(sheet.rawValue.capitalized) Sheet"
        }
    }

    public static func iconName(for action: AppAction) -> String {
        switch action {
        case .splitPane(let dir, _):
            return dir == .right ? "rectangle.split.2x1.fill" : "rectangle.split.1x2.fill"
        case .closePane:
            return "xmark.rectangle.fill"
        case .zoomPane:
            return "arrow.up.left.and.arrow.down.right"
        case .createHerdrTab:
            return "plus.rectangle.fill"
        case .switchHostTab, .openHostTab:
            return "macwindow.on.rectangle"
        case .openAppSheet(let sheet):
            switch sheet {
            case .metrics:
                return "chart.bar.fill"
            case .pulse:
                return "waveform.path.ecg"
            case .settings:
                return "gearshape.fill"
            }
        }
    }

    public static func stagedCommand(for action: AppAction) -> String? {
        switch action {
        case .splitPane(_, let cmd), .createHerdrTab(_, let cmd):
            return cmd
        default:
            return nil
        }
    }

    public static func transition(
        from currentState: State,
        onApply: () async throws -> Void
    ) async -> State {
        do {
            try await onApply()
            return .applied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: Self.iconName(for: action))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HerdrTheme.accent)

                Text(Self.title(for: action))
                    .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)

                Spacer()

                if state == .applied {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(HerdrTheme.green)
                        Text("Applied")
                            .font(HerdrTheme.mono(.caption, weight: .medium))
                            .foregroundStyle(HerdrTheme.green)
                    }
                    .accessibilityIdentifier("msam.action.applied")
                }
            }

            if let cmd = Self.stagedCommand(for: action), !cmd.isEmpty {
                HStack(spacing: 6) {
                    Text("Staged:")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)
                    Text(cmd)
                        .font(HerdrTheme.mono(.caption))
                        .foregroundStyle(HerdrTheme.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(HerdrTheme.selection)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if case .failed(let reason) = state {
                Text("⚠️ \(reason)")
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.red)
            }

            if state != .applied {
                HStack(spacing: 8) {
                    Button {
                        state = .executing
                        Task {
                            state = await Self.transition(from: state, onApply: onApply)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if state == .executing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Applying...")
                            } else {
                                Text(state == .pending ? "Apply Action" : "Retry")
                            }
                        }
                        .font(HerdrTheme.mono(.caption, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(HerdrTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(state == .executing)
                    .accessibilityIdentifier("msam.action.apply")

                    Button("Dismiss") {
                        onDismiss()
                    }
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.subtext)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("msam.action.dismiss")
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(HerdrTheme.activeRow)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(HerdrTheme.selection, lineWidth: 1)
        )
        .accessibilityIdentifier("msam.action.card")
    }
}
