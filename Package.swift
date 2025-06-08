// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskJockey",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskJockeyHelperLibrary", targets: ["DiskJockeyHelperLibrary"]),
        .executable(name: "DiskJockeyHelper", targets: ["DiskJockeyHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.21.0")
    ],
    targets: [
        .target(
            name: "DiskJockeyHelperLibrary",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "DiskJockeyHelperLibrary"
        ),
        .executableTarget(
            name: "DiskJockeyHelper",
            dependencies: ["DiskJockeyHelperLibrary"],
            path: "DiskJockeyHelper"
        ),
        .testTarget(
            name: "DiskJockeyHelperLibraryTests",
            dependencies: ["DiskJockeyHelperLibrary"],
            path: "DiskJockeyHelperLibraryTests"
        )
    ]
)