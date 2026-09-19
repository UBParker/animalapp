import Foundation

/// Files under Documents/Media/, visible in the Files app because Info.plist enables file sharing.
final class FileMediaStore: MediaStore {
    static let documentsMedia: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Media", isDirectory: true)
    }()

    let root: URL

    /// Test seam: called with the filename just before each write, so a test can make one fail.
    /// Deliberately not part of `MediaStore`.
    var writeHook: ((String) throws -> Void)?

    init(root: URL = FileMediaStore.documentsMedia) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func savePhoto(_ data: Data) throws -> SavedPhoto {
        guard let photo = ImageProcessing.downscaledJPEG(data), let thumb = ImageProcessing.thumbnailJPEG(data) else {
            throw MediaStoreError.invalidImage
        }
        let names = MediaNaming.photo()
        try write(photo, to: names.photo)
        do {
            try write(thumb, to: names.thumb)
        } catch {
            // Never leave a photo without its thumbnail in the user-visible Documents/Media folder.
            delete(names.photo)
            throw error
        }
        return SavedPhoto(filename: names.photo, thumbnailFilename: names.thumb)
    }

    func saveVideo(from url: URL) throws -> String {
        let name = MediaNaming.video()
        try copy(url, to: name)
        return name
    }

    func saveAudio(from url: URL) throws -> String {
        let name = MediaNaming.audio()
        try copy(url, to: name)
        return name
    }

    func url(for filename: String) -> URL { root.appendingPathComponent(filename) }

    func exists(_ filename: String) -> Bool { FileManager.default.fileExists(atPath: url(for: filename).path) }

    func delete(_ filename: String) { try? FileManager.default.removeItem(at: url(for: filename)) }

    private func write(_ data: Data, to filename: String) throws {
        do {
            try writeHook?(filename)
            try data.write(to: url(for: filename), options: .atomic)
        } catch {
            throw MediaStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func copy(_ src: URL, to filename: String) throws {
        do { try FileManager.default.copyItem(at: src, to: url(for: filename)) } catch { throw MediaStoreError.writeFailed(error.localizedDescription) }
    }
}
