import XCTest
@testable import AnimalTracker

final class AppRootTests: XCTestCase {
    func testLocalOnlyChoosesTheLocalRoot() {
        XCTAssertEqual(AppRoot.choose(localOnly: true), .localOnly)
    }

    func testNotLocalOnlyChoosesTheAuthGatedRoot() {
        XCTAssertEqual(AppRoot.choose(localOnly: false), .authGated)
    }

    func testThisBuildChoosesTheLocalRoot() {
        XCTAssertEqual(AppRoot.choose(localOnly: AppMode.isLocalOnly), .localOnly)
    }
}
