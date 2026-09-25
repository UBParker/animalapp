import XCTest
@testable import AnimalTracker

/// The fixture key is deliberately not JWT-shaped. A real anon key is a JWT, but a literal
/// JWT-shaped string in a test file is also a literal JWT-shaped string in the plan documents that
/// quote this file, and `scripts/check-secrets.sh` scans `docs/`. `make` only cares that the value
/// is non-empty and is not the placeholder, so the shape of the fixture proves nothing either way.
private let usableKey = "test-anon-key.not-a-real-jwt.fixture"

final class SupabaseConfigTests: XCTestCase {
    func testMakeAcceptsARealLookingKey() {
        let config = SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: usableKey)
        XCTAssertEqual(config?.url.absoluteString, "https://ojzmtyapkaxxliuurssc.supabase.co")
        XCTAssertEqual(config?.anonKey, usableKey)
    }

    func testMakeRejectsThePlaceholderKey() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: "REPLACE_WITH_ANON_KEY"))
    }

    func testMakeRejectsThePlaceholderKeyWithSurroundingWhitespace() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: "  REPLACE_WITH_ANON_KEY\n"))
    }

    func testMakeRejectsEmptyOrMissingValues() {
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: ""))
        XCTAssertNil(SupabaseConfig.make(url: "https://ojzmtyapkaxxliuurssc.supabase.co", anonKey: nil))
        XCTAssertNil(SupabaseConfig.make(url: "", anonKey: usableKey))
        XCTAssertNil(SupabaseConfig.make(url: nil, anonKey: usableKey))
    }

    func testMakeRejectsAUrlThatIsNotHttps() {
        XCTAssertNil(SupabaseConfig.make(url: "not a url", anonKey: usableKey))
        XCTAssertNil(SupabaseConfig.make(url: "http://ojzmtyapkaxxliuurssc.supabase.co",
                                         anonKey: usableKey))
    }

    /// The shipped plist names the project. The anon key is still the placeholder on this branch:
    /// the real key was not available when this task ran, so the tripwire is what is committed.
    /// When the real key lands, this assertion flips to `XCTAssertNotEqual` and
    /// `testLoadFromTheAppBundleIsNilWhileThePlaceholderIsCommitted` flips to `XCTAssertNotNil`.
    func testBundledPlistCarriesTheProjectUrlAndThePlaceholderKey() throws {
        let bundle = SupabaseConfig.appBundle
        let path = try XCTUnwrap(bundle.path(forResource: "Supabase", ofType: "plist"),
                                 "App/Config/Supabase.plist is not in the app bundle")
        let dict = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: Any])
        XCTAssertEqual(dict["SupabaseURL"] as? String, "https://ojzmtyapkaxxliuurssc.supabase.co")
        let key = try XCTUnwrap(dict["SupabaseAnonKey"] as? String)
        XCTAssertEqual(key, SupabaseConfig.placeholderKey,
                       "no real anon key is committed yet; see Task 1 Step 4")
    }

    /// The tripwire end to end: the committed plist holds the placeholder, so the app bundle does
    /// not yield a config. DEBUG turns this into offline mode; Release never gets here, because the
    /// `postCompileScripts` guard in `project.yml` fails the build first.
    func testLoadFromTheAppBundleIsNilWhileThePlaceholderIsCommitted() {
        XCTAssertNil(SupabaseConfig.load())
    }

    /// The whole point of `load()`: a bundle with a usable key produces a config. Proven against a
    /// bundle built in a temporary directory, so it holds even while the committed plist carries
    /// the placeholder.
    func testLoadFromABundleWithAUsableKeySucceeds() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SupabaseConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plist: [String: Any] = ["SupabaseURL": "https://ojzmtyapkaxxliuurssc.supabase.co",
                                    "SupabaseAnonKey": usableKey]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Supabase.plist"), options: .atomic)

        let bundle = try XCTUnwrap(Bundle(url: dir))
        let config = try XCTUnwrap(SupabaseConfig.load(bundle: bundle))
        XCTAssertEqual(config.url.absoluteString, "https://ojzmtyapkaxxliuurssc.supabase.co")
        XCTAssertEqual(config.anonKey, usableKey)
    }
}
