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
        // Genuinely non-zero offsets. Every vector above is at offset zero, so none of them can
        // tell a parser that honours the offset in the string from one that ignores it and reads
        // the wall-clock part as UTC. These two can: both are 12:00:00.125Z written in another
        // zone, so a parser that dropped the offset would be two hours out and seven hours out.
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T14:00:00.125+02:00")).timeIntervalSince1970,
                       1_789_819_200.125, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T05:00:00.125-07:00")).timeIntervalSince1970,
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
    /// Parsing floors to the millisecond and never rounds up, and the pull cursor's skip-safety
    /// rests on it. The cursor is a server timestamp this app parsed and sends back as a `gte`
    /// filter, so a floored cursor can only ever re-fetch a row, never miss one. Round to nearest
    /// instead and a page ending at `.123600` yields a cursor of `.124`, and the unconsumed row
    /// stamped `.123900` is excluded by the next `gte` forever, silently.
    ///
    /// `accuracy: 0.0001` is the point of the test. The 0.001 every other date assertion here uses
    /// is exactly wide enough to accept a millisecond rounding change without complaining.
    func testParsingFloorsToTheMillisecondSoTheCursorCannotSkipARow() throws {
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00.123999Z")).timeIntervalSince1970,
                       1_789_819_200.123, accuracy: 0.0001,
                       "parsing floors; the pull cursor must never round up past an unpulled row")
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-19T12:00:00.999999Z")).timeIntervalSince1970,
                       1_789_819_200.999, accuracy: 0.0001,
                       "and it does not carry into the next whole second either")
        // Postgres writes microseconds. Six digits parse rather than falling through to nil, so a
        // pull cannot fail on a real PostgREST timestamp.
        XCTAssertEqual(try XCTUnwrap(SyncCoding.date(from: "2026-09-25T15:35:14.823456+00:00")).timeIntervalSince1970,
                       1_790_350_514.823, accuracy: 0.0001)
    }
}
