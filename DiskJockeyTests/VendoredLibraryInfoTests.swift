//
// VendoredLibraryInfoTests.swift — the About screen's manifest parser,
// against the manifests this repository actually writes.
//
// The two fixtures below are the two blocks scripts/sibling-build.sh emits
// into VERSION-<name>.txt, key for key and in its order, with the shell
// substitutions filled in. If the writer grows or renames a key, these are
// the lines to update — and the parser has to follow.
//

import DiskJockeyLibrary
import Foundation
import Testing
@testable import DiskJockey

struct VendoredLibraryInfoTests {

    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    /// sibling-build.sh, building a pinned tag from a throwaway worktree.
    private static let fromWorktree = """
        lib=go-networkfs
        source=git@github.com:antimatter-studios/go-networkfs.git
        ref=v0.4.2
        ref_type=tag
        commit=\(commit)
        short_commit=0123456
        built_from=worktree
        dirty=false
        """

    /// sibling-build.sh, building a clean `main` checkout.
    private static let fromCheckout = """
        lib=go-networkfs
        source=unknown
        ref=main
        ref_type=branch
        commit=\(commit)
        short_commit=0123456
        built_from=checkout
        dirty=false
        """

    @Test func theWorktreeManifestNamesTheTagItWasBuiltFrom() throws {
        let info = try #require(VendoredLibraryInfo.parse(Self.fromWorktree))
        #expect(info.name == "go-networkfs")
        #expect(info.id == "go-networkfs")
        #expect(info.source == "git@github.com:antimatter-studios/go-networkfs.git")
        #expect(info.ref == "v0.4.2")
        #expect(info.refType == .tag)
        #expect(info.commit == Self.commit)
        #expect(info.shortCommit == "0123456")
        #expect(!info.isDirty)
    }

    @Test func theCheckoutManifestIsABranch() throws {
        let info = try #require(VendoredLibraryInfo.parse(Self.fromCheckout))
        #expect(info.ref == "main")
        #expect(info.refType == .branch)
    }

    /// Neither writer emits `describe` or a date, so the screen shows the
    /// short commit and no date rather than an empty label or the epoch.
    @Test func withoutDescribeOrADateTheShortCommitStandsIn() throws {
        let info = try #require(VendoredLibraryInfo.parse(Self.fromWorktree))
        #expect(info.describe == "0123456")
        #expect(info.commitDate == nil)
    }

    @Test func aManifestWithoutACommitIsRefused() {
        let text = Self.fromWorktree.split(separator: "\n")
            .filter { !$0.hasPrefix("commit=") }.joined(separator: "\n")
        #expect(VendoredLibraryInfo.parse(text) == nil)
    }

    @Test func aManifestWithoutALibraryNameIsRefused() {
        let text = Self.fromWorktree.split(separator: "\n")
            .filter { !$0.hasPrefix("lib=") }.joined(separator: "\n")
        #expect(VendoredLibraryInfo.parse(text) == nil)
    }

    @Test func withoutAShortCommitTheFirstSevenCharactersAreUsed() throws {
        let info = try #require(VendoredLibraryInfo.parse("lib=x\ncommit=\(Self.commit)"))
        #expect(info.shortCommit == "0123456")
        #expect(info.refType == .unknown)
    }

    @Test func commentsBlankLinesAndCRLFAreIgnored() throws {
        let text = "# written by hand\r\n\r\nlib=x\r\ncommit=\(Self.commit)\r\ndirty=true\r\n"
        let info = try #require(VendoredLibraryInfo.parse(text))
        #expect(info.commit == Self.commit)
        #expect(info.isDirty)
    }

    /// scripts/build-bundles.sh, for the ext4 bundle: a header, then each
    /// resolved crate as `name version` (diskjockey#347). The build copies
    /// it into vendor-versions/ as `bundle_ext4-VERSION.txt`, and the name
    /// is only in that file name.
    private static let ext4Bundle = """
        bundle resolved crates (crates.io unless dev-linked):
          rust-fs-core 0.3.11
          rust-fs-ext4 0.9.0
          rust-img-qcow2 0.5.0
        """

    @Test func aBundleManifestNamesTheBundleAndEveryCrateItResolved() throws {
        let info = try #require(VendoredLibraryInfo.parse(
            Self.ext4Bundle, fileName: "bundle_ext4-VERSION.txt"))
        #expect(info.name == "dj-ext4-bundle")
        #expect(info.crates.map(\.name) == ["rust-fs-core", "rust-fs-ext4", "rust-img-qcow2"])
        #expect(info.crates.map(\.version) == ["0.3.11", "0.9.0", "0.5.0"])
        // The version shown for the bundle is its driver's.
        #expect(info.describe == "0.9.0")
    }

    /// Every filesystem the app ships has a bundle, and each one's manifest
    /// reaches the About page under its own name.
    @Test func everyShippedFilesystemsBundleManifestIsRead() throws {
        for key in ShippedFilesystems.keys {
            let text = """
                bundle resolved crates (crates.io unless dev-linked):
                  rust-fs-core 0.3.11
                  rust-fs-\(key) 1.2.3
                """
            let info = try #require(
                VendoredLibraryInfo.parse(text, fileName: "bundle_\(key)-VERSION.txt"),
                "the \(key) bundle's manifest")
            #expect(info.name == "dj-\(key)-bundle")
            #expect(info.describe == "1.2.3")
        }
    }

    /// go-networkfs's key=value manifest reads the same with its file name.
    @Test func aSiblingManifestReadsTheSameWithItsFileName() throws {
        let info = try #require(VendoredLibraryInfo.parse(
            Self.fromWorktree, fileName: "go-networkfs-VERSION-go-networkfs.txt"))
        #expect(info.name == "go-networkfs")
        #expect(info.crates.isEmpty)
    }

    /// A bundle manifest with no crates under its header is not one.
    @Test func aBundleHeaderWithNoCratesIsRefused() {
        #expect(VendoredLibraryInfo.parse(
            "bundle resolved crates (crates.io unless dev-linked):\n",
            fileName: "bundle_ext4-VERSION.txt") == nil)
    }

    /// Older manifests carried the date as `built_at`; they still show one.
    @Test func theLegacyBuiltAtKeyStillGivesADate() throws {
        let info = try #require(VendoredLibraryInfo.parse(
            "lib=x\ncommit=\(Self.commit)\nbuilt_at=2026-09-29T10:00:00Z"))
        #expect(info.commitDate == Date(timeIntervalSince1970: 1_790_676_000))
    }
}
