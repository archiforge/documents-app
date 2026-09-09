// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NativeArchives",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(name: "NativeArchives", targets: ["NativeArchives"])
    ],
    targets: [
        .binaryTarget(
            name: "NativeArchivesC",
            path: "Artifacts/NativeArchivesC.xcframework"
        ),
        // bootstrap.sh folds liblzma into the static binary and disables
        // libarchive's optional zlib/bzip2/iconv/etc. integrations, so the
        // app does not need additional third-party linker flags.
        .target(
            name: "NativeArchives",
            dependencies: ["NativeArchivesC"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
