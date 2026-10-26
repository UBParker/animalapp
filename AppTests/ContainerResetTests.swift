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

        let wipe = await lifecycle.wipeStore()
        XCTAssertEqual(wipe, .wiped)
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

    /// A1, Critical. The wipe reopens the store at the same path, so it has to prove the old one
    /// is gone first. A `.store` file that survives the unlink while its sidecars go is still an
    /// intact SQLite database: reopening it republishes the previous person's records as a clean
    /// store, and `AuthService.establish` then writes a verified ownership claim over them for
    /// whoever is signing in. Verified with raw sqlite3 by reviewer A.
    func testAWipeThatCannotRemoveTheStoreDoesNotReopenAndPublishesNothing() async throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)
        opened.container.mainContext.insert(Animal(name: "Previous user's cat", species: "cat"))
        try opened.container.mainContext.save()

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: false,
                                          mediaStore: InMemoryMediaStore(), storeURL: url)
        let directory = url.deletingLastPathComponent()
        // Unlinking a file needs write permission on the directory holding it, so this is the
        // cheapest real version of the failure the three `try?` discarded: `removeItem` throws and
        // the file stays exactly where it was.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let outcome = await lifecycle.wipeStore()

        XCTAssertEqual(outcome, .storeSurvived)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the premise of the case: the store file really did survive the destroy")
        XCTAssertEqual(lifecycle.generation, 0,
                       "nothing is republished, so the UI is never told to re-subscribe")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try lifecycle.container.mainContext.fetch(FetchDescriptor<Animal>()).count, 1,
                       "the container in front of the UI is still the one that was already there")
    }

    /// RULING 2. A media root that could not be emptied is the same class of failure as an
    /// unverified store wipe, so it is reported. But it must not abort the reopen: an app that
    /// cannot open a store because one file would not unlink is a worse failure than the leftover.
    func testAWipeThatCannotEmptyTheMediaRootStillReopensAndReportsTheLeftovers() async throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)

        let mediaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        let media = FileMediaStore(root: mediaRoot)
        let locked = mediaRoot.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("previous person's audio".utf8).write(to: locked.appendingPathComponent("one.m4a"))
        try Data("more of it".utf8).write(to: mediaRoot.appendingPathComponent("two.m4a"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: false,
                                          mediaStore: media, storeURL: url)
        let outcome = await lifecycle.wipeStore()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)

        XCTAssertEqual(outcome, .mediaSurvived)
        XCTAssertEqual(lifecycle.generation, 1, "the store half worked, so the reopen still happened")
        XCTAssertTrue(try lifecycle.storeIsEmpty())
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaRoot.appendingPathComponent("two.m4a").path),
                       "removeAll is best effort before it is verified: a sibling it could remove is gone")
        XCTAssertFalse(try media.contents().isEmpty, "and what it could not remove is still reported")
    }

    /// RULING 3. `cancelSync()` does not stop every writer: `RecordView.finish()` and
    /// `AskView.finish()` each run a bare `Task` that view teardown does not cancel, and it writes
    /// audio through `mediaStore.saveAudio(from:)` before inserting its row. The row lands in the
    /// dead container and is discarded; the file lands in the recreated media directory. So the
    /// removal has to run again after the reseed, when every file in the root is orphaned by
    /// definition.
    func testTheMediaRootIsReconciledAfterTheReseedSoALateWriterCannotBeatTheWipe() async throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)

        let media = LateWritingMediaStore()
        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: false,
                                          mediaStore: media, storeURL: url)
        var tagsAtSecondRemoval: Int?
        media.onRemoveAll = { [weak lifecycle] call in
            if call == 1 {
                // The bare Task resuming after the first removal, writing one file into the
                // directory that was just recreated.
                media.files.insert("late-audio.m4a")
            } else {
                // `wipeStore()` is main-actor work, so this call is already on it.
                MainActor.assumeIsolated {
                    guard let lifecycle else { return }
                    tagsAtSecondRemoval = (try? lifecycle.container.mainContext
                        .fetchCount(FetchDescriptor<VoiceTag>())) ?? -1
                }
            }
        }

        let outcome = await lifecycle.wipeStore()

        XCTAssertEqual(outcome, .wiped)
        XCTAssertEqual(media.removeAllCalls, 2, "once before the reopen, once after the reseed")
        XCTAssertEqual(media.files, [], "the file the late writer left is gone")
        XCTAssertEqual(tagsAtSecondRemoval, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count,
                       "the second removal runs after the reseed, which is what makes every file in the root orphaned")
    }

    /// A2. `recovered` drives the only warning the person gets that this launch is on a throwaway
    /// store, and `wipeStore()` dropped the flag the reopen returned.
    func testTheRecoveredFlagIsRepublishedByAWipe() async throws {
        let url = tempStoreURL()
        try makeDirectory(for: url)
        let opened = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(opened.container)

        let lifecycle = AppStoreLifecycle(container: opened.container, recovered: true,
                                          mediaStore: InMemoryMediaStore(), storeURL: url)
        XCTAssertTrue(lifecycle.recovered)

        _ = await lifecycle.wipeStore()

        XCTAssertFalse(lifecycle.recovered,
                       "a wipe that opened a real store on disk clears the warning the launch raised")
    }

    /// A5. The app opened the store with `url: nil` and the wipe destroyed a derived `storeURL`:
    /// two expressions for one path, load-bearing for every destructive path and asserted nowhere.
    /// This runs on the simulator, which is the platform the question was open on.
    func testTheDefaultStoreConfigurationIsTheSamePathTheWipeDestroys() throws {
        let container = try PersistenceController.makeContainer()
        XCTAssertEqual(container.configurations.first?.url.standardizedFileURL,
                       PersistenceController.storeURL.standardizedFileURL)
    }

    /// A7. `storeIsEmpty()` counts four model types by hand and nothing links it to the schema. A
    /// model added without a matching fetch makes a store full of that model read as empty, which
    /// is `.claimEmpty`, which adopts it into the account signing in with no wipe and no watermark
    /// reset. Task 11's unpushed tombstones are exactly that case.
    func testEveryModelTypeIsCountedByStoreIsEmpty() {
        XCTAssertEqual(PersistenceController.modelTypes.count, 4,
                       "a model type was added: teach AppStoreLifecycle.storeIsEmpty() to count it, then update this number")
    }
}

/// A media store whose root can be written to while a wipe is running, which is what the two bare
/// `Task`s in the voice views do when they resume after the container has been replaced.
private final class LateWritingMediaStore: MediaStore {
    var files: Set<String> = []
    var removeAllCalls = 0
    /// Called at the end of each `removeAll()`, with the number of the call. Not `@MainActor`, so
    /// the conformance stays off the main actor; `wipeStore()` runs there, so the test body uses
    /// `MainActor.assumeIsolated` to read the container it has just reopened.
    var onRemoveAll: ((Int) -> Void)?

    func savePhoto(_ data: Data) throws -> SavedPhoto { throw MediaStoreError.invalidImage }
    func saveVideo(from url: URL) throws -> String { MediaNaming.video() }
    func saveAudio(from url: URL) throws -> String {
        let name = MediaNaming.audio()
        files.insert(name)
        return name
    }
    func url(for filename: String) -> URL { URL(fileURLWithPath: "/dev/null") }
    func exists(_ filename: String) -> Bool { files.contains(filename) }
    func delete(_ filename: String) { files.remove(filename) }
    func contents() throws -> [String] { files.sorted() }
    func removeAll() throws {
        removeAllCalls += 1
        files.removeAll()
        let call = removeAllCalls
        onRemoveAll?(call)
    }
}
