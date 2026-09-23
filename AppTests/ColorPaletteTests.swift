import SwiftUI
import XCTest
@testable import AnimalTracker

final class ColorPaletteTests: XCTestCase {
    func testEveryPresetRoundTrips() {
        for hex in ColorPalette.presets {
            XCTAssertEqual(ColorPalette.hex(ColorPalette.color(hex)), hex, "round trip failed for \(hex)")
        }
        XCTAssertEqual(ColorPalette.defaultHex, ColorPalette.presets[0])
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(ColorPalette.hex(ColorPalette.color("  #2A78D6\n")), "#2A78D6")
        XCTAssertEqual(ColorPalette.hex(ColorPalette.color("2a78d6")), "#2A78D6")
    }

    func testMalformedInputFallsBack() {
        for bad in ["", "#", "#12345", "#1234567", "#GGGGGG", "nope"] {
            XCTAssertEqual(ColorPalette.color(bad), Color.gray, "expected gray for \(bad)")
            XCTAssertEqual(ColorPalette.contrastingText(on: bad), Color.white, "expected white for \(bad)")
        }
    }

    func testContrastingText() {
        XCTAssertEqual(ColorPalette.contrastingText(on: "#FFFFFF"), Color.black)
        XCTAssertEqual(ColorPalette.contrastingText(on: "#000000"), Color.white)
    }

    func testOutOfRangeComponentsAreClamped() throws {
        let hex = ColorPalette.hex(Color(red: 1.2, green: -0.1, blue: 0.5))
        XCTAssertEqual(hex.count, 7)
        XCTAssertTrue(hex.hasPrefix("#"))
        let value = try XCTUnwrap(UInt32(hex.dropFirst(), radix: 16))
        for component in [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF] {
            XCTAssertTrue((0...255).contains(component), "component \(component) out of range in \(hex)")
        }
    }
}
