import Foundation
import Testing
@testable import SwiftyNotes
import Adwaita
import CAdwaita

struct NoteModelAndRendererTests {
    @Test
    func derivedTitleUsesFirstMeaningfulLine() {
        let title = Note.derivedTitle(from: "\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test
    func derivedTitleSkipsLeadingStandaloneImage() {
        let title = Note.derivedTitle(from: "![Cover](assets/cover.png)\n\n# Hello world\nBody")
        #expect(title == "Hello world")
    }

    @Test
    func derivedTitleFallsBackForEmptyNote() {
        #expect(Note.derivedTitle(from: " \n\n ") == "New Note")
    }

    @Test
    func noteRetitleReplacesFirstMeaningfulLine() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "Shopping list\n- eggs"
        )

        let renamed = note.retitled("Groceries")
        #expect(renamed.title == "Groceries")
        #expect(renamed.content.hasPrefix("Groceries"))
    }

    @Test
    func noteRetitlePreservesLeadingImageAndReplacesHeadingAfterIt() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "![Cover](assets/cover.png)\n\n# Original\n\nBody"
        )

        let renamed = note.retitled("Updated")
        #expect(renamed.title == "Updated")
        #expect(renamed.content == "![Cover](assets/cover.png)\n\n# Updated\n\nBody")
    }

    @Test
    func noteSearchAndExportFilenameUseReadableTitle() {
        let note = Note(
            id: UUID(),
            filename: "note.md",
            createdAt: Date(),
            updatedAt: Date(),
            content: "# Hello, Swift GTK!"
        )

        #expect(note.matches(searchQuery: "swift gtk"))
        #expect(note.suggestedExportFilename == "hello-swift-gtk.md")
        #expect(note.stableID == note.id.uuidString.lowercased())
    }

    @Test
    func rendererBuildsHeadingAndParagraphBlocks() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: "# Title\n\nParagraph", darkAppearance: false)
        #expect(blocks.count >= 2)
        #expect(blocks.first?.style == .heading(level: 1))
        #expect(blocks.first?.text == "Title")
    }

    @Test
    func rendererBuildsTaskListMarkers() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [x] Done
        - [ ] Todo
        """, darkAppearance: false)

        #expect(blocks.count == 2)
        #expect(blocks[0] == .listItem(text: .plain("Done"), depth: 0, marker: "[x]"))
        #expect(blocks[1] == .listItem(text: .plain("Todo"), depth: 0, marker: "[ ]"))
    }

    @Test
    func rendererPreservesTaskListMarkersWhenItemContainsInlineMarkdown() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        - [ ] Если было выделено **слово**, то после нажатия должно быть `код`
        """, darkAppearance: false)

        #expect(blocks.count == 1)
        guard case let .listItem(text, depth, marker) = blocks[0] else {
            Issue.record("Expected a task list item block")
            return
        }

        #expect(depth == 0)
        #expect(marker == "[ ]")
        #expect(text.plainText == "Если было выделено слово, то после нажатия должно быть код")
    }

    @Test
    func rendererUsesThemeAwareInlineCodeBackground() {
        let renderer = MarkdownRenderer()
        let lightBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: false)
        let darkBlocks = renderer.blocks(for: "Use `code` here", darkAppearance: true)

        guard case let .paragraph(lightText) = lightBlocks.first,
              case let .paragraph(darkText) = darkBlocks.first else {
            Issue.record("Expected paragraph blocks")
            return
        }

        #expect(lightText.markup.contains("font_family=\"monospace\""))
        #expect(lightText.markup.contains("background=\"#f6f5f4\""))
        #expect(darkText.markup.contains("background=\"#3b3644\""))
        #expect(lightText.markup != darkText.markup)
    }

    @Test
    func rendererBuildsStandaloneImageBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: "![Swift and Adwaita showcase artwork](markdown-demo-image.png)",
            darkAppearance: false
        )

        #expect(blocks == [
            .image(
                alt: "Swift and Adwaita showcase artwork",
                source: "markdown-demo-image.png",
                title: nil
            )
        ])
    }

    @Test
    func rendererBuildsStandaloneHTMLImageBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(
            for: #"<img alt="Swift Adwaita" src="https://spaceinbox.me/images/swift-adwaita-2.webp">"#,
            darkAppearance: false
        )

        #expect(blocks == [
            .image(
                alt: "Swift Adwaita",
                source: "https://spaceinbox.me/images/swift-adwaita-2.webp",
                title: nil
            )
        ])
    }

    @Test @MainActor
    func rendererBuildsImageGroupForLinkedBadgeImages() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        [![CI](https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml/badge.svg)](https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml)
        [![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg)](https://swift.org)
        """, darkAppearance: false)

        #expect(blocks == [
            .imageGroup(items: [
                .init(
                    alt: "CI",
                    source: "https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml/badge.svg",
                    title: nil,
                    linkDestination: "https://github.com/makoni/swift-adwaita/actions/workflows/ci.yml"
                ),
                .init(
                    alt: "Swift 6.0+",
                    source: "https://img.shields.io/badge/Swift-6.0+-F05138.svg",
                    title: nil,
                    linkDestination: "https://swift.org"
                )
            ])
        ])
    }

    @Test @MainActor
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
            .image(alt: "Swift badge", source: remoteSource, title: nil)
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

    @Test @MainActor
    func previewLoadsRemoteLinkedImageGroupWhenLoaderProvidesLocalFileAfterAsynchronousCompletion() async throws {
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
                    linkDestination: "https://spaceinbox.me/docs/swift-adwaita/documentation/adwaita"
                )
            ])
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

    @Test @MainActor
    func previewRendersLinkedBadgeGroupsWithoutFixedWidthPadding() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-badge-layout")
        try app.register()

        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .imageGroup(items: [
                .init(
                    alt: "Swift badge",
                    source: "https://img.shields.io/badge/Swift-6.0+-F05138.svg",
                    title: nil,
                    linkDestination: "https://swift.org"
                )
            ])
        ])

        guard let button = firstButton(in: preview.container),
              let child = buttonChild(button) else {
            Issue.record("Expected linked badge button content")
            return
        }

        var width: Int32 = 0
        var height: Int32 = 0
        gtk_widget_get_size_request(child.widgetPointer, &width, &height)
        let buttonNaturalHeight = measuredNaturalSize(of: button, orientation: GTK_ORIENTATION_VERTICAL)

        #expect(g_type_check_instance_is_a(child.pointer.assumingMemoryBound(to: GTypeInstance.self), gtk_picture_get_type()) != 0)
        #expect(width == -1)
        #expect(height == 18)
        #expect(buttonNaturalHeight <= 22)
    }

    @Test @MainActor
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
                    linkDestination: "https://example.invalid"
                )
            ])
        ])

        guard let button = firstButton(in: preview.container),
              let child = buttonChild(button) else {
            Issue.record("Expected linked badge button content")
            return
        }

        var width: Int32 = 0
        var height: Int32 = 0
        gtk_widget_get_size_request(child.widgetPointer, &width, &height)

        #expect(width == 108)
        #expect(height == 18)
    }

    @Test @MainActor
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
                .init(alt: "License", source: badgeURL.path(), title: nil, linkDestination: "https://example.invalid/license")
            ])
        ])

        guard let badgeRow = firstHBox(in: preview.container) else {
            Issue.record("Expected horizontal box for badge group")
            return
        }

        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(badgeRow.widgetPointer, GTK_ORIENTATION_HORIZONTAL, 18, &minimum, &natural, nil, nil)

        #expect(minimum > 0)
        #expect(natural >= minimum)
    }

    @Test @MainActor
    func previewTableHorizontalMinimumFitsInsideNarrowPreview() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.table-horizontal-shrink")
        try app.register()

        let wideCell = RenderedText(
            markup: "ListStore, StringList, FilterListModel, SortListModel, MapListModel, FlattenListModel, TreeListModel, SelectionFilterModel",
            plainText: "ListStore, StringList, FilterListModel, SortListModel, MapListModel, FlattenListModel, TreeListModel, SelectionFilterModel"
        )
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .table(
                headers: [
                    RenderedText(markup: "Protocol", plainText: "Protocol"),
                    RenderedText(markup: "Purpose", plainText: "Purpose"),
                    RenderedText(markup: "Conforming Types", plainText: "Conforming Types")
                ],
                rows: [[
                    RenderedText(markup: "ListModelConvertible", plainText: "ListModelConvertible"),
                    RenderedText(markup: "Pass models to list views", plainText: "Pass models to list views"),
                    wideCell
                ]],
                alignments: [.leading, .leading, .leading]
            )
        ])

        let children = preview.container.children()
        #expect(children.count == 1)
        guard let block = children.first else {
            Issue.record("Expected table block widget")
            return
        }

        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(block.widgetPointer, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)

        #expect(minimum <= 320)
    }

    @Test @MainActor
    func previewListItemHorizontalMinimumFitsInsideNarrowPreview() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.list-item-horizontal-shrink")
        try app.register()

        let longContent = "Zero raw pointers in public API — all OpaquePointer/gpointer hidden behind Swift types, SignalName, PropertyName, CSSClass, IconName"
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .listItem(text: .plain(longContent), depth: 0, marker: "-")
        ])

        let children = preview.container.children()
        #expect(children.count == 1)
        guard let block = children.first else {
            Issue.record("Expected list widget")
            return
        }

        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(block.widgetPointer, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)

        #expect(minimum <= 320)
    }

    @Test @MainActor
    func previewCodeBlockHorizontalMinimumFitsInsideNarrowPreview() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.code-block-horizontal-shrink")
        try app.register()

        let longLine = "flatpak-builder --force-clean --user --install build-dir flatpak/io.github.makoni.SwiftAdwaitaDemo.yml"
        let preview = MarkdownPreview(remoteImageLoader: { _, _ in })
        preview.render(blocks: [
            .codeBlock(code: longLine + "\nflatpak run io.github.makoni.SwiftAdwaitaDemo", language: "bash")
        ])

        let children = preview.container.children()
        #expect(children.count == 1)
        guard let block = children.first else {
            Issue.record("Expected code block widget")
            return
        }

        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(block.widgetPointer, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)

        #expect(minimum <= 320)
    }

    @Test @MainActor
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
            windowWidth: 760
        )
        let children = narrowPreview.container.children()
        #expect(children.count == 1)
        guard let child = children.first else {
            Issue.record("Expected standalone preview image")
            return
        }

        #expect(gtk_widget_has_css_class(child.widgetPointer, "card") != 0)
        #expect(labelTexts(in: child).contains("Hero artwork"))
        #expect(abs(Double(narrowSize.height) - (Double(narrowSize.width) * 90.0 / 160.0)) <= 4)

        #expect(firstClamp(in: narrowPreview.container) != nil)

        let widePreview = MarkdownPreview(remoteImageLoader: { _, _ in })
        let wideSize = presentedStandaloneImageCardSize(
            preview: widePreview,
            imageURL: imageURL,
            application: app,
            windowWidth: 1080
        )
        #expect(wideSize.height == narrowSize.height)
        #expect(wideSize.width == narrowSize.width)
        #expect(abs(Double(wideSize.height) - (Double(wideSize.width) * 90.0 / 160.0)) <= 4)
    }

    @Test @MainActor
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
            .image(alt: "WebP image", source: "https://example.invalid/test.webp", title: nil)
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
            measuredNaturalSize(of: $0, orientation: GTK_ORIENTATION_VERTICAL, forSize: 300)
        } ?? 0 > 0)
    }

    @Test @MainActor
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
            .image(alt: "WebP image", source: "https://example.invalid/test.webp", title: nil)
        ])
        pumpMainContext(for: .milliseconds(40))

        guard let pendingCompletion else {
            Issue.record("Expected remote WEBP completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        pumpMainContext(for: .milliseconds(80))

        guard let picture = firstPicture(in: preview.container),
              let clamp = firstClamp(in: preview.container) else {
            Issue.record("Expected remote WEBP preview widgets")
            return
        }

        #expect(await waitForPaintable(picture, timeout: .seconds(3)))
        #expect(clamp.width > 0)
        #expect(clamp.height > 0)
        #expect(picture.width > 0)
        #expect(picture.height > 0)
    }

    @Test @MainActor
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
            .image(alt: "GIF image", source: "https://example.invalid/test.gif", title: nil)
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
            measuredNaturalSize(of: $0, orientation: GTK_ORIENTATION_VERTICAL, forSize: 300)
        } ?? 0 > 0)
    }

    @Test @MainActor
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
            .image(alt: "GIF image", source: "https://example.invalid/test.gif", title: nil)
        ])
        pumpMainContext(for: .milliseconds(40))

        guard let pendingCompletion else {
            Issue.record("Expected remote GIF completion")
            return
        }

        pendingCompletion(downloadedImageURL)
        pumpMainContext(for: .milliseconds(120))

        guard let picture = firstPicture(in: preview.container),
              let clamp = firstClamp(in: preview.container) else {
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

    @Test @MainActor
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

    @Test @MainActor
    func previewAutoPlaysRemoteGIFImageAfterAsynchronousCompletion() async throws {
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
            .image(alt: "GIF image", source: "https://example.invalid/test.gif", title: nil)
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
        let initialPaintable = picturePaintablePointer(picture)
        #expect(initialPaintable != nil)
        #expect(waitForPaintableChange(in: picture, from: initialPaintable, timeout: .milliseconds(250)))
    }

    @Test @MainActor
    func animatedGIFPlayerAdvancesFrames() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let animatedGIFURL = temp.appendingPathComponent("animated.gif", isDirectory: false)
        try animatedGIFData().write(to: animatedGIFURL, options: .atomic)

        let picture = Picture()
        let player = PreviewAnimatedImagePlayer(localURL: animatedGIFURL, picture: picture, autoSchedule: false)

        #expect(player != nil)
        let initialPaintable = picturePaintablePointer(picture)
        #expect(initialPaintable != nil)

        try await Task.sleep(for: .milliseconds(120))
        player?.advanceFrame()

        let advancedPaintable = picturePaintablePointer(picture)
        #expect(advancedPaintable != nil)
        #expect(initialPaintable != advancedPaintable)
    }

    @Test
    func rendererBuildsAlignedTableBlock() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: """
        | Feature | Example | Result |
        | :-- | :-- | :-: |
        | Emphasis | `**bold**` | Ready |
        | Checklist | `- [x] Ship it` | Ready |
        """, darkAppearance: false)

        guard case let .table(headers, rows, alignments) = blocks.first else {
            Issue.record("Expected a table block")
            return
        }

        #expect(headers.map(\.plainText) == ["Feature", "Example", "Result"])
        #expect(rows.count == 2)
        #expect(rows[0].map(\.plainText) == ["Emphasis", "**bold**", "Ready"])
        #expect(rows[1].map(\.plainText) == ["Checklist", "- [x] Ship it", "Ready"])
        #expect(alignments == [.leading, .leading, .center])
    }

    @Test
    func htmlSubsetParserTreatsUnsupportedTagsAsLiteralText() {
        let nodes = HTMLSubsetParser().parse("<pre><code>swiftynotes cli get <note-id></code></pre>")
        let blocks = HTMLPreviewDocumentBuilder(darkAppearance: false).blocks(from: nodes, listDepth: 0)

        #expect(blocks == [
            .codeBlock(code: "swiftynotes cli get <note-id>", language: nil)
        ])
    }

    @Test
    func rendererBuildsBlocksForCLISeedNote() {
        let renderer = MarkdownRenderer()
        let blocks = renderer.blocks(for: SwiftyNotesCLISeed.content, darkAppearance: false)

        #expect(!blocks.isEmpty)
        #expect(blocks.contains { block in
            if case let .heading(level, text) = block {
                return level == 1 && text.plainText == "Using Swifty Notes CLI"
            }
            return false
        })
        #expect(blocks.contains { block in
            if case let .codeBlock(code, language) = block {
                return language == "bash" && code.contains("swiftynotes cli list")
            }
            return false
        })
    }

    @Test
    func previewRenderDeferralWaitsForVisibleAllocatedPreviewPane() {
        #expect(MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: true,
            width: 0,
            height: 320
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 0,
            windowHeight: 0,
            hasParent: true,
            hasRoot: false,
            width: 540,
            height: 320
        ))
    }

    @Test
    func previewRenderDeferralSkipsDetachedOrHiddenPreviewPane() {
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: true,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: false,
            hasRoot: false,
            width: 0,
            height: 0
        ))
        #expect(!MainWindow.shouldDeferPreviewRender(
            isPreviewPresented: false,
            windowWidth: 1200,
            windowHeight: 800,
            hasParent: true,
            hasRoot: false,
            width: 0,
            height: 0
        ))
    }

    @Test @MainActor
    func autosaveCoordinatorRunsLatestTask() async {
        let scheduler = TestMainActorScheduler()
        let autosave = AutosaveCoordinator(taskScheduler: scheduler.schedule(after:operation:))
        var values: [Int] = []

        autosave.scheduleSave(after: .milliseconds(10)) {
            values.append(1)
        }
        autosave.scheduleSave(after: .milliseconds(10)) {
            values.append(2)
        }

        scheduler.runPendingActions()

        #expect(values == [2])
    }

    @MainActor
    private func firstPicture(in widget: Widget) -> Picture? {
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_picture_get_type()) != 0 {
            return Picture(borrowing: widget.pointer)
        }

        for child in widget.children() {
            if let picture = firstPicture(in: child) {
                return picture
            }
        }
        return nil
    }

    @MainActor
    private func firstButton(in widget: Widget) -> Widget? {
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0 {
            return widget
        }

        for child in widget.children() {
            if let button = firstButton(in: child) {
                return button
            }
        }
        return nil
    }

    @MainActor
    private func firstHBox(in widget: Widget) -> Box? {
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_box_get_type()) != 0 {
            let box = Box(borrowing: widget.pointer)
            if gtk_orientable_get_orientation(OpaquePointer(widget.pointer)) == GTK_ORIENTATION_HORIZONTAL {
                return box
            }
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
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, adw_clamp_get_type()) != 0 {
            return Clamp(borrowing: widget.pointer)
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
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        var results: [Clamp] = []
        if g_type_check_instance_is_a(instance, adw_clamp_get_type()) != 0 {
            results.append(Clamp(borrowing: widget.pointer))
        }
        for child in widget.children() {
            results.append(contentsOf: clamps(in: child))
        }
        return results
    }

    @MainActor
    private func buttonChild(_ button: Widget) -> Widget? {
        guard let child = gtk_button_get_child(button.pointer.assumingMemoryBound(to: GtkButton.self)) else {
            return nil
        }
        return Widget(borrowing: UnsafeMutableRawPointer(child))
    }

    private func pictureFilePath(_ picture: Picture?) -> String? {
        guard let picture,
              let file = gtk_picture_get_file(OpaquePointer(picture.pointer)),
              let path = g_file_get_path(file) else {
            return nil
        }
        defer { g_free(path) }
        return String(cString: path)
    }

    private func pictureHasPaintable(_ picture: Picture?) -> Bool {
        guard let picture else { return false }
        return gtk_picture_get_paintable(OpaquePointer(picture.pointer)) != nil
    }

    private func picturePaintablePointer(_ picture: Picture?) -> UnsafeMutableRawPointer? {
        guard let picture,
              let paintable = gtk_picture_get_paintable(OpaquePointer(picture.pointer)) else {
            return nil
        }
        return UnsafeMutableRawPointer(paintable)
    }

    @MainActor
    private func measuredNaturalSize(of widget: Widget, orientation: GtkOrientation, forSize: Int32 = -1) -> Int {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(widget.widgetPointer, orientation, forSize, &minimum, &natural, nil, nil)
        return Int(natural)
    }

    @MainActor
    private func presentedStandaloneImageCardSize(
        preview: MarkdownPreview,
        imageURL: URL,
        application: Application,
        windowWidth: Int
    ) -> (width: Int, height: Int) {
        let window = ApplicationWindow(application: application)
        window.setDefaultSize(width: windowWidth, height: 760)
        window.setContent(preview.rootScroll)
        preview.attach(to: window)
        preview.render(blocks: [
            .image(alt: "Hero artwork", source: imageURL.path(), title: nil)
        ])
        window.present()
        pumpMainContext(for: .milliseconds(120))

        guard let clamp = firstClamp(in: preview.container) else {
            Issue.record("Expected responsive clamp in standalone image card")
            return (0, 0)
        }
        let effectiveWidth = min(
            clamp.maximumSize,
            measuredNaturalSize(of: clamp, orientation: GTK_ORIENTATION_HORIZONTAL)
        )
        let effectiveHeight = measuredNaturalSize(of: clamp, orientation: GTK_ORIENTATION_VERTICAL, forSize: Int32(effectiveWidth))
        return (effectiveWidth, effectiveHeight)
    }

    @MainActor
    private func labelTexts(in widget: Widget) -> [String] {
        let instance = widget.pointer.assumingMemoryBound(to: GTypeInstance.self)
        var texts: [String] = []
        if g_type_check_instance_is_a(instance, gtk_label_get_type()) != 0 {
            texts.append(Label(borrowing: widget.pointer).text)
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
        let interval = duration.components
        let totalNanoseconds = (interval.seconds * 1_000_000_000) + Int64(interval.attoseconds / 1_000_000_000)
        let deadline = Date().addingTimeInterval(Double(totalNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            g_usleep(1_000)
        }
        while g_main_context_iteration(nil, 0) != 0 {}
    }

    @MainActor
    private func waitForPaintable(
        _ picture: Picture?,
        timeout: Duration
    ) async -> Bool {
        let interval = timeout.components
        let totalNanoseconds = (interval.seconds * 1_000_000_000) + Int64(interval.attoseconds / 1_000_000_000)
        let deadline = Date().addingTimeInterval(Double(totalNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            if pictureHasPaintable(picture) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        while g_main_context_iteration(nil, 0) != 0 {}
        return pictureHasPaintable(picture)
    }

    @MainActor
    private func waitForPaintableChange(
        in picture: Picture,
        from initialPaintable: UnsafeMutableRawPointer?,
        timeout: Duration
    ) -> Bool {
        let interval = timeout.components
        let totalNanoseconds = (interval.seconds * 1_000_000_000) + Int64(interval.attoseconds / 1_000_000_000)
        let deadline = Date().addingTimeInterval(Double(totalNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            if picturePaintablePointer(picture) != initialPaintable {
                return true
            }
            g_usleep(1_000)
        }
        while g_main_context_iteration(nil, 0) != 0 {}
        return picturePaintablePointer(picture) != initialPaintable
    }
}

private enum TestFixtureError: Error {
    case invalidBase64
}
