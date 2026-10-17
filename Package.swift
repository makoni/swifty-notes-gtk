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

// The RaTeX math engine is Rust, built outside SwiftPM by
// scripts/build-ratex-bridge.sh into build/ratex-bridge/ — run that script
// before the first `swift build` (and after changing Sources/RaTeXBridge).
// Without it the link fails with "cannot find -lratex_bridge".
//
// The system libraries the static library needs are listed here rather
// than read from the build: SwiftPM caches this manifest by its contents,
// so anything it read from build/ would go stale. The build script reads
// these lists back and fails if cargo asks for anything else.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
#if os(macOS)
let mathBridgeSystemLibraries = [
    "-lgio-2.0", "-lgobject-2.0", "-lglib-2.0", "-lintl", "-lcairo-gobject", "-lcairo", "-lfontconfig",
    "-liconv", "-framework", "CoreFoundation",
]
#else
let mathBridgeSystemLibraries = [
    "-lgio-2.0", "-lgobject-2.0", "-lglib-2.0", "-lcairo-gobject", "-lcairo", "-lfontconfig",
    "-lgcc_s", "-lutil", "-lrt", "-lpthread", "-lm", "-ldl",
]
#endif
let mathBridgeLinkerFlags = ["-L\(packageDirectory)/build/ratex-bridge/lib", "-lratex_bridge"]
    + mathBridgeSystemLibraries

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
            // Pinned to the 2.0.2 tag. What this app needs from the library
            // arrived in 1.6.0 and is still the floor:
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
            // 2.0.0 is source-breaking only for six value-returning signal
            // handlers (TabOverview.onCreateTab, TabView.onCreateWindow,
            // TabView.onClosePage, NavigationView.onGetNextPage,
            // SpinRow.onInput, SpinRow.onOutput), none of which this app
            // connects. What changes here is lifetime: a widget's Swift
            // wrapper now lives as long as the GTK widget, so a handler can
            // capture the widget it is connected to with `[weak x]`, and a
            // strong capture of it keeps the whole subtree alive. 2.0.0 also
            // raises the toolchain floor to Swift 6.3: Xcode 26 and the
            // Flatpak SDK extension ship 6.3, while the snap and the Linux CI
            // jobs build with the version in .swift-version (6.4).
            // 2.0.2 stops Window()/ApplicationWindow(application:) stealing
            // GTK's toplevel reference: on 2.0.0 a released window was freed
            // while GTK still listed it, and the next text-direction walk
            // (LanguageSwitchingTests after MainWindowActionsTests) crashed.
            // Still pinned by revision rather than by version: the Flatpak
            // manifest needs a commit for its git source either way, and a
            // bump should follow validating a newer upstream rather than
            // SemVer auto-resolution.
            revision: "c6b8a4ca5d89a47239b955c0174bf1849fb999ad"
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
        .systemLibrary(name: "CRaTeXBridge", path: "Sources/RaTeXBridge"),
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
                "CRaTeXBridge",
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
            ],
            linkerSettings: [.unsafeFlags(mathBridgeLinkerFlags)]
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
