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

/// Where photos, videos, and audio live. Filenames are relative; the store owns the directory.
protocol MediaStore {
    func savePhoto(_ data: Data) throws -> SavedPhoto
    func saveVideo(from url: URL) throws -> String
    func saveAudio(from url: URL) throws -> String
    func url(for filename: String) -> URL
    func exists(_ filename: String) -> Bool
    func delete(_ filename: String)
}

enum MediaNaming {
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
        files[names.photo] = photo
        files[names.thumb] = thumb
        return SavedPhoto(filename: names.photo, thumbnailFilename: names.thumb)
    }

    func saveVideo(from url: URL) throws -> String {
        let name = MediaNaming.video()
        files[name] = try Data(contentsOf: url)
        return name
    }

    func saveAudio(from url: URL) throws -> String {
        let name = MediaNaming.audio()
        files[name] = try Data(contentsOf: url)
        return name
    }

    func url(for filename: String) -> URL {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(filename)
        if let data = files[filename] { try? data.write(to: url) }
        return url
    }

    func exists(_ filename: String) -> Bool { files[filename] != nil }

    func delete(_ filename: String) {
        files[filename] = nil
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent(filename))
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
