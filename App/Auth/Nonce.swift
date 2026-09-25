import CryptoKit
import Foundation
import Security

/// Which encoding of the SHA-256 digest Apple is given. Supabase's token check has a known
/// hex-versus-base64url ambiguity (https://github.com/supabase/auth/issues/2378), so the app tries
/// hex first and falls back to base64url once, remembering which one worked.
///
/// There is no third option. Dropping the nonce reopens a replay window on the identity token and
/// needs Ash's explicit written sign-off; it is not something this code can decide to do.
enum NonceEncoding: String, CaseIterable {
    case hex
    case base64url

    static let defaultsKey = "animalTracker.nonceEncoding"

    /// The next encoding to try after this one failed, or nil when the fallbacks are exhausted.
    var next: NonceEncoding? {
        switch self {
        case .hex: return .base64url
        case .base64url: return nil
        }
    }

    static func load(defaults: UserDefaults = .standard) -> NonceEncoding {
        guard let raw = defaults.string(forKey: defaultsKey), let value = NonceEncoding(rawValue: raw) else {
            return .hex
        }
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: NonceEncoding.defaultsKey)
    }
}

/// Sign in with Apple nonce handling. Apple is given the SHA-256 digest of the nonce and puts that
/// digest in the identity token; Supabase is given the raw nonce and re-hashes it to check the
/// token. Both halves are pure so they can be tested without an Apple account.
enum Nonce {
    enum Failure: Error, LocalizedError {
        case nonPositiveLength
        case randomUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .nonPositiveLength:
                return "A nonce must be at least one character long."
            case .randomUnavailable(let status):
                return "The system random number generator is unavailable (status \(status))."
            }
        }
    }

    /// Exactly 64 characters, so `UInt8 % 64` is uniform (256 is a multiple of 64) and every
    /// character is URL-safe.
    static let alphabet: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-.")

    /// Throws rather than trapping: a device that cannot produce randomness must fail the sign-in,
    /// not crash the app, and must never fall back to a predictable nonce.
    static func random(length: Int = 32) throws -> String {
        guard length > 0 else { throw Failure.nonPositiveLength }
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else { throw Failure.randomUnavailable(status) }
        var result = ""
        result.reserveCapacity(length)
        for byte in bytes { result.append(alphabet[Int(byte) % alphabet.count]) }
        return result
    }

    static func digest(_ input: String, encoding: NonceEncoding) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        switch encoding {
        case .hex:
            return hashed.map { String(format: "%02x", $0) }.joined()
        case .base64url:
            return Data(hashed).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }
}
