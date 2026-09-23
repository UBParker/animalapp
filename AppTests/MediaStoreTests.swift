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

    func testFileStoreMovesVideoAndAudioAndConsumesTheSource() throws {
        let store = FileMediaStore(root: tempRoot())
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([0, 1, 2, 3]).write(to: src)
        let audio = try store.saveAudio(from: src)
        XCTAssertTrue(audio.hasSuffix("-audio.m4a"))
        XCTAssertEqual(try Data(contentsOf: store.url(for: audio)), Data([0, 1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "saveAudio must consume the source")
        let vsrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([9]).write(to: vsrc)
        XCTAssertTrue(try store.saveVideo(from: vsrc).hasSuffix("-video.mov"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vsrc.path), "saveVideo must consume the source")
    }

    func testInMemoryStoreConsumesTheSourceToo() throws {
        let store = InMemoryMediaStore()
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data([7]).write(to: src)
        XCTAssertTrue(try store.saveAudio(from: src).hasSuffix("-audio.m4a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "saveAudio must consume the source")
        let vsrc = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([8]).write(to: vsrc)
        XCTAssertTrue(try store.saveVideo(from: vsrc).hasSuffix("-video.mov"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vsrc.path), "saveVideo must consume the source")
    }

    func testNamesThatAreNotASinglePathComponentAreRejected() throws {
        for name in ["", ".", "..", "../x.jpg", "a/b.jpg", "sub\\x.jpg"] {
            XCTAssertFalse(MediaNaming.isValid(name), "\(name) should be invalid")
        }
        XCTAssertTrue(MediaNaming.isValid("abc-photo.jpg"))

        let root = tempRoot()
        let store = FileMediaStore(root: root)
        // A real file one level above the root: the store must not see it or touch it.
        let outside = root.deletingLastPathComponent().appendingPathComponent("x.jpg")
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertFalse(store.exists("../x.jpg"))
        store.delete("../x.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "delete escaped the store root")

        let resolved = store.url(for: "../x.jpg").standardizedFileURL
        XCTAssertEqual(resolved.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(resolved.lastPathComponent.hasPrefix("invalid-"))

        let inMemory = InMemoryMediaStore()
        XCTAssertFalse(inMemory.exists("../x.jpg"))
        inMemory.delete("../x.jpg")
        XCTAssertTrue(inMemory.url(for: "../x.jpg").lastPathComponent.hasPrefix("invalid-"))
    }

    func testFileStoreRejectsBadPhoto() {
        let store = FileMediaStore(root: tempRoot())
        XCTAssertThrowsError(try store.savePhoto(Data([1, 2, 3])))
    }

    func testFileStoreRemovesPhotoWhenThumbnailWriteFails() throws {
        let root = tempRoot()
        let store = FileMediaStore(root: root)
        // One good save first, then clear it, so the root exists and starts empty.
        let seed = try store.savePhoto(TestImages.jpeg(width: 200, height: 200))
        store.delete(seed.filename)
        store.delete(seed.thumbnailFilename)

        store.writeHook = { filename in
            if filename.hasSuffix("-thumb.jpg") { throw MediaStoreError.writeFailed("thumbnail write failed") }
        }
        XCTAssertThrowsError(try store.savePhoto(TestImages.jpeg(width: 200, height: 200)))

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(remaining.filter { $0.hasSuffix("-photo.jpg") }.isEmpty, "orphaned photo left behind: \(remaining)")
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
