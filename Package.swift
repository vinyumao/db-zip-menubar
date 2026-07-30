// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DbZipMenubar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DbZipCore", targets: ["DbZipCore"])
    ],
    targets: [
        .target(
            name: "DbZipCore",
            path: "Sources/DbZipCore"
        ),
        .testTarget(
            name: "DbZipCoreTests",
            dependencies: ["DbZipCore"],
            path: "Tests/DbZipCoreTests"
        )
    ]
)
