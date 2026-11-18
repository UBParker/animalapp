import XCTest
@testable import AnimalTracker

final class ExportFormattersTests: XCTestCase {
    func testTimestampHasOffsetAndNoFraction() {
        let s = ExportFormatters.timestamp(Date(timeIntervalSince1970: 1_790_000_000.75))
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#
        XCTAssertNotNil(s.range(of: pattern, options: .regularExpression), s)
        XCTAssertNil(ExportFormatters.optionalTimestamp(nil))
        XCTAssertEqual(ExportFormatters.decimal(nil), "")
        XCTAssertEqual(ExportFormatters.decimal(2), "2.0")
        XCTAssertEqual(ExportFormatters.integer(nil), "")
        XCTAssertEqual(ExportFormatters.integer(3), "3")
        XCTAssertEqual(ExportFormatters.flag(true), "true")
        XCTAssertEqual(ExportFormatters.flag(false), "false")
    }
}
