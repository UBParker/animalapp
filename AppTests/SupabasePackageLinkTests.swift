import Supabase
import XCTest
@testable import AnimalTracker

final class SupabasePackageLinkTests: XCTestCase {
    func testSupabaseClientIsLinkedAndInitializesWithoutNetwork() {
        let client = SupabaseClient(supabaseURL: URL(string: "https://example.supabase.co")!,
                                    supabaseKey: "anon-key-not-real")
        XCTAssertNotNil(client.auth)
    }
}
