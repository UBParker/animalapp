import UIKit
import XCTest
@testable import AnimalTracker

final class ImageProcessingTests: XCTestCase {
    func testDownscalesLongestSideTo2048() throws {
        let big = TestImages.jpeg(width: 3000, height: 1000)
        let out = try XCTUnwrap(ImageProcessing.downscaledJPEG(big))
        let size = try XCTUnwrap(ImageProcessing.pixelSize(of: out))
        XCTAssertEqual(size.width, 2048, accuracy: 1)
        XCTAssertEqual(size.height, 683, accuracy: 2)
    }

    func testSmallImageIsNotUpscaled() throws {
        let small = TestImages.jpeg(width: 400, height: 300)
        let out = try XCTUnwrap(ImageProcessing.downscaledJPEG(small))
        XCTAssertEqual(ImageProcessing.pixelSize(of: out), CGSize(width: 400, height: 300))
    }

    func testThumbnailIs300OnLongestSide() throws {
        let out = try XCTUnwrap(ImageProcessing.thumbnailJPEG(TestImages.jpeg(width: 1200, height: 600)))
        let size = try XCTUnwrap(ImageProcessing.pixelSize(of: out))
        XCTAssertEqual(size.width, 300, accuracy: 1)
        XCTAssertEqual(size.height, 150, accuracy: 1)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ImageProcessing.downscaledJPEG(Data([1, 2, 3])))
        XCTAssertNil(ImageProcessing.pixelSize(of: Data()))
    }
}
