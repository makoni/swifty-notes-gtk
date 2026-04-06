// swift-tools-version: 6.0

import PackageDescription

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
        .package(path: "../swift-adwaita"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftyNotes",
            dependencies: [
                .product(name: "Adwaita", package: "swift-adwaita"),
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "SwiftyNotesTests",
            dependencies: ["SwiftyNotes"]
        )
    ]
)
