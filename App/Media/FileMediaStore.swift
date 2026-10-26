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

    /// Consumes the source: the file is copied in and then removed from its old location.
    func saveVideo(from url: URL) throws -> String {
        let name = MediaNaming.video()
        try consume(url, to: name)
        return name
    }

    /// Consumes the source: the file is copied in and then removed from its old location.
    func saveAudio(from url: URL) throws -> String {
        let name = MediaNaming.audio()
        try consume(url, to: name)
        return name
    }

    /// A name that is not a single path component resolves to a throwaway name inside `root`,
    /// so a bad filename can never reach a file outside the store.
    func url(for filename: String) -> URL { root.appendingPathComponent(MediaNaming.sanitized(filename)) }

    func exists(_ filename: String) -> Bool {
        MediaNaming.isValid(filename) && FileManager.default.fileExists(atPath: url(for: filename).path)
    }

    func delete(_ filename: String) {
        guard MediaNaming.isValid(filename) else { return }
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: root)
        } catch CocoaError.fileNoSuchFile {
            // Already gone. Recreating below is still the right end state.
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ data: Data, to filename: String) throws {
        do {
            try writeHook?(filename)
            try data.write(to: url(for: filename), options: .atomic)
        } catch {
            throw MediaStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Copy then remove rather than moveItem: the source is often a security-scoped or
    /// cross-volume temp file, where a copy succeeds and a move does not.
    private func consume(_ src: URL, to filename: String) throws {
        do { try FileManager.default.copyItem(at: src, to: url(for: filename)) } catch { throw MediaStoreError.writeFailed(error.localizedDescription) }
        try? FileManager.default.removeItem(at: src)
    }
}
