//
//  TerminalVT100.swift
//  MultiSessionAIManager
//
//  VT100 rendering helpers ported from NewTerm (hbang/NewTerm, MIT) and adapted
//  for this app: a clean dark theme, no NewTerm-Common dependencies.
//
//  This file collects the small shared primitives the renderer needs:
//    - `UTF8Char` alias + the `controlCharacter` / `utf8Array` helpers
//    - `EscapeSequences` (keyboard -> wire bytes for special keys)
//    - `UnicodeUtil` (display column width for runes, for cell sizing)
//

import Foundation

/// A single byte on the wire. NewTerm calls this `UTF8Char`; we keep the name so
/// the ported helpers read identically to the reference.
typealias UTF8Char = UInt8

extension UTF8Char {
    /// Translate an ASCII byte to its Ctrl-modified control code (Ctrl-A == 0x01, etc).
    var controlCharacter: UTF8Char {
        var newCharacter = self
        // Translate capital to lowercase
        if self >= 0x41 && self <= 0x5A { // >= 'A' <= 'Z'
            newCharacter += 0x61 - 0x41 // 'a' - 'A'
        }
        // Convert to the matching control character
        if self >= 0x61 && self <= 0x7A { // >= 'a' <= 'z'
            newCharacter -= 0x61 - 1 // 'a' - 1
        }
        return newCharacter
    }
}

extension String {
    /// The UTF-8 bytes of this string as a `[UTF8Char]`.
    var utf8Array: [UTF8Char] { Array(utf8) }
}

/// Keyboard -> wire byte sequences for special keys. Ported verbatim from NewTerm's
/// `EscapeSequences` (the canonical xterm sequences).
enum EscapeSequences {
    static let backspace = "\u{7f}".utf8Array
    static let meta      = "\u{1b}".utf8Array
    static let tab       = "\t".utf8Array
    static let `return`  = "\r".utf8Array

    static let up        = "\u{1b}[A".utf8Array
    static let upApp     = "\u{1b}OA".utf8Array
    static let down      = "\u{1b}[B".utf8Array
    static let downApp   = "\u{1b}OB".utf8Array
    static let left      = "\u{1b}[D".utf8Array
    static let leftApp   = "\u{1b}OD".utf8Array
    static let leftMeta  = "b".utf8Array
    static let right     = "\u{1b}[C".utf8Array
    static let rightApp  = "\u{1b}OC".utf8Array
    static let rightMeta = "f".utf8Array

    static let home      = "\u{1b}[H".utf8Array
    static let homeApp   = "\u{1b}OH".utf8Array
    static let end       = "\u{1b}[F".utf8Array
    static let endApp    = "\u{1b}OF".utf8Array
    static let pageUp    = "\u{1b}[5~".utf8Array
    static let pageDown  = "\u{1b}[6~".utf8Array
    static let delete    = "\u{1b}[3~".utf8Array

    static let fn = [
        "OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~"
    ].map { "\u{1b}\($0)".utf8Array }
}

/// Display-column width of Unicode runes, used to size each glyph run so wide
/// (CJK / emoji) characters reserve two cells. Ported from NewTerm's `UnicodeUtil`
/// (itself adapted from SwiftTerm/wcwidth).
enum UnicodeUtil {
    private struct LH {
        var lo: UInt32
        var hi: UInt32
    }

    private static let combining: [LH] = [
        LH(lo: 0x0300, hi: 0x036F), LH(lo: 0x0483, hi: 0x0486), LH(lo: 0x0488, hi: 0x0489),
        LH(lo: 0x0591, hi: 0x05BD), LH(lo: 0x05BF, hi: 0x05BF), LH(lo: 0x05C1, hi: 0x05C2),
        LH(lo: 0x05C4, hi: 0x05C5), LH(lo: 0x05C7, hi: 0x05C7), LH(lo: 0x0600, hi: 0x0603),
        LH(lo: 0x0610, hi: 0x0615), LH(lo: 0x064B, hi: 0x065E), LH(lo: 0x0670, hi: 0x0670),
        LH(lo: 0x06D6, hi: 0x06E4), LH(lo: 0x06E7, hi: 0x06E8), LH(lo: 0x06EA, hi: 0x06ED),
        LH(lo: 0x070F, hi: 0x070F), LH(lo: 0x0711, hi: 0x0711), LH(lo: 0x0730, hi: 0x074A),
        LH(lo: 0x07A6, hi: 0x07B0), LH(lo: 0x07EB, hi: 0x07F3), LH(lo: 0x0901, hi: 0x0902),
        LH(lo: 0x093C, hi: 0x093C), LH(lo: 0x0941, hi: 0x0948), LH(lo: 0x094D, hi: 0x094D),
        LH(lo: 0x0951, hi: 0x0954), LH(lo: 0x0962, hi: 0x0963), LH(lo: 0x0981, hi: 0x0981),
        LH(lo: 0x09BC, hi: 0x09BC), LH(lo: 0x09C1, hi: 0x09C4), LH(lo: 0x09CD, hi: 0x09CD),
        LH(lo: 0x09E2, hi: 0x09E3), LH(lo: 0x0A01, hi: 0x0A02), LH(lo: 0x0A3C, hi: 0x0A3C),
        LH(lo: 0x0A41, hi: 0x0A42), LH(lo: 0x0A47, hi: 0x0A48), LH(lo: 0x0A4B, hi: 0x0A4D),
        LH(lo: 0x0A70, hi: 0x0A71), LH(lo: 0x0A81, hi: 0x0A82), LH(lo: 0x0ABC, hi: 0x0ABC),
        LH(lo: 0x0AC1, hi: 0x0AC5), LH(lo: 0x0AC7, hi: 0x0AC8), LH(lo: 0x0ACD, hi: 0x0ACD),
        LH(lo: 0x0AE2, hi: 0x0AE3), LH(lo: 0x0B01, hi: 0x0B01), LH(lo: 0x0B3C, hi: 0x0B3C),
        LH(lo: 0x0B3F, hi: 0x0B3F), LH(lo: 0x0B41, hi: 0x0B43), LH(lo: 0x0B4D, hi: 0x0B4D),
        LH(lo: 0x0B56, hi: 0x0B56), LH(lo: 0x0B82, hi: 0x0B82), LH(lo: 0x0BC0, hi: 0x0BC0),
        LH(lo: 0x0BCD, hi: 0x0BCD), LH(lo: 0x0C3E, hi: 0x0C40), LH(lo: 0x0C46, hi: 0x0C48),
        LH(lo: 0x0C4A, hi: 0x0C4D), LH(lo: 0x0C55, hi: 0x0C56), LH(lo: 0x0CBC, hi: 0x0CBC),
        LH(lo: 0x0CBF, hi: 0x0CBF), LH(lo: 0x0CC6, hi: 0x0CC6), LH(lo: 0x0CCC, hi: 0x0CCD),
        LH(lo: 0x0CE2, hi: 0x0CE3), LH(lo: 0x0D41, hi: 0x0D43), LH(lo: 0x0D4D, hi: 0x0D4D),
        LH(lo: 0x0DCA, hi: 0x0DCA), LH(lo: 0x0DD2, hi: 0x0DD4), LH(lo: 0x0DD6, hi: 0x0DD6),
        LH(lo: 0x0E31, hi: 0x0E31), LH(lo: 0x0E34, hi: 0x0E3A), LH(lo: 0x0E47, hi: 0x0E4E),
        LH(lo: 0x0EB1, hi: 0x0EB1), LH(lo: 0x0EB4, hi: 0x0EB9), LH(lo: 0x0EBB, hi: 0x0EBC),
        LH(lo: 0x0EC8, hi: 0x0ECD), LH(lo: 0x0F18, hi: 0x0F19), LH(lo: 0x0F35, hi: 0x0F35),
        LH(lo: 0x0F37, hi: 0x0F37), LH(lo: 0x0F39, hi: 0x0F39), LH(lo: 0x0F71, hi: 0x0F7E),
        LH(lo: 0x0F80, hi: 0x0F84), LH(lo: 0x0F86, hi: 0x0F87), LH(lo: 0x0F90, hi: 0x0F97),
        LH(lo: 0x0F99, hi: 0x0FBC), LH(lo: 0x0FC6, hi: 0x0FC6), LH(lo: 0x102D, hi: 0x1030),
        LH(lo: 0x1032, hi: 0x1032), LH(lo: 0x1036, hi: 0x1037), LH(lo: 0x1039, hi: 0x1039),
        LH(lo: 0x1058, hi: 0x1059), LH(lo: 0x1160, hi: 0x11FF), LH(lo: 0x135F, hi: 0x135F),
        LH(lo: 0x1712, hi: 0x1714), LH(lo: 0x1732, hi: 0x1734), LH(lo: 0x1752, hi: 0x1753),
        LH(lo: 0x1772, hi: 0x1773), LH(lo: 0x17B4, hi: 0x17B5), LH(lo: 0x17B7, hi: 0x17BD),
        LH(lo: 0x17C6, hi: 0x17C6), LH(lo: 0x17C9, hi: 0x17D3), LH(lo: 0x17DD, hi: 0x17DD),
        LH(lo: 0x180B, hi: 0x180D), LH(lo: 0x18A9, hi: 0x18A9), LH(lo: 0x1920, hi: 0x1922),
        LH(lo: 0x1927, hi: 0x1928), LH(lo: 0x1932, hi: 0x1932), LH(lo: 0x1939, hi: 0x193B),
        LH(lo: 0x1A17, hi: 0x1A18), LH(lo: 0x1B00, hi: 0x1B03), LH(lo: 0x1B34, hi: 0x1B34),
        LH(lo: 0x1B36, hi: 0x1B3A), LH(lo: 0x1B3C, hi: 0x1B3C), LH(lo: 0x1B42, hi: 0x1B42),
        LH(lo: 0x1B6B, hi: 0x1B73), LH(lo: 0x1DC0, hi: 0x1DCA), LH(lo: 0x1DFE, hi: 0x1DFF),
        LH(lo: 0x200B, hi: 0x200F), LH(lo: 0x202A, hi: 0x202E), LH(lo: 0x2060, hi: 0x2063),
        LH(lo: 0x206A, hi: 0x206F), LH(lo: 0x20D0, hi: 0x20EF), LH(lo: 0x302A, hi: 0x302F),
        LH(lo: 0x3099, hi: 0x309A), LH(lo: 0xA806, hi: 0xA806), LH(lo: 0xA80B, hi: 0xA80B),
        LH(lo: 0xA825, hi: 0xA826), LH(lo: 0xFB1E, hi: 0xFB1E), LH(lo: 0xFE00, hi: 0xFE0F),
        LH(lo: 0xFE20, hi: 0xFE23), LH(lo: 0xFEFF, hi: 0xFEFF), LH(lo: 0xFFF9, hi: 0xFFFB),
        LH(lo: 0x10A01, hi: 0x10A03), LH(lo: 0x10A05, hi: 0x10A06), LH(lo: 0x10A0C, hi: 0x10A0F),
        LH(lo: 0x10A38, hi: 0x10A3A), LH(lo: 0x10A3F, hi: 0x10A3F), LH(lo: 0x1D167, hi: 0x1D169),
        LH(lo: 0x1D173, hi: 0x1D182), LH(lo: 0x1D185, hi: 0x1D18B), LH(lo: 0x1D1AA, hi: 0x1D1AD),
        LH(lo: 0x1D242, hi: 0x1D244), LH(lo: 0xE0001, hi: 0xE0001), LH(lo: 0xE0020, hi: 0xE007F),
        LH(lo: 0xE0100, hi: 0xE01EF)
    ]

    private static func bisearch(rune: UInt32, table: [LH], max _max: Int) -> Int {
        var min = 0
        var mid = 0
        var max = _max
        if rune < table[0].lo || rune > table[max].hi {
            return 0
        }
        while max >= min {
            mid = (min + max) / 2
            if rune > table[mid].hi {
                min = mid + 1
            } else if rune < table[mid].lo {
                max = mid - 1
            } else {
                return 1
            }
        }
        return 0
    }

    /// Number of display columns a rune occupies (0 for combining/zero-width, 2 for
    /// wide CJK/fullwidth, otherwise 1).
    static func columnWidth(rune: UnicodeScalar) -> Int {
        let irune = rune.value
        if irune < 32 { return 0 }
        if irune < 127 { return 1 }
        if irune >= 0x7f && irune <= 0xa0 { return 0 }
        if bisearch(rune: irune, table: combining, max: combining.count - 1) != 0 {
            return 0
        }
        return 1 +
            ((irune >= 0x1100 &&
              (irune <= 0x115f ||
               irune == 0x2329 || irune == 0x232a ||
               (irune >= 0x2e80 && irune <= 0xa4cf && irune != 0x303f) ||
               (irune >= 0xac00 && irune <= 0xd7a3) ||
               (irune >= 0xf900 && irune <= 0xfaff) ||
               (irune >= 0xfe10 && irune <= 0xfe19) ||
               (irune >= 0xfe30 && irune <= 0xfe6f) ||
               (irune >= 0xff00 && irune <= 0xff60) ||
               (irune >= 0xffe0 && irune <= 0xffe6) ||
               (irune >= 0x20000 && irune <= 0x2fffd) ||
               (irune >= 0x30000 && irune <= 0x3fffd))) ? 1 : 0)
    }
}
