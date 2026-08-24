import SwiftUI
import Observation

/// App-wide transient feedback. Show a toast after any meaningful action
/// (key installed, session started, copied, error) so the user always gets
/// confirmation — satisfies `success-feedback`, `error-recovery`, `toast-dismiss`.
@MainActor @Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case success, error, info }
    }
    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func success(_ text: String) { show(.init(text: text, kind: .success)) }
    func error(_ text: String)   { show(.init(text: text, kind: .error)) }
    func info(_ text: String)    { show(.init(text: text, kind: .info)) }

    private func show(_ toast: Toast) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { withAnimation(Theme.spring) { self?.current = nil } }
        }
    }
}

private struct ToastView: View {
    let toast: ToastCenter.Toast
    private var color: Color {
        switch toast.kind { case .success: Theme.success; case .error: Theme.danger; case .info: Theme.accent }
    }
    private var icon: String {
        switch toast.kind { case .success: "checkmark.circle.fill"; case .error: "exclamationmark.triangle.fill"; case .info: "info.circle.fill" }
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(toast.text).font(Theme.label(14)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.bgElevated)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(color.opacity(0.4)))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// Host toasts at the top of a screen. Place once near the app root.
    func toastHost(_ center: ToastCenter) -> some View {
        overlay(alignment: .top) {
            if let toast = center.current {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 6)
            }
        }
        .animation(Theme.spring, value: center.current)
    }
}
