import XCTest
@testable import AnimalVoiceStats

final class ReadinessTests: XCTestCase {
    func testReadyAtBoundary() {
        XCTAssertEqual(Readiness.check(labelCounts: ["hungry": 5, "annoyed": 5, "greeting": 1]), .ready(labels: ["annoyed", "hungry"]))
    }

    func testNotReadyReportsNeeded() {
        let status = Readiness.check(labelCounts: ["hungry": 5, "annoyed": 4])
        guard case let .notReady(message, needed) = status else { return XCTFail("expected notReady") }
        XCTAssertEqual(needed, ["annoyed": 1])
        XCTAssertTrue(message.contains("1 of 2"))
    }

    func testEmpty() {
        guard case let .notReady(message, needed) = Readiness.check(labelCounts: [:]) else { return XCTFail() }
        XCTAssertTrue(needed.isEmpty)
        XCTAssertTrue(message.contains("No labeled sounds yet"))
    }
}
