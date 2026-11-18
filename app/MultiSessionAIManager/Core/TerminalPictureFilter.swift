import Foundation

/// Takes picture commands out of what a host sends to the terminal.
///
/// AI Manager does not show pictures. Its terminal engine (SwiftTerm's core)
/// nevertheless understands the kitty graphics protocol: it answers "supported"
/// when a program asks, and decodes and keeps every picture it is sent, while
/// the app, which draws the screen itself, shows none of them. A program was
/// told yes and its user saw an empty pane. With the commands removed here the
/// engine never sees a question to say yes to, and a program that asks gets the
/// answer a terminal without pictures gives: none.
///
/// A picture command is `ESC _ G <control> ; <data> ESC \`. Everything else,
/// other `ESC _` strings included, passes through byte for byte. Output arrives
/// in arbitrary pieces, so the filter remembers where it is between calls; the
/// one or two bytes that could still become the start of a command are held
/// back until the next piece settles it.
struct TerminalPictureFilter {
    private enum State {
        case text
        /// An `ESC` that may begin `ESC _ G`.
        case escape
        /// `ESC _`, one byte short of knowing whether a picture follows.
        case string
        /// Inside a picture command.
        case picture
        /// An `ESC` inside a picture command: its end if `\` follows.
        case pictureEscape
    }

    private static let esc: UInt8 = 0x1b

    private var state = State.text
    /// The start of the current command's control data, enough to read its action.
    private var control: [UInt8] = []
    private var controlEnded = false

    /// `bytes` without picture commands, and whether one of the removed commands
    /// draws something: sends or places a picture. A program only asking whether
    /// pictures are supported does not draw.
    mutating func strip(_ bytes: [UInt8]) -> (bytes: [UInt8], drew: Bool) {
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var drew = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch state {
            case .text:
                // The common case, a run of ordinary output, is copied in one go.
                if byte == Self.esc {
                    state = .escape
                    index += 1
                } else {
                    var end = index + 1
                    while end < bytes.count, bytes[end] != Self.esc { end += 1 }
                    kept.append(contentsOf: bytes[index..<end])
                    index = end
                }
            case .escape:
                if byte == 0x5f {               // _
                    state = .string
                } else if byte == Self.esc {
                    kept.append(Self.esc)       // the earlier one; this one may begin a command
                } else {
                    kept.append(Self.esc)
                    kept.append(byte)
                    state = .text
                }
                index += 1
            case .string:
                if byte == 0x47 {               // G
                    state = .picture
                    control.removeAll(keepingCapacity: true)
                    controlEnded = false
                    index += 1
                } else {
                    // Some other application string: not ours to touch.
                    kept.append(Self.esc)
                    kept.append(0x5f)
                    state = .text               // and look at this byte again as text
                }
            case .picture:
                if byte == Self.esc {
                    state = .pictureEscape
                } else if byte == 0x18 || byte == 0x1a {
                    // CAN and SUB abandon a string without ending it.
                    state = .text
                } else if !controlEnded {
                    if byte == 0x3b {           // ;
                        controlEnded = true
                    } else if control.count < 96 {
                        control.append(byte)
                    }
                }
                index += 1
            case .pictureEscape:
                if byte == 0x5c {               // \
                    if Self.draws(control) { drew = true }
                    state = .text
                    index += 1
                } else {
                    // The command was cut off by the start of something else.
                    state = .escape
                }
            }
        }
        return (kept, drew)
    }

    /// Whether a command with this control data sends or places a picture. The
    /// action defaults to sending one, which is also what the later pieces of a
    /// picture sent in several commands look like.
    private static func draws(_ control: [UInt8]) -> Bool {
        for pair in control.split(separator: 0x2c) where pair.count == 3 && pair.first == 0x61 {    // a=?
            guard let action = pair.last else { continue }
            return action != 0x71 && action != 0x64     // q asks, d deletes
        }
        return true
    }
}
