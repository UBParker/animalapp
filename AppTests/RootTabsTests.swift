import XCTest
@testable import AnimalTracker

final class RootTabsTests: XCTestCase {
    func testLocalOnlyShowsOnlyVoice() {
        XCTAssertEqual(RootTabs.visible(localOnly: true), [.voice])
    }

    func testFullBuildShowsEveryTabInOrder() {
        XCTAssertEqual(RootTabs.visible(localOnly: false), [.buttons, .feed, .poop, .health, .voice])
    }
}
