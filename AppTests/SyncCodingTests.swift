import XCTest
@testable import AnimalTracker

/// These coders are not a test convenience: Task 4 hands them to the client as
/// `DatabaseOptions(encoder:decoder:)`, so what is asserted here is literally what goes on the wire.
final class SyncCodingTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_750_000_000.25)

    func testDatesEncodeAsIso8601WithFractionalSecondsInUtc() {
        let text = SyncCoding.string(from: moment)
        XCTAssertTrue(text.hasSuffix("Z"), text)
        XCTAssertTrue(text.contains(".250"), text)
    }

    func testDatesRoundTripToTheMillisecond() throws {
        let back = try XCTUnwrap(SyncCoding.date(from: SyncCoding.string(from: moment)))
        XCTAssertEqual(back.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Postgres omits the fractional part when it is zero, and renders the zone as +00:00 rather
    /// than Z, so the decoder has to take all three shapes.
    /// 1_789_819_200 is 2026-09-19T12:00:00Z. Computed, not guessed:
    /// `python3 -c "import datetime;print(int(datetime.datetime(2026,9,19,12,0,tzinfo=datetime.timezone.utc).timestamp()))"`
    func testDecoderAcceptsTimestampsWithoutFractionalSecondsAndWithAnOffsetZone() throws {
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00Z")).timeIntervalSince1970,
                       1_789_819_200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00+00:00")).timeIntervalSince1970,
                       1_789_819_200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00.125+00:00")).timeIntervalSince1970,
                       1_789_819_200.125, accuracy: 0.001)
    }

    func testDecoderRejectsSomethingThatIsNotADate() {
        XCTAssertNil(SyncCoding.date(from: "yesterday"))
    }

    struct Sample: Codable, Equatable {
        var when: Date
        var maybe: Date?
    }

    func testEncoderAndDecoderAgreeThroughJson() throws {
        let value = Sample(when: moment, maybe: nil)
        let data = try SyncCoding.encoder.encode(value)
        let back = try SyncCoding.decoder.decode(Sample.self, from: data)
        XCTAssertEqual(back.when.timeIntervalSince1970, moment.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(back.maybe)
    }

    /// Swift's synthesized Codable uses encodeIfPresent for optionals, so a nil is omitted rather
    /// than sent as JSON null. Pinned here because it is the reason none of Task 8's row structs
    /// use the synthesized encoder: PostgREST refuses a bulk upsert whose objects do not all carry
    /// the same keys (PGRST102), and omitted nils make the key set depend on the row's contents.
    /// Task 8's rows write an explicit `encode(to:)` instead; `SyncRowTests` asserts that.
    func testSynthesizedCodableOmitsNilWhichIsWhyRowsEncodeExplicitly() throws {
        let data = try SyncCoding.encoder.encode(Sample(when: moment, maybe: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(json.keys.contains("maybe"))
    }
}
