import XCTest
@testable import AnimalTracker

final class AnimalToolbarTests: XCTestCase {
    func testLocalOnlyHidesCheckIn() {
        XCTAssertFalse(AnimalToolbar.showsCheckIn(localOnly: true))
    }

    func testFullBuildShowsCheckIn() {
        XCTAssertTrue(AnimalToolbar.showsCheckIn(localOnly: false))
    }
}
