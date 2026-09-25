import XCTest
@testable import AnimalTracker

final class NonceTests: XCTestCase {
    func testAlphabetIsExactlySixtyFourCharactersSoTheModuloIsUniform() {
        XCTAssertEqual(Nonce.alphabet.count, 64)
        XCTAssertEqual(Set(Nonce.alphabet).count, 64)
    }

    func testRandomHasTheRequestedLengthAndOnlyAlphabetCharacters() throws {
        let value = try Nonce.random(length: 32)
        XCTAssertEqual(value.count, 32)
        XCTAssertTrue(value.allSatisfy { Nonce.alphabet.contains($0) })
    }

    func testRandomDefaultsToThirtyTwo() throws {
        XCTAssertEqual(try Nonce.random().count, 32)
    }

    func testRandomDoesNotRepeat() throws {
        let values = try (0..<50).map { _ in try Nonce.random() }
        XCTAssertEqual(Set(values).count, 50)
    }

    /// A bad length throws instead of trapping, so a caller can fail the sign-in closed
    /// rather than killing the app.
    func testRandomThrowsOnANonPositiveLength() {
        XCTAssertThrowsError(try Nonce.random(length: 0)) { error in
            guard case Nonce.Failure.nonPositiveLength = error else {
                return XCTFail("expected nonPositiveLength, got \(error)")
            }
        }
        XCTAssertThrowsError(try Nonce.random(length: -1))
    }

    /// Known SHA-256 vectors, so a change of encoding is caught. Hex is what Apple's sample code
    /// and the Supabase guide both use, and is what this app sends first.
    func testHexDigestMatchesKnownVectors() {
        XCTAssertEqual(Nonce.digest("abc", encoding: .hex),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Nonce.digest("", encoding: .hex),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// The fallback encoding, used only after Supabase answers "Nonces mismatch". Same digest
    /// bytes, base64url with no padding.
    func testBase64UrlDigestMatchesTheSameVector() {
        XCTAssertEqual(Nonce.digest("abc", encoding: .base64url),
                       "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
    }

    func testBase64UrlIsUnpaddedAndUrlSafe() throws {
        let digest = Nonce.digest(try Nonce.random(), encoding: .base64url)
        XCTAssertFalse(digest.contains("="))
        XCTAssertFalse(digest.contains("+"))
        XCTAssertFalse(digest.contains("/"))
    }

    func testHexIsLowercaseAndSixtyFourCharacters() throws {
        let digest = Nonce.digest(try Nonce.random(), encoding: .hex)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// The fallback order is fixed: hex first, then base64url, then nothing. There is no
    /// third step that drops the nonce.
    func testEncodingFallbackOrderStopsAfterBase64Url() {
        XCTAssertEqual(NonceEncoding.hex.next, .base64url)
        XCTAssertNil(NonceEncoding.base64url.next)
    }

    func testEncodingRoundTripsThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NonceTests-\(UUID().uuidString)"))
        XCTAssertEqual(NonceEncoding.load(defaults: defaults), .hex, "hex is the default")
        NonceEncoding.base64url.save(defaults: defaults)
        XCTAssertEqual(NonceEncoding.load(defaults: defaults), .base64url)
    }
}
