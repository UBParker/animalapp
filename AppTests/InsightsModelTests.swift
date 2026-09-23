import AnimalVoiceAudio
import AnimalVoiceStats
import XCTest
@testable import AnimalTracker

final class InsightsModelTests: XCTestCase {
    private func item(_ meaning: String?, f0: Double? = 500) -> InsightsModel.Item {
        InsightsModel.Item(id: UUID(), features: VoiceFixtures.features(f0: f0), meaning: meaning)
    }

    func testCountsOrderAndPoints() {
        let items = [item("Hungry"), item("Hungry"), item("Annoyed"), item("Annoyed", f0: nil), item(nil), item(VoiceTagSeed.unknownMeaning), item("")]
        let s = InsightsModel.summarize(items)
        XCTAssertEqual(s.labeledCount, 4)
        XCTAssertEqual(s.unlabeledCount, 3)
        XCTAssertEqual(s.labelCounts, ["Hungry": 2, "Annoyed": 2])
        XCTAssertEqual(s.legendOrder, ["Annoyed", "Hungry"]) // tie on count, alphabetical
        XCTAssertEqual(s.points.count, 3, "unvoiced sounds have no pitch to plot")
        guard case .notReady = s.readiness else { return XCTFail("expected notReady") }
        XCTAssertNil(s.evaluation)
    }

    func testMoreThanSixMeaningsFoldIntoOther() {
        var items: [InsightsModel.Item] = []
        for (i, name) in ["A", "B", "C", "D", "E", "F", "G", "H"].enumerated() {
            for _ in 0...(8 - i) { items.append(item(name)) } // A has 9, H has 2
        }
        let s = InsightsModel.summarize(items)
        XCTAssertEqual(s.legendOrder, ["A", "B", "C", "D", "E", "F", InsightsModel.otherLabel])
        XCTAssertEqual(s.points.filter { $0.meaning == InsightsModel.otherLabel }.count, 3 + 2)
        guard case .ready = s.readiness else { return XCTFail("expected ready") }
        XCTAssertNotNil(s.evaluation)
    }
}
