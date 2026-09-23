import Foundation
import SwiftUI

struct SavedPhoto: Equatable {
    let filename: String
    let thumbnailFilename: String
}

enum MediaStoreError: Error {
    case invalidImage
    case writeFailed(String)
}

/// Where photos, videos, and audio live. Filenames are relative single path components; the store
/// owns the directory. A filename that fails `MediaNaming.isValid` names nothing: `exists` is false,
/// `delete` does nothing, and `url(for:)` still resolves inside the store's directory.
protocol MediaStore {
    /// Returns the saved photo and its thumbnail filename.
    func savePhoto(_ data: Data) throws -> SavedPhoto
    /// Consumes the source: on success the file at `url` has been moved into the store and no
    /// longer exists at `url`. Pass a temporary file you own.
    func saveVideo(from url: URL) throws -> String
    /// Consumes the source: on success the file at `url` has been moved into the store and no
    /// longer exists at `url`. Pass a temporary file you own.
    func saveAudio(from url: URL) throws -> String
    func url(for filename: String) -> URL
    func exists(_ filename: String) -> Bool
    func delete(_ filename: String)
}

enum MediaNaming {
    /// True only for a single path component that cannot escape the store's directory.
    static func isValid(_ filename: String) -> Bool {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else { return false }
        return (filename as NSString).lastPathComponent == filename
    }

    /// A name inside the store to stand in for one that is not a usable filename.
    static func sanitized(_ filename: String) -> String {
        isValid(filename) ? filename : "invalid-" + UUID().uuidString.lowercased()
    }

    static func photo(_ id: UUID = UUID()) -> (photo: String, thumb: String) {
        ("\(id.uuidString.lowercased())-photo.jpg", "\(id.uuidString.lowercased())-thumb.jpg")
    }
    static func video(_ id: UUID = UUID()) -> String { "\(id.uuidString.lowercased())-video.mov" }
    static func audio(_ id: UUID = UUID()) -> String { "\(id.uuidString.lowercased())-audio.m4a" }
}

/// Test double: bytes held in memory, `url(for:)` materializes a temp file on demand.
final class InMemoryMediaStore: MediaStore {
    private var files: [String: Data] = [:]
    private let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("inmem-\(UUID().uuidString)")

    init() {}

    func savePhoto(_ data: Data) throws -> SavedPhoto {
        guard let photo = ImageProcessing.downscaledJPEG(data), let thumb = ImageProcessing.thumbnailJPEG(data) else {
            throw MediaStoreError.invalidImage
        }
        let names = MediaNaming.photo()
        try write(photo, to: names.photo)
        do {
            try write(thumb, to: names.thumb)
        } catch {
            delete(names.photo)
            throw error
        }
        return SavedPhoto(filename: names.photo, thumbnailFilename: names.thumb)
    }

    /// Consumes the source, like `FileMediaStore`.
    func saveVideo(from url: URL) throws -> String {
        let name = MediaNaming.video()
        files[name] = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return name
    }

    /// Consumes the source, like `FileMediaStore`.
    func saveAudio(from url: URL) throws -> String {
        let name = MediaNaming.audio()
        files[name] = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return name
    }

    func url(for filename: String) -> URL {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(MediaNaming.sanitized(filename))
        if let data = files[filename] { try? data.write(to: url) }
        return url
    }

    func exists(_ filename: String) -> Bool { MediaNaming.isValid(filename) && files[filename] != nil }

    func delete(_ filename: String) {
        guard MediaNaming.isValid(filename) else { return }
        files[filename] = nil
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(filename))
    }

    /// Mirrors `FileMediaStore.write(_:to:)` so both stores save a photo the same way.
    private func write(_ data: Data, to filename: String) throws {
        files[filename] = data
    }
}

private struct MediaStoreKey: EnvironmentKey {
    static let defaultValue: MediaStore = FileMediaStore()
}

extension EnvironmentValues {
    var mediaStore: MediaStore {
        get { self[MediaStoreKey.self] }
        set { self[MediaStoreKey.self] = newValue }
    }
}
