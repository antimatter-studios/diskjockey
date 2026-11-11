import XCTest
import FileProvider
import DiskJockeyLibrary
@testable import DiskJockeyFileProviderCore

/// fileproviderd decides whether a cached item is stale by comparing
/// item versions. Two items that describe different remote states must
/// therefore carry different versions (diskjockey#588).
final class FileProviderItemVersionTests: XCTestCase {

    func testAFileAndADirectoryOfTheSameNameAndSizeHaveDifferentMetadataVersions() {
        let file = FileProviderItem(
            info: DiskJockeyFileItem(name: "entry", size: 0, isDirectory: false),
            parentPath: "/")
        let directory = FileProviderItem(
            info: DiskJockeyFileItem(name: "entry", size: 0, isDirectory: true),
            parentPath: "/")

        XCTAssertNotEqual(
            file.itemVersion.metadataVersion,
            directory.itemVersion.metadataVersion,
            "a path that changed from a file to a directory keeps the same metadata version, so fileproviderd keeps the stale record")
    }
}
