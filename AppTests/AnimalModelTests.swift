import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class AnimalModelTests: XCTestCase {
    func testRoundTripAndDefaults() throws {
        let context = try TestSupport.container().mainContext
        let a = Animal(name: "Juniper", species: "horse")
        context.insert(a)
        try context.save()
        let fetched = try context.fetch(FetchDescriptor<Animal>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].name, "Juniper")
        XCTAssertTrue(fetched[0].tracksOutdoorTime)
        XCTAssertFalse(fetched[0].isArchived)
        XCTAssertEqual(fetched[0].sortOrder, 0)
        XCTAssertEqual(fetched[0].colorHex, ColorPalette.defaultHex)
        XCTAssertFalse(fetched[0].isCat)
        XCTAssertEqual(fetched[0].displayInitial, "J")
    }

    func testIsCatAndDogDefaults() {
        XCTAssertTrue(Animal(name: "Miso", species: "Cat").isCat)
        XCTAssertTrue(Animal(name: "Bob", species: "bobcat").isCat)
        XCTAssertFalse(Animal(name: "Rex", species: "dog").tracksOutdoorTime)
    }

    func testEnumsRoundTripAsStrings() {
        XCTAssertEqual(PressKind(rawValue: "prompted"), .prompted)
        XCTAssertEqual(FeedCategory.allCases.map(\.rawValue), ["forage", "food", "supplement", "treat"])
        XCTAssertEqual(VoiceStatus.noSounds.rawValue, "noSounds")
        XCTAssertEqual(VoiceTagKind.allCases.count, 2)
        XCTAssertEqual(CheckInStatus.allCases.count, 5)
        XCTAssertEqual(TurnRole.assistant.rawValue, "assistant")
    }
}
