//
// PKCETests.swift — the app's PKCE helper against RFC 7636 itself.
//
// The expected challenge below is copied from RFC 7636 Appendix B, not
// computed here: an S256 challenge recomputed with the same SHA-256 and the
// same base64url code would agree with any bug they share.
//

import Foundation
import Testing
@testable import DiskJockey

struct PKCETests {

    /// The unreserved set of RFC 3986 §2.3, which RFC 7636 §4.1 limits a
    /// verifier to.
    private static let unreserved = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// base64url without padding, RFC 4648 §5.
    private static let base64URL = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    @Test func theChallengeForRFC7636AppendixBsVerifierIsTheRFCsChallenge() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func aFreshPairsChallengeIsTheS256OfItsOwnVerifier() {
        let pkce = PKCE()
        #expect(pkce.codeChallenge == PKCE.challenge(for: pkce.codeVerifier))
    }

    /// RFC 7636 §4.1: "a minimum length of 43 characters and a maximum
    /// length of 128 characters".
    @Test func aFreshVerifierIsWithinTheRFCsLengthBounds() {
        let length = PKCE().codeVerifier.count
        #expect((43...128).contains(length))
    }

    @Test func aFreshVerifierUsesOnlyUnreservedCharacters() {
        #expect(PKCE().codeVerifier.allSatisfy { Self.unreserved.contains($0) })
    }

    /// A SHA-256 digest is 32 bytes, which is 43 base64url characters once
    /// the padding is dropped.
    @Test func aChallengeIsUnpaddedBase64URLOfOneDigest() {
        let challenge = PKCE().codeChallenge
        #expect(challenge.count == 43)
        #expect(challenge.allSatisfy { Self.base64URL.contains($0) })
    }

    @Test func twoFreshVerifiersAreNotTheSame() {
        #expect(PKCE().codeVerifier != PKCE().codeVerifier)
    }
}
