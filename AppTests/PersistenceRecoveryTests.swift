import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PersistenceRecoveryTests: XCTestCase {
    private var retained: [ModelContainer] = []

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("default.store")
    }

    private func siblings(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    }

    func testGarbageStoreIsRecoveredNotFatal() throws {
        let url = tempStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: url)
        try Data([0]).write(to: url.deletingLastPathComponent().appending(path: "default.store-wal"))

        let result = PersistenceController.makeContainerWithRecovery(url: url)
        retained.append(result.container)

        // The app keeps running either way: what matters is that a container opens and works.
        let context = result.container.mainContext
        context.insert(Animal(name: "Juniper", species: "horse"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Animal>()).count, 1)

        let names = try siblings(of: url)
        let movedAside = names.contains { $0.contains(".corrupt-") }
        let replaced = (try? Data(contentsOf: url)) != Data("not a sqlite database".utf8)
        XCTAssertTrue(movedAside || replaced, "garbage store was left in place: \(names)")
    }

    func testDestroyRemovesTheStoreAndItsSidecars() throws {
        let url = tempStoreURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(url: url)
        retained.append(container)
        container.mainContext.insert(Animal(name: "Pip", species: "cat"))
        try container.mainContext.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        PersistenceController.destroy(url: url)
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: name).path), "\(name) survived destroy()")
        }
    }

    func testStoreURLIsInApplicationSupport() {
        XCTAssertEqual(PersistenceController.storeURL.lastPathComponent, "default.store")
        XCTAssertEqual(PersistenceController.storeURL.deletingLastPathComponent().standardizedFileURL,
                       URL.applicationSupportDirectory.standardizedFileURL)
    }
}
