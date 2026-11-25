import SwiftUI

/// Settings: the words voice input is told to expect, and the mishearings it
/// puts right. Both are kept on the device as the text typed here.
struct VoiceInputSection: View {
    @AppStorage(VoiceVocabulary.wordsKey)
    private var wordsText = VoiceVocabulary.text(of: VoiceVocabulary.builtIn.words)
    @AppStorage(VoiceVocabulary.correctionsKey)
    private var correctionsText = VoiceVocabulary.text(of: VoiceVocabulary.builtIn.corrections)

    var body: some View {
        Section {
            NavigationLink {
                VoiceVocabularyEditor(wordsText: $wordsText, correctionsText: $correctionsText)
            } label: {
                LabeledContent("Words and corrections", value: summary)
            }
            .accessibilityIdentifier("settings.voice.vocabulary")
        } header: {
            Text("Voice input")
        } footer: {
            Text("Names and commands voice input should recognise, and words it gets wrong.")
        }
    }

    private var summary: String {
        let words = VoiceVocabulary.words(from: wordsText).count
        let corrections = VoiceVocabulary.corrections(from: correctionsText).count
        return "\(words) words, \(corrections) corrections"
    }
}

struct VoiceVocabularyEditor: View {
    @Binding var wordsText: String
    @Binding var correctionsText: String

    private var isBuiltIn: Bool {
        wordsText == VoiceVocabulary.text(of: VoiceVocabulary.builtIn.words)
            && correctionsText == VoiceVocabulary.text(of: VoiceVocabulary.builtIn.corrections)
    }

    var body: some View {
        Form {
            Section {
                editor($wordsText, height: 240, id: "settings.voice.words")
            } header: {
                Text("Words to listen for")
            } footer: {
                Text("One word or phrase per line, spelled the way it should be written. Voice input is told to expect them. The first \(VoiceVocabulary.maximumHints) are used.")
            }

            Section {
                editor($correctionsText, height: 160, id: "settings.voice.corrections")
            } header: {
                Text("Corrections")
            } footer: {
                Text("One per line, as heard = written. Where voice input still writes the words on the left, the ones on the right are typed instead. Whole words only, in any letter case.")
            }

            Section {
                Button("Restore the built-in lists") {
                    wordsText = VoiceVocabulary.text(of: VoiceVocabulary.builtIn.words)
                    correctionsText = VoiceVocabulary.text(of: VoiceVocabulary.builtIn.corrections)
                }
                .disabled(isBuiltIn)
                .accessibilityIdentifier("settings.voice.restore")
            } footer: {
                Text("A change counts from the next thing you say.")
            }
        }
        .navigationTitle("Voice input")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editor(_ text: Binding<String>, height: CGFloat, id: String) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: height)
            .accessibilityIdentifier(id)
    }
}
