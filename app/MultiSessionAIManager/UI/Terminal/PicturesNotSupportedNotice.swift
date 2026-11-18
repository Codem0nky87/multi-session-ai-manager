import SwiftUI

/// Shown over a terminal while a program on the host draws pictures in it.
///
/// AI Manager shows none, so the pane such a program fills stays empty, and the
/// pictures it keeps sending can take the whole connection. Without this the
/// user sees a blank, sluggish tab and no reason for it.
struct PicturesNotSupportedNotice: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pictures are not supported")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("A program on this host is drawing pictures in the terminal. AI Manager cannot show them, and they can make this tab slow to respond. Quit that program to carry on: Ctrl+Q in terminal-browser, Ctrl+C in most others.")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("terminal.pictures.dismiss")
        }
        .padding(.leading, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(Theme.warning.opacity(0.5), lineWidth: 1)
                )
        )
        .frame(maxWidth: 560)
        .padding(Theme.Space.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.pictures.notice")
    }
}
