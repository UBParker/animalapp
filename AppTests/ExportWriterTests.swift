import XCTest
@testable import AnimalTracker

final class ExportWriterTests: XCTestCase {
    private var tmp: URL!
    private var media: FileMediaStore!
    private var audioName: String!
    private var audioSize: Int!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ExportWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        media = FileMediaStore(root: tmp.appendingPathComponent("store", isDirectory: true))
        let source = tmp.appendingPathComponent("source.m4a")
        let bytes = Data((0..<4_096).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        audioSize = bytes.count
        audioName = try media.saveAudio(from: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var out: URL { tmp.appendingPathComponent("out", isDirectory: true) }

    private func bundle(extra: [String] = ["missing-audio.m4a"]) -> ExportBundle {
        var bundle = ExportBundle()
        bundle.voiceRecordings = ([audioName] + extra).map {
            VoiceRecordingExport(id: UUID().uuidString, recordedAt: "2026-11-17T10:00:00Z", durationS: 1,
                                 audioFilename: $0, status: "recorded")
        }
        return bundle
    }

    func testFolderHoldsJsonCsvAndMedia() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (folder, _) = try ExportWriter.writeFolder(bundle: bundle(), media: media, parent: out, now: now)
        let fm = FileManager.default
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, out.standardizedFileURL)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("AnimalTracker-export-"), folder.lastPathComponent)
        for name in ["animal-tracker.json", "voice-recordings.csv", "vocalizations.csv"] {
            XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(name).path), name)
        }
        let copied = folder.appendingPathComponent("Media").appendingPathComponent(audioName)
        let size = try fm.attributesOfItem(atPath: copied.path)[.size] as? Int
        XCTAssertEqual(size, audioSize)
        XCTAssertTrue(media.exists(audioName), "the source stays in the store")
    }

    func testMissingMediaIsListedNotFatal() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (_, missing) = try ExportWriter.writeFolder(bundle: bundle(), media: media, parent: out, now: now)
        XCTAssertEqual(missing, ["missing-audio.m4a"])
    }

    func testInvalidFilenameIsListedNotCopied() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A real file where "../escape.m4a" would point from the store, so only the name check stops it.
        try Data([1, 2, 3]).write(to: tmp.appendingPathComponent("escape.m4a"))
        let (folder, missing) = try ExportWriter.writeFolder(
            bundle: bundle(extra: ["../escape.m4a"]), media: media, parent: out, now: now)
        XCTAssertEqual(missing, ["../escape.m4a"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [folder.lastPathComponent])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Media").path),
                       [audioName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("escape.m4a").path))
    }

    func testArchiveIsAZip() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try ExportWriter.write(bundle: bundle(), media: media, parent: out, now: now)
        XCTAssertEqual(result.archiveURL.pathExtension, "zip")
        XCTAssertEqual(result.missingMedia, ["missing-audio.m4a"])
        let handle = try FileHandle(forReadingFrom: result.archiveURL)
        defer { try? handle.close() }
        XCTAssertEqual(try handle.read(upToCount: 2), Data([0x50, 0x4B]))
        let folder = result.archiveURL.deletingPathExtension()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testTwoExportsDoNotCollide() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let first = try ExportWriter.write(bundle: bundle(), media: media, parent: out, now: now)
        let second = try ExportWriter.write(bundle: bundle(), media: media, parent: out, now: now)
        XCTAssertNotEqual(first.archiveURL, second.archiveURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.archiveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.archiveURL.path))
    }
}
