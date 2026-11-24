import SwiftUI

/// The sign-in a site asked for, shown over its page in the browser's pane.
struct HostBrowserSignInCard: View {
    let request: HostBrowserSignInRequest
    let signIn: (_ user: String, _ password: String) -> Void
    let cancel: () -> Void

    private enum Field { case user, password }

    @State private var user = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    var body: some View {
        // A pane can be short, and shorter still with the keyboard up.
        ViewThatFits(in: .vertical) {
            card
            ScrollView { card }
        }
        .onAppear(perform: start)
        .onChange(of: request.id) { _, _ in start() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-space.sign-in")
    }

    private var card: some View {
        VStack(spacing: Theme.Space.md) {
            Text(request.title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(request.message)
                .font(Theme.body(13))
                .foregroundStyle(request.isSentUnprotected ? Theme.warning : Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if request.wasRefused {
                Text("That user name or password was not accepted.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("browser-space.sign-in.refused")
            }
            VStack(spacing: Theme.Space.sm) {
                TextField("", text: $user,
                          prompt: Text(request.kind == .windows ? "DOMAIN\\name" : "User name").foregroundColor(Theme.textMuted))
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focus, equals: .user)
                    .onSubmit { focus = .password }
                    .accessibilityLabel("User name")
                    .accessibilityIdentifier("browser-space.sign-in.user")
                    .modifier(Entry())
                SecureField("", text: $password, prompt: Text("Password").foregroundColor(Theme.textMuted))
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
                    .accessibilityLabel("Password")
                    .accessibilityIdentifier("browser-space.sign-in.password")
                    .modifier(Entry())
            }
            HStack(spacing: Theme.Space.sm) {
                Button("Cancel", action: cancel)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("browser-space.sign-in.cancel")
                Button("Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(user.isEmpty)
                    .accessibilityIdentifier("browser-space.sign-in.submit")
            }
        }
        .frame(maxWidth: 360)
        .padding(Theme.Space.lg)
    }

    private struct Entry: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(Theme.body(15))
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    /// A name that was turned down stays, to be corrected. A password is always
    /// typed again.
    private func start() {
        user = request.user
        password = ""
        focus = request.user.isEmpty ? .user : .password
    }

    private func submit() {
        guard !user.isEmpty else {
            focus = .user
            return
        }
        signIn(user, password)
    }
}
