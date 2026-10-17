import Foundation

enum MarkdownShowcaseSeed {
    static let imageFilename = "markdown-demo-image.png"
    static let legacySharedImageFilename = imageFilename
    static let imageAssetPath = "assets/\(imageFilename)"

    static let content = """
    # Markdown Showcase

    ![Swift and Adwaita showcase artwork](assets/markdown-demo-image.png)

    *A screenshot-ready note that shows off the native preview, spacing, and typography.*

    Swifty Notes renders Markdown as real GTK widgets, so images, lists, tables, code, and prose all stay crisp without a web view.

    > Tip: use the `Editor`, `Split`, and `Preview` buttons in the header bar to capture different layouts for release screenshots.

    ## Highlights

    - Balanced list spacing that stays compact in the preview
      - Great for outlines, changelogs, and checklists
      - Clean nesting without oversized gaps
    - Inline formatting such as *italic*, **bold**, ~~strikethrough~~, and `inline code`
    - Native image blocks that feel at home in the rest of the interface

    ## Quick Checklist

    - [x] Live Markdown preview
    - [x] Native GTK styling
    - [x] Per-note image assets
    - [ ] Add your own launch-day copy

    ## Feature Snapshot

    | Area | What it shows |
    | --- | --- |
    | Toolbar | Quick formatting without memorizing syntax |
    | Split view | Write and review side by side |
    | CLI | Automate the same file-backed notes |
    | Math | TeX formulas between `$` and `$$` |

    ## Links

    Visit [Swift.org](https://www.swift.org) and [GTK](https://www.gtk.org) for the foundations behind the app.

    ## Quote

    > Fast enough for daily notes, simple enough for plain files, and polished enough for screenshots.

    ## Code Sample

    ```swift
    let modes = ["Editor", "Split", "Preview"]
    print("Swifty Notes: \\(modes.joined(separator: " / "))")
    ```

    ## Math

    Write TeX between dollar signs and it renders in place: the area of a circle is $A = \\pi r^2$, Euler's identity reads $e^{i\\pi} + 1 = 0$, and water is $\\ce{H2O}$.

    $$
    \\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}
    $$

    $$
    \\begin{aligned}
    (a+b)^2 &= a^2 + 2ab + b^2 \\\\
    \\sum_{k=1}^{n} k &= \\frac{n(n+1)}{2}
    \\end{aligned}
    $$

    ## Mixed Content

    You can combine text, lists, tables, code blocks, formulas, and media in one note to build clean project docs or product-ready release collateral.
    """

    static func imageData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "markdown-demo-image",
            withExtension: "png",
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
