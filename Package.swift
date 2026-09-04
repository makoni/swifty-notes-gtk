// swift-tools-version: 6.0

import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment
let useBundledSwiftPMDependencies = environment["SWIFTY_NOTES_USE_BUNDLED_SWIFTPM_DEPS"] == "1"
let localSwiftAdwaitaPath = environment["SWIFTY_NOTES_LOCAL_SWIFT_ADWAITA_PATH"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)

func packagePathExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

func sourceDependency(
    bundledPath: String,
    overridePath: String? = nil,
    remoteURL: String,
    revision: String
) -> Package.Dependency {
    if useBundledSwiftPMDependencies, packagePathExists(bundledPath) {
        return .package(path: bundledPath)
    }
    if let overridePath, !overridePath.isEmpty, packagePathExists(overridePath) {
        return .package(path: overridePath)
    }
    return .package(url: remoteURL, revision: revision)
}

func sourceDependency(
    bundledPath: String,
    overridePath: String? = nil,
    remoteURL: String,
    minimumVersion: Version
) -> Package.Dependency {
    if useBundledSwiftPMDependencies, packagePathExists(bundledPath) {
        return .package(path: bundledPath)
    }
    if let overridePath, !overridePath.isEmpty, packagePathExists(overridePath) {
        return .package(path: overridePath)
    }
    return .package(url: remoteURL, from: minimumVersion)
}

let package = Package(
    name: "swifty-notes-gtk",
    platforms: [
        // Honest deployment target. The macOS .app links Homebrew GTK4 /
        // glib / libadwaita / gtksourceview / pango / harfbuzz / gdk-pixbuf /
        // graphene / intl bottles compiled with LC_BUILD_VERSION = macOS 26.0
        // (cairo at 15.0). Declaring anything lower than 26.0 here makes the
        // linker emit a per-dylib warning on every `swift build` ("building
        // for macOS-13.0, but linking with dylib ... which was built for
        // newer version 26.0") and ships a binary whose declared min-os
        // lies about portability — the dylib chain still requires macOS 26.0
        // at load time. Bump in lockstep with brew bottles if those get
        // rebuilt for a different floor. Linux ignores this clause.
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "SwiftyNotes",
            targets: ["SwiftyNotes"]
        ),
        .executable(
            name: "swiftynotes",
            targets: ["SwiftyNotesApp"]
        )
    ],
    dependencies: [
        sourceDependency(
            bundledPath: "flatpak-deps/swift-adwaita",
            overridePath: localSwiftAdwaitaPath,
            remoteURL: "https://github.com/makoni/swift-adwaita.git",
            // Pinned past the 1.5.0 release for what this app needs from it:
            //   * Window.isActive — routes app-level accelerators to the
            //     focused external document window.
            //   * The localization API — gettext setup, runtime language
            //     switching and reading direction, which replaced a
            //     hand-written C shim here.
            //   * Widget.accessibleLabel — reads back a label GTK only lets
            //     you write, which is what lets MainWindowDebug's chrome
            //     snapshot guard the accessible labels. Dropping below this
            //     breaks that guard, not just localization plumbing.
            //   * catalogueLanguages(in:domain:) and
            //     currentMessagesLocale()/setMessagesLocale(_:) — catalogue
            //     discovery and the process locale, both of which used to be
            //     local copies.
            // Bump deliberately when validating a newer upstream rather than
            // via SemVer auto-resolution.
            revision: "007a30230ccebb1ad46bd430fbe95b9c0d4d5ad4"
        ),
        sourceDependency(
            bundledPath: "flatpak-deps/swift-markdown",
            remoteURL: "https://github.com/swiftlang/swift-markdown.git",
            revision: "55d66d9a9e8d4fd3f48d111b0d437e82fe451903"
        ),
        sourceDependency(
            bundledPath: "flatpak-deps/swift-cmark",
            remoteURL: "https://github.com/swiftlang/swift-cmark.git",
            minimumVersion: Version(0, 7, 0)
        )
    ],
    targets: [
        .systemLibrary(
            name: "CSpelling",
            pkgConfig: "libspelling-1",
            providers: [
                .apt(["libspelling-1-dev"])
            ]
        ),
        .target(
            name: "SwiftyNotes",
            dependencies: [
                .product(name: "Adwaita", package: "swift-adwaita"),
                .product(name: "Markdown", package: "swift-markdown"),
                "CSpelling",
            ],
            resources: [
                // The `locale/` directory is inside the target so SwiftPM
                // preserves the `ru/LC_MESSAGES/domain.mo` layout gettext
                // expects.  `.process` would flatten it to just
                // `domain.mo` and `ngettext()` would never find the right
                // language subdir.
                .copy("locale"),
                // Other Resources files (emoji table, license, demo image)
                // These don't need subdirectory structure so .process is fine.
                .process("Resources"),
                .copy("Icons"),
                // AppIcons/hicolor/scalable/apps/me.spaceinbox.swiftynotes.svg
                // is registered as a GTK icon-theme search root at
                // first window construction so AdwAboutDialog can
                // resolve `applicationIcon`. Must be `.copy` (not
                // `.process`) — `.process` flattens nested directories
                // and GTK's icon-theme lookup expects the standard
                // `<theme>/<size>/<context>/<name>.<ext>` layout.
                .copy("AppIcons")
            ]
        ),
        .executableTarget(
            // Target name (and `path:`) must not case-collide with the
            // SwiftyNotes library target on case-insensitive filesystems
            // (default APFS); SwiftPM normalises target names and would
            // otherwise merge the two. The user-visible binary product
            // name `swiftynotes` is unchanged — see `.executable(...)`
            // in `products` above.
            name: "SwiftyNotesApp",
            dependencies: ["SwiftyNotes"],
            path: "Sources/SwiftyNotesApp"
        ),
        .testTarget(
            name: "SwiftyNotesTests",
            dependencies: ["SwiftyNotes"]
        ),
        .testTarget(
            name: "SwiftyNotesWidgetTests",
            dependencies: ["SwiftyNotes"],
            path: "Tests/SwiftyNotesWidgetTests"
        )
    ]
)
