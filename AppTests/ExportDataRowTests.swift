import XCTest
@testable import AnimalTracker

final class ExportDataRowTests: XCTestCase {
    func testButtonTitle() {
        XCTAssertEqual(ExportCopy.button, "Export voice data")
    }

    func testNoMissingNoticeWhenNothingIsMissing() {
        XCTAssertNil(ExportCopy.missingNotice(count: 0))
    }

    func testMissingNoticeSingular() {
        XCTAssertEqual(ExportCopy.missingNotice(count: 1), "1 audio or photo file was missing and is not in the export.")
    }

    func testMissingNoticePlural() {
        XCTAssertEqual(ExportCopy.missingNotice(count: 3), "3 audio or photo files were missing and are not in the export.")
    }

    func testRecoveredStoreNoticeShowsOnlyWhenRecovered() {
        XCTAssertNil(ExportCopy.recoveredNotice(recovered: false))
        XCTAssertEqual(ExportCopy.recoveredNotice(recovered: true),
                       "The data store could not be opened, so this export holds only what was recorded since the app started.")
    }
}
