import Security
import XCTest
@testable import AnimalTracker

/// The Supabase SDK's own KeychainLocalStorage has no accessibility parameter and writes
/// kSecAttrAccessibleAfterFirstUnlock. This app needs ...ThisDeviceOnly so a restored device
/// backup never carries a live session, which is why the storage is ours.
final class KeychainSessionStorageTests: XCTestCase {
    /// Unique per test run, so these cases can never touch the app's real keychain item and two
    /// runs on the same machine cannot collide with each other.
    private let service = "com.ashlab.AnimalTracker.auth.tests.\(UUID().uuidString)"
    private var storage: KeychainSessionStorage!
    private let key = "session-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        storage = KeychainSessionStorage(service: service)
    }

    override func tearDown() {
        try? storage.remove(key: key)
        // Sweep the whole throwaway service, so a failed assertion cannot leave an item behind.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
        super.tearDown()
    }

    func testStoreRetrieveRemoveRoundTrip() throws {
        XCTAssertNil(try storage.retrieve(key: key))
        try storage.store(key: key, value: Data("first".utf8))
        XCTAssertEqual(try storage.retrieve(key: key), Data("first".utf8))
        try storage.store(key: key, value: Data("second".utf8))
        XCTAssertEqual(try storage.retrieve(key: key), Data("second".utf8), "store replaces, it does not duplicate")
        try storage.remove(key: key)
        XCTAssertNil(try storage.retrieve(key: key))
    }

    func testRemovingSomethingThatIsNotThereIsNotAnError() {
        XCTAssertNoThrow(try storage.remove(key: "absent-\(UUID().uuidString)"))
    }

    func testItemIsAccessibleOnlyAfterFirstUnlockAndOnlyOnThisDevice() throws {
        try storage.store(key: key, value: Data("x".utf8))
        XCTAssertEqual(storage.accessibility(forKey: key), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// Account deletion has to leave nothing behind, and the SDK writes more than one item under
    /// this service: the session under its storage key and a PKCE code verifier under
    /// `<storageKey>-code-verifier`. One service-wide delete cannot drift as the SDK adds keys.
    func testRemoveAllClearsEverySessionItemUnderTheService() throws {
        try storage.store(key: AuthService.sessionStorageKey, value: Data("session".utf8))
        try storage.store(key: AuthService.codeVerifierStorageKey, value: Data("verifier".utf8))

        try storage.removeAll()

        XCTAssertNil(try storage.retrieve(key: AuthService.sessionStorageKey))
        XCTAssertNil(try storage.retrieve(key: AuthService.codeVerifierStorageKey),
                     "the code verifier is an item too, and removing only the session key leaves it")
    }

    func testRemoveAllOnAServiceWithNothingInItIsNotAnError() {
        XCTAssertNoThrow(try storage.removeAll())
    }

    /// One throwaway service is not touched by a sweep of another.
    func testRemoveAllOnlyTouchesItsOwnService() throws {
        let other = KeychainSessionStorage(service: "\(service).neighbour")
        try other.store(key: key, value: Data("keep me".utf8))
        defer { try? other.removeAll() }

        try storage.store(key: key, value: Data("sweep me".utf8))
        try storage.removeAll()

        XCTAssertNil(try storage.retrieve(key: key))
        XCTAssertEqual(try other.retrieve(key: key), Data("keep me".utf8))
    }

    /// Two assertions on purpose. The default init has to resolve to the pinned service, which is
    /// what production depends on, and the string itself has to stay put: renaming it would orphan
    /// the session item on every phone that already has one.
    func testTheServiceIsPinnedToTheApp() {
        XCTAssertEqual(KeychainSessionStorage().service, KeychainSessionStorage.defaultService)
        XCTAssertEqual(KeychainSessionStorage.defaultService, "com.ashlab.AnimalTracker.auth")
    }
}
