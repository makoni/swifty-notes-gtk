import Testing
@testable import SwiftyNotes

@Suite struct MarkdownLinkPasteTests {

    // MARK: - URL detection

    @Test
    func `recognises bare http and https URLs as pasteable`() {
        #expect(MarkdownLinkPaste.isPasteableURL("http://example.com"))
        #expect(MarkdownLinkPaste.isPasteableURL("https://example.com"))
        #expect(MarkdownLinkPaste.isPasteableURL("https://github.com/makoni/swifty-notes-gtk"))
        #expect(MarkdownLinkPaste.isPasteableURL("https://example.com/path?query=value&other=1#fragment"))
    }

    @Test
    func `accepts uppercase scheme by lowercasing`() {
        #expect(MarkdownLinkPaste.isPasteableURL("HTTP://Example.COM"))
        #expect(MarkdownLinkPaste.isPasteableURL("HTTPS://example.com"))
    }

    @Test
    func `rejects strings that aren't single bare URLs`() {
        #expect(!MarkdownLinkPaste.isPasteableURL(""))
        #expect(!MarkdownLinkPaste.isPasteableURL("not a url"))
        #expect(!MarkdownLinkPaste.isPasteableURL("foo"))
        // Internal whitespace — bare URL paste only.
        #expect(!MarkdownLinkPaste.isPasteableURL("see https://example.com please"))
        #expect(!MarkdownLinkPaste.isPasteableURL("https://example.com\nhttps://other.com"))
    }

    @Test
    func `rejects non-http schemes to avoid xss style wrapping`() {
        #expect(!MarkdownLinkPaste.isPasteableURL("javascript:alert(1)"))
        #expect(!MarkdownLinkPaste.isPasteableURL("file:///etc/passwd"))
        #expect(!MarkdownLinkPaste.isPasteableURL("mailto:test@example.com"))
        #expect(!MarkdownLinkPaste.isPasteableURL("ftp://example.com"))
    }

    @Test
    func `rejects URLs with empty host`() {
        #expect(!MarkdownLinkPaste.isPasteableURL("https://"))
        #expect(!MarkdownLinkPaste.isPasteableURL("http://"))
    }

    // MARK: - Code-context detection

    @Test
    func `cursor inside fenced code block is recognised as code context`() {
        let textBefore = """
        Some text

        ```
        code line one
        cursor-here
        """
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    @Test
    func `cursor after closed fenced code block is plain text`() {
        let textBefore = """
        Some text

        ```
        code
        ```

        cursor-here
        """
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    @Test
    func `language-tagged fence still counts as code context`() {
        let textBefore = """
        Notes:

        ```swift
        let x = 1
        cursor-here
        """
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    @Test
    func `cursor inside unmatched inline backticks on the same line is code context`() {
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: "Run `swift build "))
        #expect(MarkdownLinkPaste.isInCodeContext(textBefore: "Use `git commit -m \"msg`. And `now another "))
    }

    @Test
    func `cursor after balanced inline backticks is plain text`() {
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: "Run `swift build` and then "))
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: "Plain old prose without any backticks"))
    }

    @Test
    func `inline backticks reset on newline so unmatched ticks earlier don't poison later lines`() {
        let textBefore = """
        Earlier line with stray ` backtick
        Now a fresh line cursor-here
        """
        #expect(!MarkdownLinkPaste.isInCodeContext(textBefore: textBefore))
    }

    // MARK: - Transform decision

    @Test
    func `bare URL paste with no selection wraps as duplicate link`() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "https://example.com",
            selectedText: "",
            isInCodeContext: false,
        )
        #expect(action == .wrap("[https://example.com](https://example.com)"))
    }

    @Test
    func `bare URL paste with selection wraps the selection as link text`() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "https://example.com",
            selectedText: "click here",
            isInCodeContext: false,
        )
        #expect(action == .wrap("[click here](https://example.com)"))
    }

    @Test
    func `URL paste in code context falls through to plain text paste`() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "https://example.com",
            selectedText: "",
            isInCodeContext: true,
        )
        #expect(action == .passThrough)
    }

    @Test
    func `non-URL text paste falls through to plain text paste`() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "just some text",
            selectedText: "",
            isInCodeContext: false,
        )
        #expect(action == .passThrough)
    }

    @Test
    func `URL surrounded by whitespace is trimmed before validation and wrap`() {
        let action = MarkdownLinkPaste.transform(
            clipboardText: "  https://example.com  \n",
            selectedText: "",
            isInCodeContext: false,
        )
        #expect(action == .wrap("[https://example.com](https://example.com)"))
    }
}
