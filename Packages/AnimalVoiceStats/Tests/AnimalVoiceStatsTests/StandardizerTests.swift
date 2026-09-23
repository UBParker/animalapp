import XCTest
@testable import AnimalVoiceStats

final class StandardizerTests: XCTestCase {
    func testFitIgnoresNaNAndTransformsMissingToZero() {
        let s = Standardizer.fit([[1, 10], [3, 30], [.nan, 50]])
        XCTAssertEqual(s.means, [2, 30])
        XCTAssertEqual(s.stds[0], 1, accuracy: 1e-9)
        XCTAssertEqual(s.stds[1], 16.3299, accuracy: 1e-3) // population std of 10, 30, 50
        XCTAssertEqual(s.transform([3, .nan]), [1, 0])
    }

    func testConstantColumnGetsUnitStd() {
        let s = Standardizer.fit([[5, 1], [5, 2]])
        XCTAssertEqual(s.stds[0], 1)
        XCTAssertEqual(s.transform([5, 1.5]), [0, 0])
    }

    func testEmptyFit() {
        let s = Standardizer.fit([])
        XCTAssertEqual(s.means, [])
        XCTAssertEqual(s.transform([1, 2]), [])
    }
}
