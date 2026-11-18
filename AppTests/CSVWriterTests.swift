import XCTest
@testable import AnimalTracker

final class CSVWriterTests: XCTestCase {
    func testPlainFieldIsUnquoted() {
        XCTAssertEqual(CSVWriter.field("plain"), "plain")
    }

    func testCommaIsQuoted() {
        XCTAssertEqual(CSVWriter.field("a,b"), "\"a,b\"")
    }

    func testInnerQuotesAreDoubled() {
        XCTAssertEqual(CSVWriter.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testNewlineIsQuoted() {
        XCTAssertEqual(CSVWriter.field("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(CSVWriter.field("a\rb"), "\"a\rb\"")
    }

    func testEmojiIsUnquoted() {
        XCTAssertEqual(CSVWriter.field("🐴"), "🐴")
    }

    func testDocumentHasTrailingNewline() {
        XCTAssertEqual(CSVWriter.document(header: ["a", "b"], rows: [["1", "2"]]), "a,b\n1,2\n")
    }
}
