import XCTest
@testable import AnimalTracker

final class AppModeTests: XCTestCase {
    func testThisBuildIsLocalOnly() {
        XCTAssertTrue(AppMode.isLocalOnly)
    }
}
