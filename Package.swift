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
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftyNotes",
            targets: ["SwiftyNotes"]
        ),
        .executable(
            name: "swiftynotes",
            targets: ["swiftynotes"]
        )
    ],
    dependencies: [
        sourceDependency(
            bundledPath: "flatpak-deps/swift-adwaita",
            overridePath: localSwiftAdwaitaPath,
            remoteURL: "https://github.com/makoni/swift-adwaita.git",
            revision: "24db12e"
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
        .target(
            name: "SwiftyNotes",
            dependencies: [
                .product(name: "Adwaita", package: "swift-adwaita"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "swiftynotes",
            dependencies: ["SwiftyNotes"],
            path: "Sources/swiftynotes"
        ),
        .testTarget(
            name: "SwiftyNotesTests",
            dependencies: ["SwiftyNotes"]
        )
    ]
)
