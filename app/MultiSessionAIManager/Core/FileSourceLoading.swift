import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit

/// A file staged for upload, whatever it came from — the clipboard, Photos, or
/// the Files app.
struct OutgoingFile: Equatable {
    let data: Data
    /// Already sanitized by `RemoteFileUpload.sanitizedExtension`.
    let fileExtension: String
    /// Shown in the sheet only. Never used to build the remote path.
    let displayName: String

    var byteCount: Int { data.count }

    /// A thumbnail, when the bytes happen to be an image. `nil` for a PDF or a
    /// source file, which the sheet renders as an icon and a name instead.
    var previewImage: UIImage? { UIImage(data: data) }
}

/// Pulls an image off a pasteboard, tolerating the several shapes one can
/// arrive in.
///
/// `UIPasteboard.image` alone is not enough: it covers the common case, but an
/// image copied out of Safari, Photos, or another app can land as raw data
/// under a type UIKit does not auto-promote (HEIC being the usual culprit on an
/// iPad), or as a file URL when it was copied in Files.
enum PasteboardImageReader {

    static func image(from pasteboard: UIPasteboard) -> UIImage? {
        if let direct = pasteboard.image { return direct }

        // Any declared type that CONFORMS to public.image, rather than a hard
        // coded list -- that way a format added to iOS later works without a
        // change here.
        for identifier in pasteboard.types {
            guard let type = UTType(identifier),
                  type.conforms(to: .image),
                  let data = pasteboard.data(forPasteboardType: identifier),
                  let image = UIImage(data: data)
            else { continue }
            return image
        }

        // Copying a file in Files puts a URL on the pasteboard, not pixels.
        if let url = pasteboard.url, let image = try? LocalImageLoader.load(from: url) {
            return image
        }
        return nil
    }

    /// Whether tapping Paste would produce anything. Cheaper than decoding.
    static func hasImage(_ pasteboard: UIPasteboard) -> Bool {
        if pasteboard.hasImages { return true }
        return pasteboard.types.contains { UTType($0)?.conforms(to: .image) == true }
    }
}

/// Reads a file of ANY type from a URL — the Files app, a share sheet, or
/// anywhere else that hands back a URL rather than bytes.
enum LocalFileLoader {
    enum Failure: Error, Equatable {
        case unreadable
        case empty
    }

    static func load(from url: URL) throws -> OutgoingFile {
        let data = try readBytes(at: url)
        guard !data.isEmpty else { throw Failure.empty }
        return OutgoingFile(
            data: data,
            fileExtension: RemoteFileUpload.sanitizedExtension(url.pathExtension),
            displayName: url.lastPathComponent
        )
    }

    static func readBytes(at url: URL) throws -> Data {
        // A URL from the Files app lives outside the app container and must be
        // opened inside a security scope. `startAccessingSecurityScopedResource`
        // returns false for URLs that are not scoped -- so a `guard` on it would
        // reject perfectly readable in-container URLs while looking like careful
        // code. Take the scope when granted, release only what was taken, and
        // let the read itself decide whether the URL was usable.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return data
    }
}

/// The image-only view of `LocalFileLoader`, used when following an image URL
/// off the pasteboard.
enum LocalImageLoader {
    enum Failure: Error, Equatable {
        case unreadable
        case notAnImage
    }

    static func load(from url: URL) throws -> UIImage {
        let data: Data
        do {
            data = try LocalFileLoader.readBytes(at: url)
        } catch {
            throw Failure.unreadable
        }
        guard let image = UIImage(data: data) else { throw Failure.notAnImage }
        return image
    }
}
#endif
