import XCTest
@testable import AnimalTracker

final class VoiceCSVExporterTests: XCTestCase {
    private let juniperId = UUID().uuidString
    private let withAnimalId = UUID().uuidString
    private let withoutId = UUID().uuidString

    private func bundle(mfcc: [Double] = Array(repeating: 0, count: 13), note: String = "") -> ExportBundle {
        var bundle = ExportBundle()
        bundle.animals = [AnimalExport(id: juniperId, name: "Juniper", species: "horse")]
        bundle.voiceRecordings = [
            VoiceRecordingExport(id: withAnimalId, animalId: juniperId, recordedAt: "2026-11-17T10:00:00Z",
                                 durationS: 2, audioFilename: "a-audio.m4a", status: "analyzed", note: note,
                                 activityTag: "Eating", meaningTag: "Hungry", userConfidence: 3),
            VoiceRecordingExport(id: withoutId, animalId: nil, recordedAt: "2026-11-17T11:00:00Z",
                                 durationS: 1, audioFilename: "b-audio.m4a", status: "recorded"),
        ]
        bundle.vocalizations = [
            VocalizationExport(id: UUID().uuidString, recordingId: withAnimalId, startS: 0.1, endS: 0.5,
                               f0Mean: 600, mfcc: mfcc, activityTag: "Eating", meaningTag: "Hungry",
                               userConfidence: 2, overridden: true),
        ]
        return bundle
    }

    private func lines(_ document: String) -> [String] {
        document.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func testHeadersVerbatim() {
        let recordings = "animal,timestamp_iso8601,duration_s,audio_filename,status,activity,meaning,confidence,note"
        let vocalizations = "animal,recording_id,start_s,end_s,f0_mean,f0_min,f0_max,f0_slope,voiced_fraction,rms_db,"
            + "spectral_centroid_hz,mfcc0,mfcc1,mfcc2,mfcc3,mfcc4,mfcc5,mfcc6,mfcc7,mfcc8,mfcc9,mfcc10,mfcc11,mfcc12,"
            + "activity,meaning,confidence,overridden"
        XCTAssertEqual(lines(VoiceCSVExporter.recordings(bundle()))[0], recordings)
        XCTAssertEqual(lines(VoiceCSVExporter.vocalizations(bundle()))[0], vocalizations)
    }

    func testRecordingRowUsesAnimalName() {
        let rows = lines(VoiceCSVExporter.recordings(bundle()))
        XCTAssertEqual(rows[1], "Juniper,2026-11-17T10:00:00Z,2.0,a-audio.m4a,analyzed,Eating,Hungry,3,")
        XCTAssertTrue(rows[2].hasPrefix(","), rows[2])
        XCTAssertTrue(lines(VoiceCSVExporter.vocalizations(bundle()))[1].hasPrefix("Juniper,\(withAnimalId),"))
    }

    func testShortMfccPadsEmpty() {
        let short = lines(VoiceCSVExporter.vocalizations(bundle(mfcc: [1, 2, 3])))[1]
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(short.count, VoiceCSVExporter.vocalizationsHeader.count)
        let mfcc0 = VoiceCSVExporter.vocalizationsHeader.firstIndex(of: "mfcc0")!
        XCTAssertEqual(Array(short[mfcc0..<mfcc0 + 3]), ["1.0", "2.0", "3.0"])
        XCTAssertEqual(Array(short[mfcc0 + 3..<mfcc0 + 13]), Array(repeating: "", count: 10))
        XCTAssertEqual(Array(short.suffix(4)), ["Eating", "Hungry", "2", "true"])

        let long = lines(VoiceCSVExporter.vocalizations(bundle(mfcc: (0..<15).map(Double.init))))[1]
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(long.count, VoiceCSVExporter.vocalizationsHeader.count)
        XCTAssertEqual(long[mfcc0 + 12], "12.0")
        XCTAssertEqual(long[mfcc0 + 13], "Eating")
    }

    func testRecordingNoteWithCommaAndNewlineIsQuoted() {
        let document = VoiceCSVExporter.recordings(bundle(note: "ate, then\nslept"))
        XCTAssertTrue(document.contains(",3,\"ate, then\nslept\"\n"), document)
    }
}
