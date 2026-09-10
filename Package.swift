// swift-tools-version: 6.0
//
// A WAY TO RUN THE LIBRARY SUITE WITHOUT LAUNCHING ANYTHING.
//
// This package exists for one reason: `xcodebuild test` cannot run a test
// bundle without launching a process to host it. With TEST_HOST set that host
// is DiskJockey.app; without it Xcode substitutes its own `xctest` runner. It
// is a launch either way, it goes through RunningBoard either way, and on
// 2026-09-10 both of them were refused on the CI runner:
//
//     IDELaunchReport: Finished with error: Could not launch "DiskJockeyTests"
//     IDELaunchReport: Finished with error: Could not launch "DiskJockeyLibraryTests"
//     Runningboard has returned error 5
//       (Underlying Error: Launch failed.
//         (Underlying Error: Launchd job spawn failed))
//
// Note the second line. DiskJockeyLibraryTests has no app, no UI and no
// extensions, and it failed to launch too — so a library-only *scheme* does
// not avoid the problem, because the launch is xcodebuild's, not the app's.
// See diskjockey#139.
//
// `swift test` links the test code into a binary and runs it. No launch
// service, no launchd job, nothing to sign. Measured locally: 90 cases in
// 0.4 seconds of testing, 11 seconds cold from an empty build directory.
//
// This is NOT a replacement for the Xcode project. The app, the FSKit
// extensions and the app-hosted DiskJockeyTests target are all still built
// and tested by `xcodebuild` in the `Build & Test` job. This package covers
// exactly the code that does not need a host, and its value is that it keeps
// working when the launch does not.
//
// The two settings below are not choices, they are a mirror of the Xcode
// project, and they must move together with it:
//   platforms  — MACOSX_DEPLOYMENT_TARGET = 15.5 in project.pbxproj. FSItem
//                and FSStatFSResult are macOS 15.4+, so a lower floor here
//                fails to compile sources that compile fine in Xcode.
//   language   — SWIFT_VERSION = 5.0. swift-tools-version 6.0 would otherwise
//                default to Swift 6 language mode and reject library code
//                that the project accepts (FileIDCache's non-Sendable Item).
import PackageDescription

let package = Package(
    name: "DiskJockeyLibraryOnly",
    platforms: [.macOS("15.5")],
    targets: [
        .target(
            name: "DiskJockeyLibrary",
            path: "DiskJockeyLibrary",
            exclude: ["DiskJockeyLibrary.docc"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiskJockeyLibraryTests",
            dependencies: ["DiskJockeyLibrary"],
            path: "DiskJockeyLibraryTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // THE EXT4 VOLUME LOGIC, WITHOUT THE EXTENSION AROUND IT.
        //
        // `sources:` is a deliberate SUBSET of DiskJockeyEXT4/, not an
        // oversight. The rest of that directory — EXT4Backend, EXT4Load,
        // EXT4Maintenance — makes 61 calls into the fs_ext4 C ABI, so it
        // needs the Rust static library and its bridging header, which is
        // exactly what this target exists to avoid. What is listed here is
        // pure Swift over pure Swift types, and it holds the logic the app
        // -hosted suite could only reach through hand-written mirrors:
        // the FSKit attribute-mask conversion and the item cache's
        // path/parent validation.
        //
        // The Xcode target still compiles the whole directory (it is a
        // file-system-synchronised group), so this is a second view of the
        // same files, never a copy of them.
        .target(
            name: "DiskJockeyEXT4Core",
            dependencies: ["DiskJockeyLibrary"],
            path: "DiskJockeyEXT4",
            // Named rather than globbed so adding a file to the directory is
            // a decision here too — and so the warning about "unhandled
            // files" does not become background noise that hides a real one.
            exclude: [
                "EXT4Backend.swift",
                "EXT4FileSystem.swift",
                "EXT4Load.swift",
                "EXT4Maintenance.swift",
                "EXT4Probe.swift",
                "RepairXPCService.swift",
                "DiskJockeyEXT4-Bridging-Header.h",
                "DiskJockeyEXT4.entitlements",
                "Info.plist",
            ],
            sources: [
                "EXT4Volume.swift",
                "FileSystemBackend.swift",
                "EXT4Watchdog.swift",
                "EXT4Log.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DiskJockeyEXT4CoreTests",
            dependencies: ["DiskJockeyEXT4Core", "DiskJockeyLibrary"],
            path: "DiskJockeyEXT4CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
