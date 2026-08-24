import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Receives a file the host queued and hands it to iPadOS.
///
/// The file is already downloaded by the time this appears -- the sheet exists
/// to preview it and to route it somewhere the iPad can keep it, which is what
/// `Save to Files` and the share sheet are for.
struct IncomingFileSheet: View {
    let file: IncomingFile
    let onDone: () -> Void

    @State private var showingExporter = false
    @State private var showingShare = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(HerdrTheme.selection)
            preview
            Divider().overlay(HerdrTheme.selection)
            footer
        }
        .background(HerdrTheme.background)
        .preferredColorScheme(.dark)
        .fileExporter(
            isPresented: $showingExporter,
            document: IncomingFileDocument(file: file),
            // The name it had on the host, not the generated one the UPLOAD
            // path uses: this file already has a name the user chose.
            contentType: Self.contentType(for: file),
            defaultFilename: file.displayName
        ) { _ in onDone() }
        .sheet(isPresented: $showingShare) {
            ShareSheet(items: [Self.temporaryURL(for: file)].compactMap { $0 })
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(HerdrTheme.mono(.footnote, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(1)
                Text(FileSendSheet.sizeLabel(file.byteCount))
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer()
            Button("Done", action: onDone)
                .font(HerdrTheme.mono(.footnote))
                .foregroundStyle(HerdrTheme.subtext)
        }
        .padding(.horizontal, 16)
        .frame(height: HerdrChromeMetrics.headerHeight)
        .background(HerdrTheme.panel)
    }

    @ViewBuilder private var preview: some View {
        if let image = UIImage(data: file.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(16)
                .accessibilityIdentifier("msam.incoming.preview")
        } else if let document = PDFDocument(data: file.data) {
            PDFPreview(document: document)
                .accessibilityIdentifier("msam.incoming.preview")
        } else if let text = Self.previewText(for: file) {
            ScrollView {
                Text(text)
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .accessibilityIdentifier("msam.incoming.preview")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 44))
                    .foregroundStyle(HerdrTheme.accent)
                Text("No preview")
                    .font(HerdrTheme.mono(.footnote))
                    .foregroundStyle(HerdrTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("msam.incoming.preview")
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(file.remotePath)
                .font(HerdrTheme.mono(.caption))
                .foregroundStyle(HerdrTheme.muted)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Share") { showingShare = true }
                .font(HerdrTheme.mono(.footnote))
                .foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
                .accessibilityIdentifier("msam.incoming.share")
            Button("Save to Files") { showingExporter = true }
                .font(HerdrTheme.mono(.footnote, weight: .semibold))
                .foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: HerdrChromeMetrics.minimumHitTarget)
                .accessibilityIdentifier("msam.incoming.save")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HerdrTheme.panel)
    }

    // MARK: - Helpers

    /// Best-effort type from the extension, falling back to raw data.
    ///
    /// `.data` rather than guessing: a wrong content type makes Files refuse the
    /// save outright, whereas the generic one always works and merely loses the
    /// icon.
    ///
    /// `UTType(filenameExtension:)` does NOT return nil for an extension the
    /// system does not know -- it mints a DYNAMIC type (`dyn.ah62d4...`), which
    /// is precisely the sort the exporter can reject. Only a type the system
    /// actually recognises is worth passing on.
    static func contentType(for file: IncomingFile) -> UTType {
        guard !file.fileExtension.isEmpty,
              let type = UTType(filenameExtension: file.fileExtension),
              !type.isDynamic
        else { return .data }
        return type
    }

    /// Only decode as text when it really is text -- a binary rendered as
    /// replacement characters is worse than saying there is no preview.
    static func previewText(for file: IncomingFile, limit: Int = 200_000) -> String? {
        guard file.byteCount <= limit else { return nil }
        guard let text = String(data: file.data, encoding: .utf8) else { return nil }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }

    /// The share sheet takes a URL, so the bytes are staged in a temp file named
    /// the way the host named them -- sharing "Untitled" would lose the name.
    static func temporaryURL(for file: IncomingFile) -> URL? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msam-incoming", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.displayName)
            try file.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// Wraps the downloaded bytes for `.fileExporter`.
struct IncomingFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let file: IncomingFile

    init(file: IncomingFile) { self.file = file }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: file.data)
    }
}

struct PDFPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.document = document
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
