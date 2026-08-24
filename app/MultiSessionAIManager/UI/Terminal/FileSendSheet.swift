import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sends a file from the iPad to the open tab's host.
///
/// A terminal carries text, so there is no "paste a file into Herdr". What this
/// does instead is upload the bytes over the tab's own SSH connection and type
/// the resulting absolute path into the pane, which is the form an agent wants
/// anyway — it can then read the PDF, the screenshot, or the log.
///
/// Three sources, because an iPad has three places a file lives: the clipboard
/// (a screenshot you just copied), Photos, and Files. The clipboard is offered
/// but never used silently — `hasImage` is true for ANY image sitting there,
/// possibly copied hours ago in another app, so it is always shown first.
struct FileSendSheet: View {
    let session: HerdrHostSession
    let hostName: String
    let onFinished: (String) -> Void
    let onCancel: () -> Void

    @State private var staged: OutgoingFile?
    /// Set on first appearance, so re-renders never re-read the clipboard over
    /// a file the user has since chosen.
    @State private var checkedClipboard = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(HerdrTheme.selection)
            content
            Divider().overlay(HerdrTheme.selection)
            footer
        }
        .background(HerdrTheme.background)
        .preferredColorScheme(.dark)
        .photosPicker(isPresented: $showingPhotos, selection: $pickerItem, matching: .images)
        .fileImporter(
            isPresented: $showingFiles,
            // Any file: a PDF to read, a log to analyse, a CSV to chart. The
            // upload path never inspected the bytes, so nothing here needs to.
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadFromPhotos(item) }
        }
        .task {
            guard !checkedClipboard else { return }
            checkedClipboard = true
            pasteFromClipboard()
        }
    }

    private var header: some View {
        HStack {
            Text("Send to \(hostName)")
                .font(HerdrTheme.mono(.footnote, weight: .semibold))
                .foregroundStyle(HerdrTheme.text)
            Spacer()
            Button("Cancel", action: onCancel)
                .font(HerdrTheme.mono(.footnote))
                .foregroundStyle(HerdrTheme.subtext)
                .disabled(isSending)
        }
        .padding(.horizontal, 16)
        .frame(height: HerdrChromeMetrics.headerHeight)
        .background(HerdrTheme.panel)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            if let staged {
                if let preview = staged.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .accessibilityIdentifier("msam.file.preview")
                } else {
                    // A PDF or a log has no thumbnail worth rendering; name,
                    // type and size are what tell the user they picked right.
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 44))
                            .foregroundStyle(HerdrTheme.accent)
                        Text(staged.displayName)
                            .font(HerdrTheme.mono(.footnote, weight: .semibold))
                            .foregroundStyle(HerdrTheme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(Self.sizeLabel(staged.byteCount))
                            .font(HerdrTheme.mono(.caption))
                            .foregroundStyle(HerdrTheme.muted)
                    }
                    .padding(24)
                    .accessibilityIdentifier("msam.file.preview")
                }
            } else {
                Text("Nothing chosen")
                    .font(HerdrTheme.mono(.footnote))
                    .foregroundStyle(HerdrTheme.muted)
            }
            if isSending {
                HerdrTheme.background.opacity(0.75)
                ProgressView("Uploading…")
                    .font(HerdrTheme.mono(.footnote))
                    .tint(HerdrTheme.accent)
                    .foregroundStyle(HerdrTheme.text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let failure {
                Text(failure)
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("msam.file.error")
            }
            HStack(spacing: 16) {
                sourceButton("Paste", "doc.on.clipboard", "msam.file.paste", pasteFromClipboard)
                sourceButton("Photos", "photo", "msam.file.photos") { showingPhotos = true }
                sourceButton("Files", "folder", "msam.file.files") { showingFiles = true }

                Spacer()

                Button(action: send) {
                    Text("Send")
                        .font(HerdrTheme.mono(.footnote, weight: .semibold))
                        .foregroundStyle(staged == nil || isSending ? HerdrTheme.muted : HerdrTheme.accent)
                        .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
                }
                .disabled(staged == nil || isSending)
                .accessibilityIdentifier("msam.file.send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HerdrTheme.panel)
    }

    private func sourceButton(
        _ title: String,
        _ symbol: String,
        _ identifier: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title).font(HerdrTheme.mono(.caption))
            }
            .foregroundStyle(isSending ? HerdrTheme.muted : HerdrTheme.accent)
            .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
        }
        .disabled(isSending)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Sources

    private func pasteFromClipboard() {
        guard let image = PasteboardImageReader.image(from: .general) else { return }
        stage(imageFromPixels: image, displayName: "Pasted image")
    }

    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        failure = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                failure = "That item is not an image."
                return
            }
            stage(imageFromPixels: image, displayName: "Photo")
        } catch {
            failure = "Could not read that image: \(error.localizedDescription)"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        failure = nil
        switch result {
        case .failure(let error):
            failure = "Could not open that file: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                // Byte-for-byte, under its own extension: re-encoding somebody's
                // document would be a surprise, and only images can be re-encoded
                // at all.
                staged = try LocalFileLoader.load(from: url)
            } catch {
                failure = Self.message(for: error)
            }
        }
    }

    /// Images that arrived as PIXELS (clipboard, Photos) are normalised to PNG:
    /// an iPad hands back HEIC, which plenty of tools on a Linux host cannot open.
    private func stage(imageFromPixels image: UIImage, displayName: String) {
        guard let png = RemoteFileUpload.pngData(from: image) else {
            failure = "Could not encode that image as PNG."
            return
        }
        failure = nil
        staged = OutgoingFile(data: png, fileExtension: "png", displayName: displayName)
    }

    // MARK: - Send

    private func send() {
        guard let staged, !isSending else { return }
        isSending = true
        failure = nil
        Task {
            do {
                let path = try await session.sendFile(
                    staged.data,
                    fileExtension: staged.fileExtension
                )
                isSending = false
                onFinished(path)
            } catch {
                isSending = false
                failure = Self.message(for: error)
            }
        }
    }

    // MARK: - Messages

    static func sizeLabel(_ byteCount: Int) -> String {
        let mb = Double(byteCount) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(byteCount) / 1024)
    }

    static func message(for error: Error) -> String {
        if let failure = error as? RemoteFileUpload.Failure {
            switch failure {
            case .emptyFile:
                return "That file is empty."
            case .tooLarge(let byteCount):
                let limit = RemoteFileUpload.maximumByteCount / 1_048_576
                return "That file is \(sizeLabel(byteCount)); the limit is \(limit) MB."
            case .homeUnresolved:
                return "The host did not report a home directory, so there is nowhere to put the file."
            case .uploadFailed(let reason):
                return "Upload failed: \(reason)"
            }
        }
        if let failure = error as? LocalFileLoader.Failure {
            switch failure {
            case .unreadable: return "That file could not be read."
            case .empty: return "That file is empty."
            }
        }
        return "Upload failed: \(error.localizedDescription)"
    }
}
