// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskJockey",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskJockeyLibrary", targets: ["DiskJockeyLibrary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.21.0")
    ],
    targets: [
        .target(
            name: "DiskJockeyLibrary",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "DiskJockeyLibrary"
        ),
    ]
)