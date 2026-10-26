import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ContainerResetTests: XCTestCase {
    /// Containers do not keep themselves alive and a ModelContext does not retain its container.
    private var retained: [ModelContainer] = []

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("default.store")
    }

    private func makeDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func testStoreURLsAreTheStoreAndItsTwoSidecars() {
        let url = tempStoreURL()
        let names = PersistenceController.storeURLs(url: url).map(\.lastPathComponent)
        XCTAssertEqual(names, ["default.store", "default.store-shm", "default.store-wal"])
    }

    func testDestroyIncludingRecoveredCopiesRemovesTheCorruptCopiesToo() throws {
        let url = tempStoreURL()
        let directory = url.deletingLastPathComponent()
        try makeDirectory(for: url)
        let container = try PersistenceController.makeContainer(url: url)
        retained.append(container)
        container.mainContext.insert(Animal(name: "Pip", species: "cat"))
        try container.mainContext.save()

        // What `moveAside` leaves behind after a recovery. These are a full copy of the previous
        // person's records, so a sign-out wipe has to take them as well.
        try Data("old".utf8).write(to: directory.appending(path: "default.store.corrupt-1750000000"))
        try Data("old".utf8).write(to: directory.appending(path: "default.store-wal.corrupt-1750000000"))

        PersistenceController.destroyIncludingRecoveredCopies(url: url)

        // Assert what this method is for rather than total emptiness. The container opened above is
        // deliberately still retained (so SwiftData does not trap), and a retained SQLite
        // connection on an unlinked inode is free to recreate `default.store-wal` or `-shm` on a
        // checkpoint between the unlink and this listing. Asserting an empty directory would make
        // the case fail intermittently with a message about the wrong subject (C-D9).
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(left.allSatisfy { !$0.contains(".corrupt-") }, "recovered copies left behind: \(left)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the store itself is gone")
    }

    func testWipingRebuildsAnEmptyStoreThatStillHasTheBuiltInTags() async throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)
        _ = try? VoiceTagSeed.seedIfNeeded(context: opened.container.mainContext)
        opened.container.mainContext.insert(Animal(name: "Miso", species: "cat"))
        try opened.container.mainContext.save()

        // A real FileMediaStore on its own temporary root, so the media half of the wipe is
        // exercised against the filesystem rather than a dictionary (verification defect D-D6).
        let mediaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        let media = FileMediaStore(root: mediaRoot)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: source)
        let audioName = try media.saveAudio(from: source)
        XCTAssertTrue(media.exists(audioName), "the fixture is really on disk before the wipe")

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: opened.recovered,
                                          mediaStore: media, storeURL: url)
        XCTAssertFalse(try lifecycle.storeIsEmpty(), "an animal makes the store non-empty")

        await lifecycle.wipeStore()
        retained.append(lifecycle.container)

        XCTAssertFalse(media.exists(audioName), "the audio file goes with the store")
        let leftInMedia = try FileManager.default.contentsOfDirectory(atPath: mediaRoot.path)
        XCTAssertEqual(leftInMedia, [], "the media directory is empty after a wipe, left: \(leftInMedia)")

        XCTAssertEqual(try lifecycle.container.mainContext.fetch(FetchDescriptor<Animal>()).count, 0)
        XCTAssertTrue(try lifecycle.storeIsEmpty())
        XCTAssertEqual(lifecycle.generation, 1)
        let tags = try lifecycle.container.mainContext.fetch(FetchDescriptor<VoiceTag>())
        XCTAssertEqual(tags.count, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count,
                       "a wiped store is re-seeded, and re-seeded exactly once")
        XCTAssertEqual(tags.first { $0.kind == .meaning && $0.name == "Hungry" }?.id,
                       VoiceTagSeed.builtInID(kind: .meaning, name: "Hungry"),
                       "with the same ids as before the wipe, so a later pull merges rather than doubles")
    }

    /// "Empty" has to mean "no records the person made". The built-in tags are always there, so a
    /// store that only holds them is still a fresh store, and a fresh install must not be wiped.
    func testAStoreHoldingOnlyBuiltInTagsCountsAsEmpty() throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)
        _ = try? VoiceTagSeed.seedIfNeeded(context: opened.container.mainContext)

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: opened.recovered,
                                          mediaStore: InMemoryMediaStore(), storeURL: url)
        XCTAssertTrue(try lifecycle.storeIsEmpty())

        opened.container.mainContext.insert(VoiceTag(kind: .meaning, name: "Ash's own tag"))
        try opened.container.mainContext.save()
        XCTAssertFalse(try lifecycle.storeIsEmpty(), "a tag the person added is their data")
    }
}
