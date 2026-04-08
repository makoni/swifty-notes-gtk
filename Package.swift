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

let package = Package(
    name: "swifty-notes-gtk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SwiftyNotes",
            targets: ["SwiftyNotes"]
        )
    ],
    dependencies: [
        sourceDependency(
            bundledPath: "flatpak-deps/swift-adwaita",
            overridePath: localSwiftAdwaitaPath,
            remoteURL: "https://github.com/makoni/swift-adwaita.git",
            revision: "abf7a8cf43e74a13aa8230f7ae4e9d8a029b974f"
        ),
        sourceDependency(
            bundledPath: "flatpak-deps/swift-markdown",
            remoteURL: "https://github.com/swiftlang/swift-markdown.git",
            revision: "7d9a5ce307528578dfa777d505496bd5f544ad94"
        ),
        sourceDependency(
            bundledPath: "flatpak-deps/swift-cmark",
            remoteURL: "https://github.com/swiftlang/swift-cmark.git",
            revision: "5d9bdaa4228b381639fff09403e39a04926e2dbe"
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftyNotes",
            dependencies: [
                .product(name: "Adwaita", package: "swift-adwaita"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SwiftyNotesTests",
            dependencies: ["SwiftyNotes"]
        )
    ]
)
