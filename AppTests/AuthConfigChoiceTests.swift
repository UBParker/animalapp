import XCTest
@testable import AnimalTracker

final class AuthConfigChoiceTests: XCTestCase {
    private let realConfig = SupabaseConfig(url: URL(string: "https://example.supabase.co")!,
                                            anonKey: "a-real-looking-key")

    func testLocalOnlyGivesNoConfigEvenWhenOneLoads() {
        let config = realConfig
        XCTAssertNil(AnimalTrackerApp.authConfig(localOnly: true, load: { config }))
    }

    func testNotLocalOnlyPassesTheLoadedConfigThrough() {
        let config = realConfig
        XCTAssertEqual(AnimalTrackerApp.authConfig(localOnly: false, load: { config }), config)
        XCTAssertNil(AnimalTrackerApp.authConfig(localOnly: false, load: { nil }))
    }
}
