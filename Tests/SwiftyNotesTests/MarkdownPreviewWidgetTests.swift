import Adwaita
import Foundation
@testable import SwiftyNotes
import Testing

/// Widget-backed MarkdownPreview tests live in their own suite so the CI step
/// that runs them gets a dedicated process. When they share a process with
/// MainWindow*Tests the teardown of those suites leaves GLib idle callbacks
/// referencing freed GObjects, which crash the next widget test that pumps
/// the main context.
struct MarkdownPreviewWidgetTests {
    @Test @MainActor
    func `preview loads remote image when loader provides local file after asynchronous completion`() async throws {
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

    @Test @MainActor
    func `preview loads remote linked image group when loader provides local file after asynchronous completion`() async throws {
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

    @Test @MainActor
    func `preview renders linked badge groups without fixed width padding`() throws {
        let app = Application(id: "me.spaceinbox.swiftynotes.tests.remote-preview-badge-layout")
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

        guard let button = firstButton(in: preview.container),
              let child = buttonChild(button)
        else {
            Issue.record("Expected linked badge button content")
            return
        }

        let size = child.sizeRequest
        let buttonNaturalHeight = measuredNaturalSize(of: button, orientation: .vertical)

        #expect(child.isInstance(of: Picture.self))
        #expect(size.width == -1)
        #expect(size.height == 18)
        #expect(buttonNaturalHeight <= 22)
    }

    @Test @MainActor
    func `preview scales linked badge SVG to preferred height`() throws {
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

        guard let button = firstButton(in: preview.container),
              let child = buttonChild(button)
        else {
            Issue.record("Expected linked badge button content")
            return
        }

        let size = child.sizeRequest

        #expect(size.width == 108)
        #expect(size.height == 18)
    }

    @Test @MainActor
    func `preview measures badge group at constrained height without warnings`() throws {
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

    @Test @MainActor
    func `preview table horizontal minimum fits inside narrow preview`() throws {
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

    @Test @MainActor
    func `preview list item horizontal minimum fits inside narrow preview`() throws {
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

    @Test @MainActor
    func `preview code block horizontal minimum fits inside narrow preview`() throws {
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

    @Test @MainActor
    func `preview renders standalone image in responsive card with caption`() throws {
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
        #expect(labelTexts(in: child).contains("Hero artwork"))
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

    @Test @MainActor
    func `preview renders remote web P image after asynchronous completion`() async throws {
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

    @Test @MainActor
    func `presented preview allocates remote web P image after asynchronous completion`() async throws {
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

    @Test @MainActor
    func `preview renders remote GIF image after asynchronous completion`() async throws {
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

    @Test @MainActor
    func `presented preview allocates remote GIF image after asynchronous completion`() throws {
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

    @Test @MainActor
    func `presented preview allocates standalone remote images after badge rows`() throws {
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
    func `preview auto plays remote GIF image after asynchronous completion`() throws {
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

    @Test @MainActor
    func `animated GIF player advances frames`() async throws {
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
