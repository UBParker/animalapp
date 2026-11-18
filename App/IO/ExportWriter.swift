import Foundation

struct ExportResult: Equatable {
    let archiveURL: URL
    /// Media names the data refers to that could not be copied: gone from disk, or not a valid
    /// store filename. Sorted. The export still succeeds without them.
    let missingMedia: [String]
}

/// Writes an `ExportBundle` to disk as one zip: `animal-tracker.json`, the voice CSVs, and the media
/// files under `Media/` with their store names, so the JSON's filenames resolve inside the archive.
enum ExportWriter {
    static let jsonName = "animal-tracker.json"
    static let recordingsCSVName = "voice-recordings.csv"
    static let vocalizationsCSVName = "vocalizations.csv"
    static let mediaFolderName = "Media"

    static func writeFolder(bundle: ExportBundle, media: MediaStore, parent: URL, now: Date) throws
        -> (folder: URL, missingMedia: [String]) {
        let fm = FileManager.default
        let folder = parent.appendingPathComponent(folderName(now: now), isDirectory: true)
        let mediaFolder = folder.appendingPathComponent(mediaFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            try JSONExporter.data(bundle).write(to: folder.appendingPathComponent(jsonName))
            try Data(VoiceCSVExporter.recordings(bundle).utf8).write(to: folder.appendingPathComponent(recordingsCSVName))
            try Data(VoiceCSVExporter.vocalizations(bundle).utf8)
                .write(to: folder.appendingPathComponent(vocalizationsCSVName))

            var missing: [String] = []
            for name in mediaNames(bundle) {
                guard MediaNaming.isValid(name), media.exists(name) else {
                    missing.append(name)
                    continue
                }
                // copyItem, never through Data: a long audio history must not be read into memory.
                try fm.copyItem(at: media.url(for: name), to: mediaFolder.appendingPathComponent(name))
            }
            return (folder, missing.sorted())
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Zips `folder` to `<folder path>.zip`. The system builds the zip from disk via a
    /// `.forUploading` coordinated read; the URL it hands back is valid only inside the accessor,
    /// so it is copied out there.
    static func archive(folder: URL) throws -> URL {
        let destination = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + ".zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zip in
            do { try FileManager.default.copyItem(at: zip, to: destination) } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return destination
    }

    static func write(bundle: ExportBundle, media: MediaStore,
                      parent: URL = FileManager.default.temporaryDirectory, now: Date = Date()) throws -> ExportResult {
        let (folder, missing) = try writeFolder(bundle: bundle, media: media, parent: parent, now: now)
        defer { try? FileManager.default.removeItem(at: folder) }
        return ExportResult(archiveURL: try archive(folder: folder), missingMedia: missing)
    }

    /// `AnimalTracker-export-<yyyy-MM-dd>-<8 hex>`; the random suffix keeps two exports on the same
    /// day apart.
    private static func folderName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "AnimalTracker-export-\(formatter.string(from: now))-\(suffix)"
    }

    /// Every media name the data refers to, once each, empty strings skipped.
    private static func mediaNames(_ bundle: ExportBundle) -> [String] {
        let names = bundle.voiceRecordings.map(\.audioFilename)
            + bundle.animals.flatMap { [$0.photoFilename, $0.photoThumbnailFilename].compactMap { $0 } }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
