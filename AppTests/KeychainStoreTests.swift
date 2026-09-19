import XCTest
@testable import AnimalTracker

final class KeychainStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = KeychainStore(service: "AnimalTracker.tests")
        let account = "k-\(UUID().uuidString)"
        XCTAssertNil(store.get(account))
        try store.set("first", account: account)
        XCTAssertEqual(store.get(account), "first")
        try store.set("second", account: account)
        XCTAssertEqual(store.get(account), "second")
        store.delete(account)
        XCTAssertNil(store.get(account))
    }

    func testApiKeyAccountName() {
        XCTAssertEqual(KeychainStore.apiKeyAccount, "anthropic-api-key")
        XCTAssertEqual(KeychainStore().service, "AnimalTracker")
    }
}
