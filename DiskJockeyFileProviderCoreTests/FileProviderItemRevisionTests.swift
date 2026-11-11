import XCTest
import FileProvider
import DiskJockeyLibrary
@testable import DiskJockeyFileProviderCore

/// Item versions must follow the remote revision, not only the name and
/// size (diskjockey#588).
final class FileProviderItemRevisionTests: XCTestCase {

    private func item(name: String = "notes.txt", size: Int64 = 10,
                      isDirectory: Bool = false,
                      modificationTime: Int64? = 1_700_000_000,
                      mode: UInt32? = 0o644) -> FileProviderItem {
        FileProviderItem(
            info: DiskJockeyFileItem(name: name, size: size, isDirectory: isDirectory,
                                     modificationTime: modificationTime, mode: mode),
            parentPath: "/docs")
    }

    func testASameSizeEditWithANewModificationTimeHasANewContentVersion() {
        let old = item(modificationTime: 1_700_000_000)
        let edited = item(modificationTime: 1_700_000_001)
        XCTAssertNotEqual(old.itemVersion.contentVersion, edited.itemVersion.contentVersion)
        XCTAssertNotEqual(old.itemVersion.metadataVersion, edited.itemVersion.metadataVersion)
    }

    func testAModeChangeChangesOnlyTheMetadataVersion() {
        let old = item(mode: 0o644)
        let changed = item(mode: 0o600)
        XCTAssertEqual(old.itemVersion.contentVersion, changed.itemVersion.contentVersion)
        XCTAssertNotEqual(old.itemVersion.metadataVersion, changed.itemVersion.metadataVersion)
    }

    func testASizeChangeChangesBothVersions() {
        let old = item(size: 10)
        let grown = item(size: 11)
        XCTAssertNotEqual(old.itemVersion.contentVersion, grown.itemVersion.contentVersion)
        XCTAssertNotEqual(old.itemVersion.metadataVersion, grown.itemVersion.metadataVersion)
    }

    func testAFileAndADirectoryOfOneRevisionHaveDifferentContentVersions() {
        let file = item(size: 0, isDirectory: false)
        let directory = item(size: 0, isDirectory: true)
        XCTAssertNotEqual(file.itemVersion.contentVersion, directory.itemVersion.contentVersion)
    }

    func testAnUnchangedRevisionKeepsBothVersions() {
        XCTAssertEqual(item().itemVersion.contentVersion, item().itemVersion.contentVersion)
        XCTAssertEqual(item().itemVersion.metadataVersion, item().itemVersion.metadataVersion)
    }

    func testAnUnknownModificationTimeNeverMatchesAKnownOne() {
        let known = item(modificationTime: 0)
        let unknown = item(modificationTime: nil)
        XCTAssertNotEqual(known.itemVersion.contentVersion, unknown.itemVersion.contentVersion)
    }

    func testTheModificationDateComesFromTheRemote() {
        XCTAssertEqual(item(modificationTime: 1_700_000_000).contentModificationDate,
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(item(modificationTime: nil).contentModificationDate)
    }

    // MARK: - fetchContents' item

    private func remote(size: Int64 = 10, isDirectory: Bool = false,
                        modificationTime: Int64? = 1_700_000_000,
                        mode: UInt32? = 0o644) -> DiskJockeyFileItem {
        DiskJockeyFileItem(name: "notes.txt", size: size, isDirectory: isDirectory,
                           modificationTime: modificationTime, mode: mode)
    }

    func testAFetchBetweenAgreeingStatsMatchesTheEnumeratedVersion() {
        let fetched = FileProviderItem(
            info: fetchedFileInfo(name: "notes.txt", downloadedSize: 10,
                                  before: remote(), after: remote()),
            parentPath: "/docs")
        XCTAssertEqual(fetched.itemVersion.contentVersion, item().itemVersion.contentVersion)
        XCTAssertEqual(fetched.itemVersion.metadataVersion, item().itemVersion.metadataVersion)
    }

    func testAFetchWithAnAfterStatOnlyCarriesItsRevision() {
        let info = fetchedFileInfo(name: "notes.txt", downloadedSize: 10,
                                   before: nil, after: remote())
        XCTAssertEqual(info.modificationTime, 1_700_000_000)
        XCTAssertEqual(info.mode, 0o644)
    }

    func testAFetchDuringAnEditCarriesNoRevision() {
        let info = fetchedFileInfo(name: "notes.txt", downloadedSize: 10,
                                   before: remote(modificationTime: 1),
                                   after: remote(modificationTime: 2))
        XCTAssertNil(info.modificationTime)
        XCTAssertEqual(info.size, 10)
    }

    func testAFetchWhoseBytesDisagreeWithTheStatCarriesNoRevision() {
        let info = fetchedFileInfo(name: "notes.txt", downloadedSize: 9,
                                   before: remote(), after: remote())
        XCTAssertNil(info.modificationTime)
        XCTAssertEqual(info.size, 9)
        XCTAssertFalse(info.isDirectory)
    }

    func testAFetchWithNoStatCarriesNoRevision() {
        let info = fetchedFileInfo(name: "notes.txt", downloadedSize: 10,
                                   before: nil, after: nil)
        XCTAssertNil(info.modificationTime)
        XCTAssertNil(info.mode)
        XCTAssertEqual(info.size, 10)
    }

    func testAFetchWhosePathBecameADirectoryCarriesNoRevision() {
        let info = fetchedFileInfo(name: "notes.txt", downloadedSize: 10,
                                   before: remote(), after: remote(isDirectory: true))
        XCTAssertNil(info.modificationTime)
        XCTAssertFalse(info.isDirectory)
    }
}
