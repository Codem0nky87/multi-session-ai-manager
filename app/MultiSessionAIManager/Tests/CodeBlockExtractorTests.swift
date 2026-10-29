import Testing
import Foundation
@testable import MultiSessionAIManager

@Suite struct CodeBlockExtractorTests {
    @Test func plainTextReturnsSingleTextSegment() {
        let input = "This is a simple response without any code blocks."
        let segments = CodeBlockExtractor.parse(markdown: input)

        #expect(segments.count == 1)
        if case .text(let text) = segments[0].type {
            #expect(text == input)
        } else {
            Issue.record("Expected .text segment")
        }
    }

    @Test func singleCodeBlockWithLanguage() {
        let input = """
        Here is the command you should run:
        ```bash
        ls -la /var/log
        ```
        Let me know if that works!
        """
        let segments = CodeBlockExtractor.parse(markdown: input)

        #expect(segments.count == 3)
        if case .text(let t) = segments[0].type {
            #expect(t.contains("Here is the command"))
        } else { Issue.record() }

        if case .codeBlock(let code, let lang) = segments[1].type {
            #expect(code == "ls -la /var/log")
            #expect(lang == "bash")
        } else { Issue.record() }

        if case .text(let t) = segments[2].type {
            #expect(t.contains("Let me know"))
        } else { Issue.record() }
    }

    @Test func multipleCodeBlocksWithDifferentLanguages() {
        let input = """
        ```swift
        let x = 10
        ```
        And in bash:
        ```sh
        echo $x
        ```
        """
        let segments = CodeBlockExtractor.parse(markdown: input)

        #expect(segments.count == 3)
        if case .codeBlock(let code, let lang) = segments[0].type {
            #expect(code == "let x = 10")
            #expect(lang == "swift")
        } else { Issue.record() }

        if case .text(let t) = segments[1].type {
            #expect(t.contains("And in bash:"))
        } else { Issue.record() }

        if case .codeBlock(let code, let lang) = segments[2].type {
            #expect(code == "echo $x")
            #expect(lang == "sh")
        } else { Issue.record() }
    }

    @Test func unclosedCodeBlockDuringStreaming() {
        let input = """
        Working on this:
        ```swift
        func testStream() {
        """
        let segments = CodeBlockExtractor.parse(markdown: input)

        #expect(segments.count == 2)
        if case .codeBlock(let code, let lang) = segments[1].type {
            #expect(code.contains("func testStream()"))
            #expect(lang == "swift")
        } else { Issue.record() }
    }
}
