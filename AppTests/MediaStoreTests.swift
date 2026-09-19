import XCTest
@testable import AnimalTracker

final class MediaStoreTests: XCTestCase {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
    }

    func testFileStoreSavesPhotoAndThumbnailAndDeletes() throws {
        let store = FileMediaStore(root: tempRoot())
        let saved = try store.savePhoto(TestImages.jpeg(width: 3000, height: 1500))
        XCTAssertTrue(saved.filename.hasSuffix("-photo.jpg"))
        XCTAssertTrue(saved.thumbnailFilename.hasSuffix("-thumb.jpg"))
        XCTAssertEqual(saved.filename.dropLast("-photo.jpg".count), saved.thumbnailFilename.dropLast("-thumb.jpg".count))
        XCTAssertTrue(store.exists(saved.filename))
        XCTAssertTrue(store.exists(saved.thumbnailFilename))
        let photoSize = try XCTUnwrap(ImageProcessing.pixelSize(of: Data(contentsOf: store.url(for: saved.filename))))
        XCTAssertEqual(photoSize.width, 2048, accuracy: 1)
        store.delete(saved.filename)
        store.delete(saved.thumbnailFilename)
        XCTAssertFalse(store.exists(saved.filename))
    }

    func testFileStoreCopiesVideoAndAudio() throws {
        let store = FileMediaStore(root: tempRoot())
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: src)
        let audio = try store.saveAudio(from: src)
        XCTAssertTrue(audio.hasSuffix("-audio.m4a"))
        XCTAssertEqual(try Data(contentsOf: store.url(for: audio)), Data([0, 1, 2, 3]))
        let vsrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([9]).write(to: vsrc)
        XCTAssertTrue(try store.saveVideo(from: vsrc).hasSuffix("-video.mov"))
    }

    func testFileStoreRejectsBadPhoto() {
        let store = FileMediaStore(root: tempRoot())
        XCTAssertThrowsError(try store.savePhoto(Data([1, 2, 3])))
    }

    func testInMemoryStoreBehavesTheSame() throws {
        let store = InMemoryMediaStore()
        let saved = try store.savePhoto(TestImages.jpeg(width: 100, height: 100))
        XCTAssertTrue(store.exists(saved.filename))
        XCTAssertTrue(store.exists(saved.thumbnailFilename))
        XCTAssertNoThrow(try Data(contentsOf: store.url(for: saved.filename)))
        store.delete(saved.filename)
        XCTAssertFalse(store.exists(saved.filename))
        XCTAssertThrowsError(try store.savePhoto(Data()))
    }
}
