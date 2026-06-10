import Testing
@testable import SwiftyNotes

@Suite struct MarkdownLinkPasteTests {

    // MARK: - URL detection

    @Test("Recognises bare http and https URLs as pasteable")
    func recognisesBareHttpAndHttpsURLsAsPasteable() {
        #expect(MarkdownLinkPaste.isPasteableURL("http://example.com"))
        #expect(MarkdownLinkPaste.isPasteableURL("https://example.com"))
        #expect(MarkdownLinkPaste.isPasteableURL("https://github.com/makoni/swifty-notes-gtk"))
        #expect(MarkdownLinkPaste.isPasteableURL("https://example.com/path?query=value&other=1#fragment"))
    }

    @Test("Accepts uppercase scheme by lowercasing")
    func acceptsUppercaseSchemeByLowercasing() {
        #expect(MarkdownLinkPaste.isPasteableURL("HTTP://Example.COM"))
        #expect(MarkdownLinkPaste.isPasteableURL("HTTPS://example.com"))
    }

    @Test("Rejects strings that aren't single bare URLs")
    func rejectsStringsThatArentSingleBareURLs() {
        #expect(!MarkdownLinkPaste.isPasteableURL(""))
        #expect(!MarkdownLinkPaste.isPasteableURL("not a url"))
        #expect(!MarkdownLinkPaste.isPasteableURL("foo"))
        // Internal whitespace — bare URL paste only.
        #expect(!MarkdownLinkPaste.isPasteableURL("see https://example.com please"))
        #expect(!MarkdownLinkPaste.isPasteableURL("https://example.com\nhttps://other.com"))
    }

    @Test("Rejects non-http schemes to avoid xss style wrapping")
    func rejectsNonHttpSchemesToAvoidXssStyleWrapping() {
        #expect(!MarkdownLinkPaste.isPasteableURL("javascript:alert(1)"))
        #expect(!MarkdownLinkPaste.isPasteableURL("file:///etc/passwd"))
        #expect(!MarkdownLinkPaste.isPasteableURL("mailto:test@example.com"))
        #expect(!MarkdownLinkPaste.isPasteableURL("ftp://example.com"))
    }

    @Test("Rejects URLs with empty host")
    func rejectsURLsWithEmptyHost() {
        #expect(!MarkdownLinkPaste.isPasteableURL("https://"))
        #expect(!MarkdownLinkPaste.isPasteableURL("http://"))
    }

    // MARK: - Code-context detection

    @Test("Cursor inside fenced code block is recognised as code context")
    func cursorInsideFencedCodeBlockIsRecognisedAsCodeContext() {
        let textBefore = """
        Some text

        ```
        code line one
        cursor-here
        """
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    @Test("Cursor after closed fenced code block is plain text")
    func cursorAfterClosedFencedCodeBlockIsPlainText() {
        let textBefore = """
        Some text

        ```
        code
        ```

        cursor-here
        """
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    @Test("Language-tagged fence still counts as code context")
    func languageTaggedFenceStillCountsAsCodeContext() {
        let textBefore = """
        Notes:

        ```swift
        let x = 1
        cursor-here
        """
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    @Test("Cursor inside unmatched inline backticks on the same line is code context")
    func cursorInsideUnmatchedInlineBackticksOnTheSameLineIsCodeContext() {
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: "Run `swift build "))
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: "Use `git commit -m \"msg`. And `now another "))
    }

    @Test("Cursor after balanced inline backticks is plain text")
    func cursorAfterBalancedInlineBackticksIsPlainText() {
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: "Run `swift build` and then "))
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: "Plain old prose without any backticks"))
    }

    @Test("Inline backticks reset on newline so unmatched ticks earlier don't poison later lines")
    func inlineBackticksResetOnNewlineSoUnmatchedTicksEarlierDontPoisonLater() {
        let textBefore = """
        Earlier line with stray ` backtick
        Now a fresh line cursor-here
        """
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    // MARK: - Transform decision

    @Test("Bare URL paste with no selection wraps as duplicate link")
    func bareURLPasteWithNoSelectionWrapsAsDuplicateLink() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "https://example.com",
            selectedText: "",
            isInCodeContext: false,
        )
        #expect(action == .wrap("[https://example.com](https://example.com)"))
    }

    @Test("Bare URL paste with selection wraps the selection as link text")
    func bareURLPasteWithSelectionWrapsTheSelectionAsLinkText() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "https://example.com",
            selectedText: "click here",
            isInCodeContext: false,
        )
        #expect(action == .wrap("[click here](https://example.com)"))
    }

    @Test("URL paste in code context falls through to plain text paste")
    func uRLPasteInCodeContextFallsThroughToPlainTextPaste() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "https://example.com",
            selectedText: "",
            isInCodeContext: true,
        )
        #expect(action == .passThrough)
    }

    @Test("non-URL text paste falls through to plain text paste")
    func nonURLTextPasteFallsThroughToPlainTextPaste() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "just some text",
            selectedText: "",
            isInCodeContext: false,
        )
        #expect(action == .passThrough)
    }

    @Test("URL surrounded by whitespace is trimmed before validation and wrap")
    func uRLSurroundedByWhitespaceIsTrimmedBeforeValidationAndWrap() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "  https://example.com  \n",
            selectedText: "",
            isInCodeContext: false,
        )
        #expect(action == .wrap("[https://example.com](https://example.com)"))
    }
}
