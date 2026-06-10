#if !os(macOS)
import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// Widget-backed MarkdownPreview tests live in their own test target so SwiftPM
/// runs them in a dedicated process. When they share a process with
/// MainWindow*Tests the teardown of those suites leaves GLib idle callbacks
/// referencing freed GObjects, which crash the next widget test that pumps
/// the main context.
struct MarkdownPreviewWidgetTests {
    @Test("Preview loads remote image when loader provides local file after asynchronous completion") @MainActor
    func previewLoadsRemoteImageWhenLoaderProvidesLocalFileAfterAsynchronousCompletion() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-preview.png", isDirectory: false)
        try MarkdownShowcaseSeed.imageData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-image")
        try app.register()

        let remoteSource = "https://img.shields.io/badge/Swift-6.0+-F05138.svg"
        var requestedURL: URL?
        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { url, completion in
            requestedURL = url
            pendingCompletion = completion
        })

        preview.render(blocks: [
            .image(alt: "Swift badge", source: remoteSource, title: nil),
        ])

        let picture = firstPicture(in: preview.container)
        #expect(requestedURL?.absoluteString == remoteSource)
        #expect(picture != nil)
        #expect(picture?.alternativeText == "Swift badge")
        #expect(pictureFilePath(picture) == nil)

        guard let pendingCompletion else {
            Issue.record("Expected remote image completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        #expect(await waitForPaintable(picture, timeout: .seconds(3)))
    }

    @Test("Preview loads remote linked image group when loader provides local file after asynchronous completion") @MainActor
    func previewLoadsRemoteLinkedImageGroupWhenLoaderProvidesLocalFileAfter() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-badge.png", isDirectory: false)
        try MarkdownShowcaseSeed.imageData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-image-group")
        try app.register()

        let remoteSource = "https://img.shields.io/badge/Documentation-Online-0A84FF.svg"
        var requestedURL: URL?
        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { url, completion in
            requestedURL = url
            pendingCompletion = completion
        })

        preview.render(blocks: [
            .imageGroup(items: [
                .init(
                    alt: "Documentation",
                    source: remoteSource,
                    title: nil,
                    linkDestination: "https://spaceinbox.me/docs/swift-adwaita/documentation/adwaita",
                ),
            ]),
        ])

        let picture = firstPicture(in: preview.container)
        #expect(requestedURL?.absoluteString == remoteSource)
        #expect(picture != nil)
        #expect(picture?.alternativeText == "Documentation")
        #expect(pictureFilePath(picture) == nil)

        guard let pendingCompletion else {
            Issue.record("Expected remote linked image completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        #expect(await waitForPaintable(picture, timeout: .seconds(3)))
    }

    @Test("Preview wraps linked badge in chromeless Box without inheriting Button min-height") @MainActor
    func previewWrapsLinkedBadgeInChromelessBoxWithoutInheritingButtonMinHeight() throws {
        // Regression: an earlier version wrapped linked badges in a
        // libadwaita `Button`. The Button enforced a ~30px min-height
        // that silently capped how tall the inner Picture could grow,
        // so badges rendered visibly smaller than the preferredHeight
        // they requested. The wrapper is now a plain `Box` with a
        // `GestureClick` controller for click handling.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.linked-badge-box-wrapper")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .imageGroup(items: [
                .init(
                    alt: "Swift badge",
                    source: "https://img.shields.io/badge/Swift-6.0+-F05138.svg",
                    title: nil,
                    linkDestination: "https://swift.org",
                ),
            ]),
        ])

        #expect(firstButton(in: preview.container) == nil)

        guard let picture = firstPicture(in: preview.container) else {
            Issue.record("Expected a Picture inside the linked badge")
            return
        }

        let size = picture.sizeRequest
        #expect(size.width == -1)
        #expect(size.height == 22)

        // The wrapper that owns the click target sits one level above
        // the Picture and must have the `preview-image-link` class so
        // the chromeless hover styling applies.
        guard let wrapper = picture.parent else {
            Issue.record("Expected a wrapper around the Picture")
            return
        }
        #expect(wrapper.hasCSSClass("preview-image-link"))

        let wrapperHeight = measuredNaturalSize(of: wrapper, orientation: .vertical)
        // Box wrapper must not pad the badge — its natural height is
        // the Picture's request. A Button here would be ~30+.
        #expect(wrapperHeight <= 22)
    }

    @Test("Preview scales linked badge SVG to preferred height") @MainActor
    func previewScalesLinkedBadgeSVGToPreferredHeight() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let badgeURL = temp.appendingPathComponent("badge.svg", isDirectory: false)
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="20" viewBox="0 0 120 20">
          <rect width="120" height="20" fill="#0a84ff"/>
        </svg>
        """.utf8).write(to: badgeURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-local-svg-badge")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .imageGroup(items: [
                .init(
                    alt: "Badge",
                    source: badgeURL.path(),
                    title: nil,
                    linkDestination: "https://example.invalid",
                ),
            ]),
        ])

        guard let picture = firstPicture(in: preview.container) else {
            Issue.record("Expected linked badge Picture")
            return
        }

        let size = picture.sizeRequest

        // 120×20 SVG scaled to badge height = 22 → width = 132.
        #expect(size.width == 132)
        #expect(size.height == 22)
    }

    @Test("Badge Picture disables canShrink so async-loaded SVG honours its size request") @MainActor
    func badgePictureDisablesCanShrinkSoAsyncLoadedSVGHonoursItsSizeRequest() throws {
        // Regression: before this fix the Picture had `canShrink = true`
        // unconditionally. A linked badge's remote SVG arrives async,
        // after initial layout has already settled on a zero-width
        // allocation. With canShrink=true GTK happily kept the badge
        // squashed at 0×height even though setSizeRequest reported the
        // proper size. canShrink=false makes setSizeRequest a hard
        // minimum so the badge ends up rendered at its requested size.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.badge-picture-cannot-shrink")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .imageGroup(items: [
                .init(
                    alt: "Swift badge",
                    source: "https://img.shields.io/badge/Swift-6.0+-F05138.svg",
                    title: nil,
                    linkDestination: "https://swift.org",
                ),
            ]),
        ])

        guard let picture = firstPicture(in: preview.container) else {
            Issue.record("Expected badge Picture")
            return
        }
        #expect(picture.canShrink == false)
    }

    @Test("Presented preview re-sizes block image when the preview pane is widened after initial layout") @MainActor
    func presentedPreviewReSizesBlockImageWhenThePreviewPaneIsWidened() throws {
        // Regression: the previous resize hook used `notify::width`, which
        // GtkWidget never emits — so when the user widened the preview
        // pane after a note was already open, `Clamp.maximumSize` stayed
        // pinned at the initial width and the image visibly stopped
        // growing even though the surrounding card kept expanding. The
        // fix replaces the hook with a per-frame tick callback that
        // actually fires on allocation changes; this test pins the
        // contract by simulating the user dragging the splitter wider
        // and asserting that the image's clamp width grew with it.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let imageURL = temp.appendingPathComponent("hero-large.svg", isDirectory: false)
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900" viewBox="0 0 1600 900">
          <rect width="1600" height="900" fill="#0a84ff"/>
        </svg>
        """.utf8).write(to: imageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.preview-grows-on-resize")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let window = ApplicationWindow(application: app)
        let editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.setSizeRequest(width: 600, height: 400)
        let pane = Paned(orientation: .horizontal)
        pane.startChild = editorHost
        pane.endChild = preview.rootScroll
        pane.resizeStartChild = true
        pane.resizeEndChild = true
        pane.shrinkStartChild = true
        pane.shrinkEndChild = true
        window.setDefaultSize(width: 1100, height: 760)
        window.setContent(pane)
        preview.attach(to: window)
        window.present()
        pumpMainContext(for: .milliseconds(40))

        preview.render(blocks: [
            .image(alt: "Hero artwork", source: imageURL.path(), title: nil),
        ])
        pumpMainContext(for: .milliseconds(120))

        guard let initialClamp = firstClamp(in: preview.container) else {
            Issue.record("Expected initial clamp")
            return
        }
        let initialMax = initialClamp.maximumSize
        #expect(initialMax > 0)
        #expect(initialMax < 1600)

        // Shrink the editor pane to widen the preview pane: this is the
        // programmatic equivalent of the user dragging the splitter to
        // the left in the running app.
        editorHost.setSizeRequest(width: 200, height: 400)
        pumpMainContext(for: .milliseconds(200))

        guard let resizedClamp = firstClamp(in: preview.container) else {
            Issue.record("Expected clamp after resize")
            return
        }
        #expect(resizedClamp.maximumSize > initialMax)
    }

    @Test("Block image Picture keeps canShrink so wide images can scale into narrow preview columns") @MainActor
    func blockImagePictureKeepsCanShrinkSoWideImagesCanScaleIntoNarrow() throws {
        // Block images (cards, plain in-flow) need to scale down when
        // the preview pane is narrow — that is `Picture.canShrink`'s
        // raison d'être. The fix above is targeted at badges via
        // `preferredHeight`; block images (no preferredHeight) must be
        // unaffected.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.block-image-can-shrink")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .image(
                alt: "Wide showcase",
                source: "https://example.invalid/showcase.png",
                title: nil,
                style: .card,
            ),
        ])

        guard let picture = firstPicture(in: preview.container) else {
            Issue.record("Expected block image Picture")
            return
        }
        #expect(picture.canShrink == true)
    }

    @Test("Preview measures badge group at constrained height without warnings") @MainActor
    func previewMeasuresBadgeGroupAtConstrainedHeightWithoutWarnings() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let badgeURL = temp.appendingPathComponent("badge.svg", isDirectory: false)
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="20" viewBox="0 0 120 20">
          <rect width="120" height="20" fill="#0a84ff"/>
        </svg>
        """.utf8).write(to: badgeURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-badge-measurement")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .imageGroup(items: [
                .init(alt: "CI", source: badgeURL.path(), title: nil, linkDestination: "https://example.invalid/ci"),
                .init(alt: "Swift", source: badgeURL.path(), title: nil, linkDestination: "https://example.invalid/swift"),
                .init(alt: "Docs", source: badgeURL.path(), title: nil, linkDestination: "https://example.invalid/docs"),
                .init(alt: "License", source: badgeURL.path(), title: nil, linkDestination: "https://example.invalid/license"),
            ]),
        ])

        guard let badgeRow = firstHBox(in: preview.container) else {
            Issue.record("Expected horizontal box for badge group")
            return
        }

        let measurement = badgeRow.measure(orientation: .horizontal, forSize: 18)

        #expect(measurement.minimum > 0)
        #expect(measurement.natural >= measurement.minimum)
    }

    @Test("Preview table horizontal minimum fits inside narrow preview") @MainActor
    func previewTableHorizontalMinimumFitsInsideNarrowPreview() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.table-horizontal-shrink")
        try app.register()

        let wideCell = RenderedText(
            markup: "ListStore, StringList, FilterListModel, SortListModel, MapListModel, FlattenListModel, TreeListModel, SelectionFilterModel",
            plainText: "ListStore, StringList, FilterListModel, SortListModel, MapListModel, FlattenListModel, TreeListModel, SelectionFilterModel",
        )
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .table(
                headers: [
                    RenderedText(markup: "Protocol", plainText: "Protocol"),
                    RenderedText(markup: "Purpose", plainText: "Purpose"),
                    RenderedText(markup: "Conforming Types", plainText: "Conforming Types"),
                ],
                rows: [[
                    RenderedText(markup: "ListModelConvertible", plainText: "ListModelConvertible"),
                    RenderedText(markup: "Pass models to list views", plainText: "Pass models to list views"),
                    wideCell,
                ]],
                alignments: [.leading, .leading, .leading],
            ),
        ])

        let children = preview.container.children()
        #expect(children.count == 1)
        guard let block = children.first else {
            Issue.record("Expected table block widget")
            return
        }

        let measurement = block.measure(orientation: .horizontal)

        #expect(measurement.minimum <= 320)
    }

    @Test("Preview list item horizontal minimum fits inside narrow preview") @MainActor
    func previewListItemHorizontalMinimumFitsInsideNarrowPreview() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.list-item-horizontal-shrink")
        try app.register()

        let longContent = "Zero raw pointers in public API — all OpaquePointer/gpointer hidden behind Swift types, SignalName, PropertyName, CSSClass, IconName"
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .listItem(text: .plain(longContent), depth: 0, marker: "-"),
        ])

        let children = preview.container.children()
        #expect(children.count == 1)
        guard let block = children.first else {
            Issue.record("Expected list widget")
            return
        }

        let measurement = block.measure(orientation: .horizontal)

        #expect(measurement.minimum <= 320)
    }

    @Test("Preview flattens depth-zero list runs into a smaller subtree") @MainActor
    func previewFlattensDepthZeroListRunsIntoASmallerSubtree() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.list-run-flattening")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .listItem(text: .plain("API surface stays Swifty"), depth: 0, marker: "-"),
            .listItem(text: .plain("Ordered items still render"), depth: 0, marker: "1."),
            .listItem(text: .plain("Task checkboxes stay interactive"), depth: 0, marker: "[ ]", taskIndex: 0),
            .listItem(text: .plain("Completed tasks keep their checkmark"), depth: 0, marker: "[x]", taskIndex: 1),
        ])

        #expect(preview.debugTopLevelWidgetCount == 1)
        #expect(preview.debugWidgetTreeCount == 10)
        let mergedText = labelTexts(in: preview.container).joined(separator: "\n")
        #expect(mergedText.contains("API surface stays Swifty"))
        #expect(mergedText.contains("☐"))
        #expect(mergedText.contains("☑"))
    }

    @Test("Preview collapses nested non-task list into a single Label too") @MainActor
    func previewCollapsesNestedNonTaskListIntoASingleLabelToo() throws {
        // Phase B.2 (extended): the depth restriction is dropped for
        // non-task lists. A list with nested items still becomes one
        // Label — indent per depth level is rendered through leading
        // spaces inside the Pango markup so the outer container goes
        // from `Box > N×(Box per item)` (≥ N+1 widgets) down to a
        // single widget regardless of nesting.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.nested-list-label")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .listItem(text: .plain("Outer one"),   depth: 0, marker: "-"),
            .listItem(text: .plain("Inner one"),   depth: 1, marker: "-"),
            .listItem(text: .plain("Inner two"),   depth: 1, marker: "-"),
            .listItem(text: .plain("Outer two"),   depth: 0, marker: "-"),
        ])
        #expect(preview.debugTopLevelWidgetCount == 1)
        #expect(preview.debugWidgetTreeCount == 2)
        let texts = labelTexts(in: preview.container)
        #expect(texts.contains { $0.contains("Outer one") })
        #expect(texts.contains { $0.contains("Inner one") })
        #expect(texts.contains { $0.contains("Inner two") })
        #expect(texts.contains { $0.contains("Outer two") })
    }

    @Test("Preview collapses flat non-task list into a single Label") @MainActor
    func previewCollapsesFlatNonTaskListIntoASingleLabel() throws {
        // Phase B.2: a depth-0 list with no checkbox markers no
        // longer materializes a Grid + 2N cell Labels. The whole
        // list becomes one Pango-markup Label so the per-frame
        // snapshot walk sees one widget instead of 9 for a 4-item
        // list.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.flat-list-label")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .listItem(text: .plain("First"),  depth: 0, marker: "-"),
            .listItem(text: .plain("Second"), depth: 0, marker: "-"),
            .listItem(text: .plain("Third"),  depth: 0, marker: "-"),
            .listItem(text: .plain("Fourth"), depth: 0, marker: "-"),
        ])
        #expect(preview.debugTopLevelWidgetCount == 1)
        // Container + the single Label = 2 widgets total.
        #expect(preview.debugWidgetTreeCount == 2)
        let texts = labelTexts(in: preview.container)
        #expect(texts.contains { $0.contains("First") })
        #expect(texts.contains { $0.contains("Second") })
        #expect(texts.contains { $0.contains("Third") })
        #expect(texts.contains { $0.contains("Fourth") })
    }

    @Test("Preview collapses table cells into a single monospaced Label inside the card wrapper") @MainActor
    func previewCollapsesTableCellsIntoASingleMonospacedLabelInsideTheCard() throws {
        // Phase B.3 (scroll perf): the old Grid + cell-Labels layout
        // exposed ~12 widgets for a 4-row, 2-column table; per-frame
        // GTK snapshot walks dominated scroll CPU on notes that
        // contained even one table. Collapse the table body to a
        // single Pango-markup Label inside the existing `.card`
        // wrapper Box. Column alignment comes from <tt>-monospaced
        // character-count padding.
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.table-collapse")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .table(
                headers: [.plain("Area"), .plain("What")],
                rows: [
                    [.plain("Toolbar"),    .plain("Quick formatting")],
                    [.plain("Split view"), .plain("Side by side")],
                    [.plain("CLI"),        .plain("Automation")],
                ],
                alignments: [.leading, .leading],
            ),
        ])

        #expect(preview.debugTopLevelWidgetCount == 1)
        // Container + card-wrapper Box + single Label = 3 widgets total.
        #expect(preview.debugWidgetTreeCount == 3)
        let texts = labelTexts(in: preview.container)
        #expect(texts.contains { $0.contains("Area") })
        #expect(texts.contains { $0.contains("Toolbar") })
        #expect(texts.contains { $0.contains("Automation") })
    }

    @Test("Preview coalesces long paragraph runs into a single label subtree") @MainActor
    func previewCoalescesLongParagraphRunsIntoASingleLabelSubtree() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.paragraph-run-coalescing")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let blocks = (1 ... 32).map { RenderedBlock.paragraph(.plain("Paragraph \($0)")) }
        preview.render(blocks: blocks)

        #expect(preview.debugTopLevelWidgetCount == 1)
        #expect(preview.debugWidgetTreeCount == 2)
        let mergedText = labelTexts(in: preview.container).joined(separator: "\n")
        #expect(mergedText.contains("Paragraph 1"))
        #expect(mergedText.contains("Paragraph 32"))
    }

    @Test("Preview can force virtualization for long safe documents while preserving plain text") @MainActor
    func previewCanForceVirtualizationForLongSafeDocumentsWhilePreservingPlainText() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.virtualized-preview-safe-doc")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.debugForceVirtualizedRows = true
        let blocks = (1 ... 160).map { RenderedBlock.codeBlock(code: "let item\($0) = \($0)\n", language: "swift") }
        preview.render(blocks: blocks)

        #expect(preview.debugUsesVirtualizedRows)
        #expect(preview.debugTopLevelWidgetCount == 1)
        #expect(preview.container.children().isEmpty)
        #expect(preview.rootScroll.child?.tryCast(ListView.self) != nil)
        #expect(preview.plainText.contains("let item1 = 1"))
        #expect(preview.plainText.contains("let item160 = 160"))
    }

    @Test("Preview incrementally reuses unchanged surrounding rows when middle row needs replacement") @MainActor
    func previewIncrementallyReusesUnchangedSurroundingRowsWhenMiddleRowNeedsReplacement() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.incremental-preview-middle-edit")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .heading(level: 2, text: .plain("Alpha")),
            .codeBlock(code: "let bravo = 1\n", language: "swift"),
            .heading(level: 2, text: .plain("Charlie")),
        ])
        let initialChildren = preview.container.children()
        let initialAddresses = initialChildren.map(widgetAddress)

        preview.render(blocks: [
            .heading(level: 2, text: .plain("Alpha")),
            .codeBlock(code: "let bravo = 2\n", language: "swift"),
            .heading(level: 2, text: .plain("Charlie")),
        ])
        let updatedChildren = preview.container.children()
        let updatedAddresses = updatedChildren.map(widgetAddress)

        #expect(updatedChildren.count == 3)
        #expect(initialAddresses[0] == updatedAddresses[0])
        #expect(initialAddresses[1] != updatedAddresses[1])
        #expect(initialAddresses[2] == updatedAddresses[2])
        #expect(preview.plainText.contains("let bravo = 2"))
    }

    @Test("Preview updates compatible text rows in place within stacked mode") @MainActor
    func previewUpdatesCompatibleTextRowsInPlaceWithinStackedMode() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.incremental-preview-in-place-text")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        // Phase B.1 of SCROLL_PERF_PLAN coalesces a heading + its
        // trailing paragraphs into a single `richTextRun` Label, so
        // `heading + paragraph + blockquote` now renders as 2 widgets
        // (one Label for the rich-text run, one Box for the
        // blockquote) — not 3. The in-place update path still has to
        // reuse those 2 widgets without rebuilding them.
        preview.render(blocks: [
            .heading(level: 2, text: .plain("Heading A")),
            .paragraph(.plain("Paragraph A")),
            .blockquote(.plain("Quote A")),
        ])
        let initialChildren = preview.container.children()
        let initialAddresses = initialChildren.map(widgetAddress)
        #expect(initialChildren.count == 2)

        preview.render(blocks: [
            .heading(level: 1, text: .plain("Heading B")),
            .paragraph(.plain("Paragraph B")),
            .blockquote(.plain("Quote B")),
        ])
        let updatedChildren = preview.container.children()
        let updatedAddresses = updatedChildren.map(widgetAddress)

        #expect(updatedChildren.count == 2)
        #expect(initialAddresses == updatedAddresses)
        let texts = labelTexts(in: preview.container)
        // Heading + paragraph live inside the same Label's markup,
        // separated by the Pango run's `\n\n`. Confirm both spans
        // reached the surviving label.
        #expect(texts.contains(where: { $0.contains("Heading B") }))
        #expect(texts.contains(where: { $0.contains("Paragraph B") }))
        #expect(texts.contains(where: { $0.contains("Quote B") }))
    }

    @Test("Preview can force custom text layout for long safe documents") @MainActor
    func previewCanForceCustomTextLayoutForLongSafeDocuments() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.custom-text-preview-safe-doc")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.debugForceCustomTextLayout = true
        let blocks = (1 ... 160).flatMap { index -> [RenderedBlock] in
            [
                .heading(level: 2, text: .plain("Section \(index)")),
                .paragraph(.plain("Body \(index)")),
            ]
        }
        preview.render(blocks: blocks)

        #expect(preview.debugUsesCustomTextLayout)
        #expect(!preview.debugUsesVirtualizedRows)
        #expect(preview.debugTopLevelWidgetCount == 1)
        #expect(preview.debugWidgetTreeCount == 2)
        #expect(labelTexts(in: preview.container).joined(separator: "\n").contains("Section 1"))
        #expect(labelTexts(in: preview.container).joined(separator: "\n").contains("Body 160"))
    }

    @Test("Preview custom text layout updates existing label instead of rebuilding subtree") @MainActor
    func previewCustomTextLayoutUpdatesExistingLabelInsteadOfRebuildingSubtree() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.custom-text-preview-reuse")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.debugForceCustomTextLayout = true
        preview.render(blocks: (1 ... 160).flatMap { index -> [RenderedBlock] in
            [
                .heading(level: 2, text: .plain("Section \(index)")),
                .paragraph(.plain("Body \(index)")),
            ]
        })
        let initialChildren = preview.container.children()
        let initialAddresses = initialChildren.map(widgetAddress)

        preview.render(blocks: (1 ... 160).flatMap { index -> [RenderedBlock] in
            [
                .heading(level: 2, text: .plain("Section \(index)")),
                .paragraph(.plain(index == 80 ? "Body \(index) updated" : "Body \(index)")),
            ]
        })
        let updatedChildren = preview.container.children()
        let updatedAddresses = updatedChildren.map(widgetAddress)

        #expect(preview.debugUsesCustomTextLayout)
        #expect(updatedChildren.count == 1)
        #expect(initialAddresses == updatedAddresses)
        #expect(labelTexts(in: preview.container).joined(separator: "\n").contains("Body 80 updated"))
    }

    @Test("Preview custom text layout refuses task lists so checkbox rows keep interactivity") @MainActor
    func previewCustomTextLayoutRefusesTaskListsSoCheckboxRowsKeepInteractivity() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.custom-text-preview-task-fallback")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.debugForceCustomTextLayout = true
        preview.render(blocks: [
            .paragraph(.plain("Intro")),
            .listItem(text: .plain("Todo"), depth: 0, marker: "[ ]", taskIndex: 0),
        ])

        #expect(!preview.debugUsesCustomTextLayout)
        #expect(preview.debugTopLevelWidgetCount == 2)
        #expect(labelTexts(in: preview.container).contains("☐"))
    }

    @Test("Preview coalesces consecutive blockquotes but still breaks runs around non-text blocks") @MainActor
    func previewCoalescesConsecutiveBlockquotesButStillBreaksRunsAroundNonTextBlocks() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.blockquote-run-coalescing")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .blockquote(.plain("Quote line 1")),
            .blockquote(.plain("Quote line 2")),
            .codeBlock(code: "let answer = 42\n", language: "swift"),
            .blockquote(.plain("Quote line 3")),
            .blockquote(.plain("Quote line 4")),
        ])

        #expect(preview.debugTopLevelWidgetCount == 3)
        #expect(preview.debugWidgetTreeCount == 22)
        let mergedText = labelTexts(in: preview.container).joined(separator: "\n")
        #expect(mergedText.contains("Quote line 1"))
        #expect(mergedText.contains("Quote line 4"))
        #expect(firstSourceView(in: preview.container)?.buffer.text == "let answer = 42\n")
    }

    @Test("Preview code block renders through a read-only SourceView with matching language") @MainActor
    func previewCodeBlockRendersThroughAReadOnlySourceViewWithMatchingLanguage() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-source-view-swift")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .codeBlock(code: "let answer = 42\n", language: "swift"),
        ])

        guard let sourceView = firstSourceView(in: preview.container) else {
            Issue.record("Expected a SourceView inside the rendered code block")
            return
        }
        #expect(sourceView.editable == false)
        #expect(sourceView.cursorVisible == false)
        #expect(preview.debugWidgetTreeCount == 16)
        #expect(sourceView.buffer.text == "let answer = 42\n")
        #expect(sourceView.buffer.language?.id == "swift")
        #expect(sourceView.buffer.highlightSyntax == true)
    }

    @Test("Preview code block maps common language aliases before looking up the SourceLanguageManager") @MainActor
    func previewCodeBlockMapsCommonLanguageAliasesBeforeLookingUpTheSourceLanguageManager() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-language-aliases")
        try app.register()

        let cases: [(raw: String, expected: String)] = [
            ("js", "typescript"), // GtkSourceView 5.18 merged JS into TS
            ("ts", "typescript"),
            ("py", "python"),
            ("rb", "ruby"),
            ("sh", "sh"),
            ("cpp", "cpp"),
            ("yml", "yaml"),
            ("md", "markdown"),
        ]
        for (raw, expected) in cases {
            let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
            preview.render(blocks: [
                .codeBlock(code: "x\n", language: raw),
            ])
            guard let sourceView = firstSourceView(in: preview.container) else {
                Issue.record("Expected a SourceView for alias \(raw)")
                continue
            }
            #expect(sourceView.buffer.language?.id == expected, "Alias \(raw) should resolve to \(expected)")
        }
    }

    @Test("Preview code block falls back to a language-less SourceBuffer when info-string is missing or unknown") @MainActor
    func previewCodeBlockFallsBackToALanguageLessSourceBufferWhenInfo() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-language-fallback")
        try app.register()

        let noLanguagePreview = MarkdownPreview(remoteImageLoader: { _, _ in })
        noLanguagePreview.render(blocks: [
            .codeBlock(code: "plain\n", language: nil),
        ])
        guard let sourceViewNoLang = firstSourceView(in: noLanguagePreview.container) else {
            Issue.record("Expected a SourceView with no language")
            return
        }
        #expect(sourceViewNoLang.buffer.language == nil)

        let unknownLanguagePreview = MarkdownPreview(remoteImageLoader: { _, _ in })
        unknownLanguagePreview.render(blocks: [
            .codeBlock(code: "plain\n", language: "not-a-real-language-42"),
        ])
        guard let sourceViewUnknown = firstSourceView(in: unknownLanguagePreview.container) else {
            Issue.record("Expected a SourceView for unknown language")
            return
        }
        #expect(sourceViewUnknown.buffer.language == nil)
    }

    @Test("Preview code block exposes a Copy button") @MainActor
    func previewCodeBlockExposesACopyButton() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-copy-button")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .codeBlock(code: "let answer = 42\n", language: "swift"),
        ])

        guard let copyButton = firstButton(in: preview.container) else {
            Issue.record("Expected a Copy button on the rendered code block")
            return
        }
        #expect(copyButton.iconName == "edit-copy-symbolic")
        #expect(copyButton.tooltipText == "Copy code to clipboard")
        #expect(copyButton.hasCSSClass("preview-code-copy"))
    }

    @Test("Preview code block Copy button swaps to a confirmation icon after click and restores") @MainActor
    func previewCodeBlockCopyButtonSwapsToAConfirmationIconAfterClick() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-copy-feedback")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .codeBlock(code: "print(\"hello\")\n", language: "swift"),
        ])
        guard let copyButton = firstButton(in: preview.container) else {
            Issue.record("Expected a Copy button on the rendered code block")
            return
        }

        copyButton.emitClicked()
        #expect(copyButton.iconName == "object-select-symbolic")

        // Icon should restore after roughly one second. Pump the main loop
        // a touch longer to stay robust on slower CI VMs.
        MainContext.pump(for: .milliseconds(1400))
        #expect(copyButton.iconName == "edit-copy-symbolic")
    }

    @Test("Preview code block horizontal minimum fits inside narrow preview") @MainActor
    func previewCodeBlockHorizontalMinimumFitsInsideNarrowPreview() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-horizontal-shrink")
        try app.register()

        let longLine = "flatpak-builder --force-clean --user --install build-dir flatpak/io.github.makoni.SwiftAdwaitaDemo.yml"
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .codeBlock(code: longLine + "\nflatpak run io.github.makoni.SwiftAdwaitaDemo", language: "bash"),
        ])

        let children = preview.container.children()
        #expect(children.count == 1)
        guard let block = children.first else {
            Issue.record("Expected code block widget")
            return
        }

        let measurement = block.measure(orientation: .horizontal)

        #expect(measurement.minimum <= 320)
    }

    @Test("Preview renders standalone image in responsive card with caption") @MainActor
    func previewRendersStandaloneImageInResponsiveCardWithCaption() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let imageURL = temp.appendingPathComponent("hero.svg", isDirectory: false)
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="160" height="90" viewBox="0 0 160 90">
          <rect width="160" height="90" fill="#0a84ff"/>
        </svg>
        """.utf8).write(to: imageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.preview-standalone-image-layout")
        try app.register()

        let narrowPreview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let narrowSize = presentedStandaloneImageCardSize(
            preview: narrowPreview,
            imageURL: imageURL,
            application: app,
            windowWidth: 760,
        )
        let children = narrowPreview.container.children()
        #expect(children.count == 1)
        guard let child = children.first else {
            Issue.record("Expected standalone preview image")
            return
        }

        #expect(child.hasCSSClass("card"))
        #expect(child.hasCSSClass("preview-image-card"))
        #expect(labelTexts(in: child).contains("Hero artwork"))
        #expect(narrowPreview.debugWidgetTreeCount == 6)
        #expect(child.measure(orientation: .horizontal).natural >= narrowSize.width + 28)
        #expect(abs(Double(narrowSize.height) - (Double(narrowSize.width) * 90.0 / 160.0)) <= 4)

        #expect(firstClamp(in: narrowPreview.container) != nil)

        let widePreview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let wideSize = presentedStandaloneImageCardSize(
            preview: widePreview,
            imageURL: imageURL,
            application: app,
            windowWidth: 1080,
        )
        #expect(wideSize.height == narrowSize.height)
        #expect(wideSize.width == narrowSize.width)
        #expect(abs(Double(wideSize.height) - (Double(wideSize.width) * 90.0 / 160.0)) <= 4)
    }

    @Test("Preview renders remote web P image after asynchronous completion") @MainActor
    func previewRendersRemoteWebPImageAfterAsynchronousCompletion() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-preview.webp", isDirectory: false)
        try tinyWebPData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-webp")
        try app.register()

        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { _, completion in
            pendingCompletion = completion
        })

        preview.render(blocks: [
            .image(alt: "WebP image", source: "https://example.invalid/test.webp", title: nil),
        ])

        let picture = firstPicture(in: preview.container)
        #expect(picture != nil)
        #expect(pictureHasPaintable(picture) == false)

        guard let pendingCompletion else {
            Issue.record("Expected remote WEBP completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        #expect(await waitForPaintable(picture, timeout: .seconds(3)))

        #expect(firstClamp(in: preview.container).map {
            measuredNaturalSize(of: $0, orientation: .vertical, forSize: 300)
        } ?? 0 > 0)
    }

    @Test("Presented preview allocates remote web P image after asynchronous completion") @MainActor
    func presentedPreviewAllocatesRemoteWebPImageAfterAsynchronousCompletion() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-preview.webp", isDirectory: false)
        try tinyWebPData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.presented-remote-preview-webp")
        try app.register()

        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { _, completion in
            pendingCompletion = completion
        })
        let window = ApplicationWindow(application: app)
        let editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.setSizeRequest(width: 500, height: 400)
        let pane = Paned(orientation: .horizontal)
        pane.startChild = editorHost
        pane.endChild = preview.rootScroll
        pane.resizeStartChild = true
        pane.resizeEndChild = false
        pane.shrinkStartChild = false
        pane.shrinkEndChild = true
        window.setDefaultSize(width: 1100, height: 760)
        window.setContent(pane)
        preview.attach(to: window)
        window.present()
        pumpMainContext(for: .milliseconds(40))

        preview.render(blocks: [
            .image(alt: "WebP image", source: "https://example.invalid/test.webp", title: nil),
        ])
        pumpMainContext(for: .milliseconds(40))

        guard let pendingCompletion else {
            Issue.record("Expected remote WEBP completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        pumpMainContext(for: .milliseconds(80))

        guard let picture = firstPicture(in: preview.container),
              let clamp = firstClamp(in: preview.container)
        else {
            Issue.record("Expected remote WEBP preview widgets")
            return
        }

        #expect(await waitForPaintable(picture, timeout: .seconds(3)))
        #expect(clamp.width > 0)
        #expect(clamp.height > 0)
        #expect(picture.width > 0)
        #expect(picture.height > 0)
    }

    @Test("Preview renders remote GIF image after asynchronous completion") @MainActor
    func previewRendersRemoteGIFImageAfterAsynchronousCompletion() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-preview.gif", isDirectory: false)
        try animatedGIFData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-gif")
        try app.register()

        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { _, completion in
            pendingCompletion = completion
        })

        preview.render(blocks: [
            .image(alt: "GIF image", source: "https://example.invalid/test.gif", title: nil),
        ])

        let picture = firstPicture(in: preview.container)
        #expect(picture != nil)
        #expect(preview.debugAnimatedImagePlayerCount == 0)

        guard let pendingCompletion else {
            Issue.record("Expected remote GIF completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        try await Task.sleep(for: .milliseconds(20))

        #expect(pictureHasPaintable(picture))
        #expect(preview.debugAnimatedImagePlayerCount == 1)
        #expect(firstClamp(in: preview.container).map {
            measuredNaturalSize(of: $0, orientation: .vertical, forSize: 300)
        } ?? 0 > 0)
    }

    @Test("Presented preview allocates remote GIF image after asynchronous completion") @MainActor
    func presentedPreviewAllocatesRemoteGIFImageAfterAsynchronousCompletion() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-preview.gif", isDirectory: false)
        try animatedGIFData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.presented-remote-preview-gif")
        try app.register()

        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { _, completion in
            pendingCompletion = completion
        })
        let window = ApplicationWindow(application: app)
        let editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.setSizeRequest(width: 500, height: 400)
        let pane = Paned(orientation: .horizontal)
        pane.startChild = editorHost
        pane.endChild = preview.rootScroll
        pane.resizeStartChild = true
        pane.resizeEndChild = false
        pane.shrinkStartChild = false
        pane.shrinkEndChild = true
        window.setDefaultSize(width: 1100, height: 760)
        window.setContent(pane)
        preview.attach(to: window)
        window.present()
        pumpMainContext(for: .milliseconds(40))

        preview.render(blocks: [
            .image(alt: "GIF image", source: "https://example.invalid/test.gif", title: nil),
        ])
        pumpMainContext(for: .milliseconds(40))

        guard let pendingCompletion else {
            Issue.record("Expected remote GIF completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        pumpMainContext(for: .milliseconds(120))

        guard let picture = firstPicture(in: preview.container),
              let clamp = firstClamp(in: preview.container)
        else {
            Issue.record("Expected remote GIF preview widgets")
            return
        }

        #expect(pictureHasPaintable(picture))
        #expect(clamp.width > 0)
        #expect(clamp.height > 0)
        #expect(picture.width > 0)
        #expect(picture.height > 0)
        #expect(preview.debugAnimatedImagePlayerCount == 1)
    }

    @Test("Presented preview allocates standalone remote images after badge rows") @MainActor
    func presentedPreviewAllocatesStandaloneRemoteImagesAfterBadgeRows() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let badgeURL = temp.appendingPathComponent("badge.svg", isDirectory: false)
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="20" viewBox="0 0 120 20">
          <rect width="120" height="20" fill="#0a84ff"/>
        </svg>
        """.utf8).write(to: badgeURL, options: .atomic)

        let webpURL = temp.appendingPathComponent("hero.webp", isDirectory: false)
        try tinyWebPData().write(to: webpURL, options: .atomic)

        let gifURL = temp.appendingPathComponent("demo.gif", isDirectory: false)
        try animatedGIFData().write(to: gifURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.presented-preview-badges-and-images")
        try app.register()

        var pendingCompletions: [String: PreviewRemoteImageLoadCompletion] = [:]
        let preview = MarkdownPreview(remoteImageLoader: { url, completion in
            pendingCompletions[url.absoluteString] = completion
        })
        let window = ApplicationWindow(application: app)
        let editorHost = Box(orientation: .vertical, spacing: 0)
        editorHost.setSizeRequest(width: 500, height: 400)
        let pane = Paned(orientation: .horizontal)
        pane.startChild = editorHost
        pane.endChild = preview.rootScroll
        pane.resizeStartChild = true
        pane.resizeEndChild = false
        pane.shrinkStartChild = false
        pane.shrinkEndChild = true
        window.setDefaultSize(width: 1100, height: 760)
        window.setContent(pane)
        preview.attach(to: window)
        window.present()
        pumpMainContext(for: .milliseconds(40))

        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        [![CI](badge.svg)](https://example.invalid/ci)
        [![Swift](badge.svg)](https://example.invalid/swift)
        [![Documentation](badge.svg)](https://example.invalid/docs)
        [![License](badge.svg)](https://example.invalid/license)

        <img alt="Swift Adwaita" src="https://example.invalid/hero.webp">

        Preview paragraph

        <img alt="Swift Adwaita Demo" src="https://example.invalid/demo.gif">
        """)
        preview.render(blocks: blocks, baseDirectory: temp)
        pumpMainContext(for: .milliseconds(40))

        pendingCompletions["https://example.invalid/hero.webp"]?(webpURL)
        pendingCompletions["https://example.invalid/demo.gif"]?(gifURL)
        pumpMainContext(for: .milliseconds(120))

        let imageClamps = clamps(in: preview.container)
        #expect(imageClamps.count == 2)
        #expect(imageClamps.allSatisfy { $0.width > 0 })
        #expect(imageClamps.allSatisfy { $0.height > 0 })
    }

    @Test("Preview auto plays remote GIF image after asynchronous completion") @MainActor
    func previewAutoPlaysRemoteGIFImageAfterAsynchronousCompletion() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let downloadedImageURL = temp.appendingPathComponent("remote-preview.gif", isDirectory: false)
        try animatedGIFData().write(to: downloadedImageURL, options: .atomic)

        let app = Application(id: "me.spaceinbox.swiftynotes.tests.animated-gif-player-autoplay")
        try app.register()

        var pendingCompletion: PreviewRemoteImageLoadCompletion?
        let preview = MarkdownPreview(remoteImageLoader: { _, completion in
            pendingCompletion = completion
        })

        preview.render(blocks: [
            .image(alt: "GIF image", source: "https://example.invalid/test.gif", title: nil),
        ])

        let picture = firstPicture(in: preview.container)
        #expect(picture != nil)

        guard let pendingCompletion, let picture else {
            Issue.record("Expected remote GIF completion and picture")
            return
        }

        pendingCompletion(downloadedImageURL)
        pumpMainContext(for: .milliseconds(20))

        #expect(preview.debugAnimatedImagePlayerCount == 1)
        let initialIdentity = picturePaintableIdentity(picture)
        #expect(initialIdentity != nil)
        #expect(waitForPaintableChange(in: picture, from: initialIdentity, timeout: .milliseconds(250)))
    }

    @Test("Animated GIF player advances frames") @MainActor
    func animatedGIFPlayerAdvancesFrames() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let animatedGIFURL = temp.appendingPathComponent("animated.gif", isDirectory: false)
        try animatedGIFData().write(to: animatedGIFURL, options: .atomic)

        let picture = Picture()
        let player = PreviewAnimatedImagePlayer(localURL: animatedGIFURL, picture: picture, autoSchedule: false)

        #expect(player != nil)
        let initialIdentity = picturePaintableIdentity(picture)
        #expect(initialIdentity != nil)

        try await Task.sleep(for: .milliseconds(120))
        player?.advanceFrame()

        let advancedIdentity = picturePaintableIdentity(picture)
        #expect(advancedIdentity != nil)
        #expect(initialIdentity != advancedIdentity)
    }

    @MainActor
    private func firstPicture(in widget: Widget) -> Picture? {
        if let picture = widget.tryCast(Picture.self) {
            return picture
        }
        for child in widget.children() {
            if let picture = firstPicture(in: child) {
                return picture
            }
        }
        return nil
    }

    @MainActor
    private func firstButton(in widget: Widget) -> Button? {
        if let button = widget.tryCast(Button.self) {
            return button
        }
        for child in widget.children() {
            if let button = firstButton(in: child) {
                return button
            }
        }
        return nil
    }

    @MainActor
    private func firstSourceView(in widget: Widget) -> SourceView? {
        if let view = widget.tryCast(SourceView.self) {
            return view
        }
        for child in widget.children() {
            if let view = firstSourceView(in: child) {
                return view
            }
        }
        return nil
    }


    @MainActor
    private func firstHBox(in widget: Widget) -> Box? {
        if let box = widget.tryCast(Box.self), box.orientation == .horizontal {
            return box
        }
        for child in widget.children() {
            if let hbox = firstHBox(in: child) {
                return hbox
            }
        }
        return nil
    }

    @MainActor
    private func firstClamp(in widget: Widget) -> Clamp? {
        if let clamp = widget.tryCast(Clamp.self) {
            return clamp
        }
        for child in widget.children() {
            if let clamp = firstClamp(in: child) {
                return clamp
            }
        }
        return nil
    }

    @MainActor
    private func clamps(in widget: Widget) -> [Clamp] {
        var results: [Clamp] = []
        if let clamp = widget.tryCast(Clamp.self) {
            results.append(clamp)
        }
        for child in widget.children() {
            results.append(contentsOf: clamps(in: child))
        }
        return results
    }

    @MainActor
    private func buttonChild(_ button: Button) -> Widget? {
        button.child
    }

    @MainActor
    private func pictureFilePath(_ picture: Picture?) -> String? {
        picture?.fileURL?.path(percentEncoded: false)
    }

    @MainActor
    private func pictureHasPaintable(_ picture: Picture?) -> Bool {
        picture?.hasPaintable == true
    }

    @MainActor
    private func widgetAddress(_ widget: Widget) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(widget.widgetPointer))
    }

    @MainActor
    private func picturePaintableIdentity(_ picture: Picture?) -> Picture.PaintableIdentity? {
        picture?.paintableIdentity
    }

    @MainActor
    private func measuredNaturalSize(of widget: Widget, orientation: GtkOrientation, forSize: Int = -1) -> Int {
        widget.measure(orientation: orientation, forSize: forSize).natural
    }

    @MainActor
    private func presentedStandaloneImageCardSize(
        preview: MarkdownPreview,
        imageURL: URL,
        application: Application,
        windowWidth: Int,
    ) -> (width: Int, height: Int) {
        let window = ApplicationWindow(application: application)
        window.setDefaultSize(width: windowWidth, height: 760)
        window.setContent(preview.rootScroll)
        preview.attach(to: window)
        preview.render(blocks: [
            .image(alt: "Hero artwork", source: imageURL.path(), title: nil),
        ])
        window.present()
        pumpMainContext(for: .milliseconds(120))

        guard let clamp = firstClamp(in: preview.container) else {
            Issue.record("Expected responsive clamp in standalone image card")
            return (0, 0)
        }
        let effectiveWidth = min(
            clamp.maximumSize,
            measuredNaturalSize(of: clamp, orientation: .horizontal),
        )
        let effectiveHeight = measuredNaturalSize(of: clamp, orientation: .vertical, forSize: effectiveWidth)
        return (effectiveWidth, effectiveHeight)
    }

    @MainActor
    private func labelTexts(in widget: Widget) -> [String] {
        var texts: [String] = []
        if let label = widget.tryCast(Label.self) {
            texts.append(label.text)
        }
        for child in widget.children() {
            texts.append(contentsOf: labelTexts(in: child))
        }
        return texts
    }

    private func tinyWebPData() throws -> Data {
        guard let data = Data(base64Encoded: "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA=") else {
            throw TestFixtureError.invalidBase64
        }
        return data
    }

    private func animatedGIFData() throws -> Data {
        guard let data = Data(base64Encoded: "R0lGODlhAgACAPAAAP8AAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQAAAAAACwAAAAAAgACAAACAoRRACH5BAAKAAAALAAAAAACAAIAgAAA/wAAAAIChFEAOw==") else {
            throw TestFixtureError.invalidBase64
        }
        return data
    }

    @MainActor
    private func pumpMainContext(for duration: Duration) {
        MainContext.pump(for: duration)
    }

    @MainActor
    private func waitForPaintable(
        _ picture: Picture?,
        timeout: Duration,
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            MainContext.drainPending()
            if pictureHasPaintable(picture) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        MainContext.drainPending()
        return pictureHasPaintable(picture)
    }

    @MainActor
    private func waitForPaintableChange(
        in picture: Picture,
        from initialIdentity: Picture.PaintableIdentity?,
        timeout: Duration,
    ) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            MainContext.drainPending()
            if picturePaintableIdentity(picture) != initialIdentity {
                return true
            }
            MainContext.pump(for: .milliseconds(2))
        }
        MainContext.drainPending()
        return picturePaintableIdentity(picture) != initialIdentity
    }
}

private enum TestFixtureError: Error {
    case invalidBase64
}
#endif
