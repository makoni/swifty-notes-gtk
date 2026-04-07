import Foundation

enum MarkdownShowcaseSeed {
    static let imageFilename = "markdown-demo-image.png"

    static let content = """
    # Markdown Showcase

    Welcome to the demo note for **Swifty Notes**. This document shows the main Markdown features supported by the editor and preview.

    ## Headings

    ### Smaller Heading

    Regular paragraphs work as expected, and you can mix *italic*, **bold**, ***bold italic***, ~~strikethrough~~, and `inline code` in the same sentence.

    ## Links

    Visit [Swift.org](https://www.swift.org) or [GTK](https://www.gtk.org) for more details.

    ## Blockquote

    > Markdown is a lightweight way to write rich text.
    >
    > It is great for notes, drafts, and technical documentation.

    ## Lists

    - Unordered item
    - Another item
      - Nested item
    - Final item

    ## Ordered List

    1. First step
    2. Second step
    3. Third step

    ## Task List

    - [x] Write the note
    - [x] Test the preview
    - [ ] Add your own content

    ## Code Block

    ```swift
    import Foundation

    let message = "Hello from Swifty Notes"
    print(message)
    ```

    ## Table

    | Feature | Example | Status |
    | --- | --- | --- |
    | Bold | `**bold**` | Works |
    | Code | `` `code` `` | Works |
    | Table | `| a | b |` | Works |

    ## Thematic Break

    ---

    ## Image

    ![Tiny demo pixel](markdown-demo-image.png)

    ## Mixed Content

    You can combine text, lists, tables, and code blocks in one note to create rich documentation or project notes.
    """

    static let imageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM6sAAAAASUVORK5CYII="
}
