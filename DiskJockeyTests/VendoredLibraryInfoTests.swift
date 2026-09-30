//
// VendoredLibraryInfoTests.swift — the About screen's manifest parser,
// against the manifests this repository actually writes.
//
// The two fixtures below are the two blocks scripts/sibling-build.sh emits
// into VERSION-<name>.txt, key for key and in its order, with the shell
// substitutions filled in. If the writer grows or renames a key, these are
// the lines to update — and the parser has to follow.
//

import Foundation
import Testing
@testable import DiskJockey

struct VendoredLibraryInfoTests {

    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    /// sibling-build.sh, building a pinned tag from a throwaway worktree.
    private static let fromWorktree = """
        lib=go-networkfs
        source=git@github.com:christhomas/go-networkfs.git
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
        #expect(info.source == "git@github.com:christhomas/go-networkfs.git")
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

    /// Older manifests carried the date as `built_at`; they still show one.
    @Test func theLegacyBuiltAtKeyStillGivesADate() throws {
        let info = try #require(VendoredLibraryInfo.parse(
            "lib=x\ncommit=\(Self.commit)\nbuilt_at=2026-09-29T10:00:00Z"))
        #expect(info.commitDate == Date(timeIntervalSince1970: 1_790_676_000))
    }
}
