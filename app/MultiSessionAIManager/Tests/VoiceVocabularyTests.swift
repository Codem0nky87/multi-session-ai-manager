import Foundation
import Speech
import Testing
@testable import MultiSessionAIManager

/// The words voice input is told to listen for, and the mishearings it puts right.
@Suite struct VoiceVocabularyTests {
    private func vocabulary(_ pairs: [(String, String)], words: [String] = []) -> VoiceVocabulary {
        VoiceVocabulary(words: words, corrections: pairs.map { .init(heard: $0.0, written: $0.1) })
    }

    // MARK: - Putting a mishearing right

    @Test func aMisheardWordIsWrittenAsListedWhateverItsLetterCase() {
        let fix = vocabulary([("kodak", "Codex")])
        #expect(fix.corrected("ask Kodak to fix it") == "ask Codex to fix it")
        #expect(fix.corrected("KODAK") == "Codex")
        #expect(fix.corrected("kodak, then Kodak.") == "Codex, then Codex.")
    }

    @Test func onlyAWholeWordIsPutRight() {
        let fix = vocabulary([("kodak", "Codex")])
        #expect(fix.corrected("kodaks and Kodakchrome") == "kodaks and Kodakchrome")
        #expect(fix.corrected("mykodak") == "mykodak")
    }

    @Test func aMisheardPhraseIsPutRightAcrossAnySpacing() {
        let fix = vocabulary([("cloud code", "Claude Code")])
        #expect(fix.corrected("open Cloud  Code now") == "open Claude Code now")
    }

    /// "cloud code" is one mishearing, not "cloud" followed by a corrected "code".
    @Test func theLongestListedMishearingWins() {
        let fix = vocabulary([("code", "Codex"), ("cloud code", "Claude Code")])
        #expect(fix.corrected("cloud code and code") == "Claude Code and Codex")
    }

    /// One pass: what a correction writes is not corrected again.
    @Test func whatACorrectionWritesIsNotCorrectedAgain() {
        let fix = vocabulary([("alpha", "beta"), ("beta", "gamma")])
        #expect(fix.corrected("alpha beta") == "beta gamma")
    }

    @Test func aCorrectionIsWrittenLiterally() {
        let fix = vocabulary([("dollar home", "$HOME"), ("back slash n", "\\n"), ("c plus plus", "C++")])
        #expect(fix.corrected("echo dollar home") == "echo $HOME")
        #expect(fix.corrected("print back slash n") == "print \\n")
        #expect(fix.corrected("in C plus plus") == "in C++")
    }

    @Test func textWithNothingListedInItIsLeftAlone() {
        #expect(vocabulary([("kodak", "Codex")]).corrected("git status") == "git status")
        #expect(vocabulary([]).corrected("ask Kodak") == "ask Kodak")
    }

    // MARK: - Reading the lists the user types

    @Test func wordsAreOnePerLineTrimmedAndListedOnce() {
        let words = VoiceVocabulary.words(from: "  Codex \n\nHerdr\ncodex\n   \nClaude Code\n")
        #expect(words == ["Codex", "Herdr", "Claude Code"])
        #expect(VoiceVocabulary.words(from: VoiceVocabulary.text(of: words)) == words)
    }

    @Test func correctionsAreHeardEqualsWrittenOnePerLine() {
        let text = "kodak = Codex\ncloud code=Claude Code\n  \nno separator here\n = nothing heard\nnothing written = \nsum = a = b"
        #expect(VoiceVocabulary.corrections(from: text) == [
            .init(heard: "kodak", written: "Codex"),
            .init(heard: "cloud code", written: "Claude Code"),
            // Split at the first "=": what is written may hold one.
            .init(heard: "sum", written: "a = b"),
        ])
        let corrections = VoiceVocabulary.corrections(from: text)
        #expect(VoiceVocabulary.corrections(from: VoiceVocabulary.text(of: corrections)) == corrections)
    }

    // MARK: - What the recogniser is told

    /// It is told the words, and what each correction writes: hearing the right
    /// word in the first place is better than putting it right afterwards.
    @Test func theRecogniserIsToldTheWordsAndWhatTheCorrectionsWrite() {
        let told = vocabulary([("kodak", "Codex"), ("herder", "Herdr")], words: ["Herdr", "kubectl"]).hints
        #expect(told == ["Herdr", "kubectl", "Codex"])
    }

    @Test func theRecogniserIsToldNoMoreThanItTakes() {
        let many = VoiceVocabulary(words: (1...250).map { "word\($0)" }, corrections: [])
        #expect(many.hints.count == VoiceVocabulary.maximumHints)
        #expect(many.hints.first == "word1")
    }

    // MARK: - The built-in list and what is kept on the device

    @Test func theBuiltInListKnowsCodex() {
        #expect(VoiceVocabulary.builtIn.words.contains("Codex"))
        #expect(VoiceVocabulary.builtIn.hints.contains("Codex"))
        #expect(VoiceVocabulary.builtIn.corrected("ask Kodak and kodex") == "ask Codex and Codex")
    }

    @Test func withNothingKeptTheBuiltInListIsUsedAndAnEmptiedListStaysEmpty() {
        let defaults = UserDefaults(suiteName: "msam.voice.\(UUID())")!
        #expect(VoiceVocabulary.stored(in: defaults) == VoiceVocabulary.builtIn)

        defaults.set("Herdr\nzellij", forKey: VoiceVocabulary.wordsKey)
        defaults.set("zelda = zellij", forKey: VoiceVocabulary.correctionsKey)
        #expect(VoiceVocabulary.stored(in: defaults)
                == VoiceVocabulary(words: ["Herdr", "zellij"],
                                   corrections: [.init(heard: "zelda", written: "zellij")]))

        // Emptied on purpose is not the same as never set.
        defaults.set("", forKey: VoiceVocabulary.wordsKey)
        defaults.set("", forKey: VoiceVocabulary.correctionsKey)
        #expect(VoiceVocabulary.stored(in: defaults) == VoiceVocabulary(words: [], corrections: []))
    }

    // MARK: - In the dictation engine

    /// Stands in for what is kept on the device, so a test can change it.
    @MainActor private final class Settings {
        var written = "Codex"
    }

    @MainActor
    @Test func theEngineTellsTheRecogniserTheWordsBeforeItListens() async {
        let mock = MockSpeechRecognitionService()
        let engine = VoiceDictationEngine(service: mock, vocabulary: {
            VoiceVocabulary(words: ["Herdr"], corrections: [.init(heard: "kodak", written: "Codex")])
        })

        await engine.startRecording()

        #expect(mock.contextualStringsAtStart == ["Herdr", "Codex"])
        engine.cancelRecording()
    }

    @MainActor
    @Test func theEnginePutsMishearingsRightInWhatItShowsAndInWhatItTypes() async {
        let mock = MockSpeechRecognitionService()
        mock.transcribedResult = "ask Kodak to run the tests"
        let engine = VoiceDictationEngine(service: mock, vocabulary: {
            VoiceVocabulary(words: [], corrections: [.init(heard: "kodak", written: "Codex")])
        })

        await engine.startRecording()
        mock.simulatePartialText("ask kodak")
        #expect(engine.state == .listening(liveText: "ask Codex", audioLevel: 0.0))

        #expect(await engine.stopRecording() == "ask Codex to run the tests")
    }

    /// The list is read when recording starts, so a change in Settings counts
    /// from the next thing said.
    @MainActor
    @Test func theEngineReadsTheListAfreshEachTimeItStarts() async {
        let mock = MockSpeechRecognitionService()
        let settings = Settings()
        let engine = VoiceDictationEngine(service: mock, vocabulary: {
            VoiceVocabulary(words: [], corrections: [.init(heard: "kodak", written: settings.written)])
        })
        mock.transcribedResult = "kodak"

        await engine.startRecording()
        #expect(await engine.stopRecording() == "Codex")

        settings.written = "Kodak"
        await engine.startRecording()
        #expect(await engine.stopRecording() == "Kodak")
    }

    @MainActor
    @Test func theSpeechRequestCarriesTheWords() {
        let request = AppleSpeechRecognitionService.makeRequest(contextualStrings: ["Codex", "Herdr"])
        #expect(request.contextualStrings == ["Codex", "Herdr"])
        #expect(request.shouldReportPartialResults)
        #expect(!request.requiresOnDeviceRecognition)
    }
}
