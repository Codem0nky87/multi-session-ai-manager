//
//  VoiceVocabulary.swift
//  MultiSessionAIManager
//
//  Voice input writes ordinary words well and names badly: "Codex" comes out
//  as "Kodak". Two lists, both the user's to edit in Settings, deal with that.
//  The words are given to the speech recogniser as what to expect. The
//  corrections put right what it still gets wrong, after the fact.
//

import Foundation

struct VoiceVocabulary: Equatable, Sendable {
    /// A word the recogniser writes wrongly, and what to type in its place.
    struct Correction: Equatable, Sendable {
        let heard: String
        let written: String
    }

    var words: [String]
    var corrections: [Correction]

    /// The recogniser is documented to take about this many phrases.
    static let maximumHints = 100
    /// Where the device keeps the two lists, as the text the user typed.
    static let wordsKey = "msam.voice.words"
    static let correctionsKey = "msam.voice.corrections"

    /// What is used until the user changes it: the names and commands said in
    /// these terminals that a dictation model does not expect.
    static let builtIn = VoiceVocabulary(
        words: [
            "Codex", "Claude", "Claude Code", "Anthropic", "OpenAI", "Gemini", "Herdr",
            "sudo", "git", "GitHub", "npm", "pnpm", "kubectl", "Docker", "grep",
            "SSH", "localhost", "JSON", "YAML", "regex", "repo", "rebase", "worktree",
            "Xcode", "TestFlight",
        ],
        corrections: [
            Correction(heard: "kodak", written: "Codex"),
            Correction(heard: "kodex", written: "Codex"),
            Correction(heard: "cloud code", written: "Claude Code"),
            Correction(heard: "herder", written: "Herdr"),
        ])

    // MARK: - The lists as text

    /// One word or phrase per line. Each is listed once, whatever its letter case.
    static func words(from text: String) -> [String] {
        unique(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    static func text(of words: [String]) -> String {
        words.joined(separator: "\n")
    }

    /// One per line, `heard = written`, split at the first `=`. A line without
    /// both sides is ignored.
    static func corrections(from text: String) -> [Correction] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let separator = line.firstIndex(of: "=") else { return nil }
            let heard = line[..<separator].trimmingCharacters(in: .whitespaces)
            let written = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !written.isEmpty else { return nil }
            return Correction(heard: heard, written: written)
        }
    }

    static func text(of corrections: [Correction]) -> String {
        corrections.map { "\($0.heard) = \($0.written)" }.joined(separator: "\n")
    }

    /// The lists kept on the device, or the built-in ones where nothing has been
    /// kept. A list emptied on purpose stays empty.
    static func stored(in defaults: UserDefaults = .standard) -> VoiceVocabulary {
        VoiceVocabulary(
            words: defaults.string(forKey: wordsKey).map(words(from:)) ?? builtIn.words,
            corrections: defaults.string(forKey: correctionsKey).map(corrections(from:)) ?? builtIn.corrections)
    }

    // MARK: - Using them

    /// What the recogniser is told to expect: the words, and what each correction
    /// writes. Hearing the right word is better than putting it right afterwards.
    var hints: [String] {
        Array(Self.unique(words + corrections.map(\.written)).prefix(Self.maximumHints))
    }

    /// The text with every listed mishearing put right. Whole words only, in any
    /// letter case, the longest listed phrase first, and in one pass: what a
    /// correction writes is never corrected again.
    func corrected(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var written: [String: String] = [:]
        var alternatives: [String] = []
        for correction in corrections.sorted(by: { $0.heard.count > $1.heard.count }) {
            let key = Self.key(correction.heard)
            guard !key.isEmpty, written[key] == nil else { continue }
            written[key] = correction.written
            alternatives.append(key.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+"))
        }
        guard !alternatives.isEmpty,
              let listed = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])",
                options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        var result = ""
        var end = 0
        for match in listed.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: end, length: match.range.location - end))
            let heard = source.substring(with: match.range)
            result += written[Self.key(heard)] ?? heard
            end = match.range.location + match.range.length
        }
        return result + source.substring(from: end)
    }

    /// A heard phrase as it is looked up: lower case, single spaces.
    private static func key(_ heard: String) -> String {
        heard.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func unique(_ words: [String]) -> [String] {
        var seen: Set<String> = []
        return words.filter { seen.insert($0.lowercased()).inserted }
    }
}
