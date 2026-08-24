import Foundation
import UIKit

enum TerminalClipboardPayload: Equatable {
    case text(String)
}

protocol TerminalPasteboardReading {
    var hasStrings: Bool { get }
    var string: String? { get }
}

extension UIPasteboard: TerminalPasteboardReading {}

enum TerminalClipboard {
    static func canPaste(from pasteboard: TerminalPasteboardReading) -> Bool {
        pasteboard.hasStrings
    }

    static func payload(from pasteboard: TerminalPasteboardReading) -> TerminalClipboardPayload? {
        if let text = pasteboard.string, !text.isEmpty {
            return .text(text)
        }

        return nil
    }
}
