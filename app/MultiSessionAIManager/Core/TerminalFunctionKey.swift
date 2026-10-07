import SwiftTerm

enum TerminalFunctionKey {
    static let numbers = Array(1...12)

    static func bytes(for number: Int) -> [UInt8]? {
        guard numbers.contains(number) else { return nil }
        return EscapeSequences.fn[number - 1]
    }
}
