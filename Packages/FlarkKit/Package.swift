// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlarkKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "FlarkKit", targets: ["FlarkKit"])
    ],
    targets: [
        .target(
            name: "FlarkKit",
            path: "Sources/FlarkKit"
        ),
        .testTarget(
            name: "FlarkKitTests",
            dependencies: ["FlarkKit"],
            path: "Tests/FlarkKitTests"
        )
    ]
)
