import Foundation
import OSLog
import SwiftData

enum PersistenceController {
    private static let log = Logger(subsystem: "com.ashlab.AnimalTracker", category: "persistence")

    /// Every @Model type in the app. Later plans append their models here.
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        VoiceRecording.self,
        Vocalization.self,
        VoiceTag.self,
    ]

    static var schema: Schema { Schema(modelTypes) }

    /// Where SwiftData puts the default store when no url is given.
    static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }

    /// SQLite keeps two sidecar files next to the store; all three move or go together.
    private static func sidecars(of url: URL) -> [URL] {
        [url,
         url.deletingLastPathComponent().appending(path: url.lastPathComponent + "-shm"),
         url.deletingLastPathComponent().appending(path: url.lastPathComponent + "-wal")]
    }

    /// Local-only store. No CloudKit, by design (spec ruling 1).
    static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let url {
            config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Deletes the store and its sidecars. Used by tests and by a future "reset data" action.
    static func destroy(url: URL? = nil) {
        for file in sidecars(of: url ?? storeURL) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The store file and its two sidecars. Public so a test can assert a wipe left nothing.
    static func storeURLs(url: URL? = nil) -> [URL] {
        sidecars(of: url ?? storeURL)
    }

    /// `destroy` plus every `<name>.corrupt-<timestamp>` copy `moveAside` left behind. Sign-out and
    /// a user change have to use this one: a recovered copy is a complete copy of the previous
    /// person's records sitting next to the live store.
    static func destroyIncludingRecoveredCopies(url: URL? = nil) {
        let target = url ?? storeURL
        destroy(url: target)
        let directory = target.deletingLastPathComponent()
        let base = target.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(base) && name.contains(".corrupt-") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Opens the store, and if it cannot be opened moves it aside and starts a fresh one rather
    /// than killing the app at launch. `recovered` is true only when even that fails and the app
    /// is running on a throwaway in-memory store, which is what the launch banner warns about.
    static func makeContainerWithRecovery(url: URL? = nil) -> (container: ModelContainer, recovered: Bool) {
        do {
            return (try makeContainer(url: url), false)
        } catch {
            log.error("Could not open the data store: \(String(describing: error), privacy: .public)")
            moveAside(url ?? storeURL)
        }
        do {
            return (try makeContainer(url: url), false)
        } catch {
            log.error("Could not open a fresh data store either: \(String(describing: error), privacy: .public)")
            // Last resort: a store that works for this launch, so the app opens at all.
            // An in-memory container can only fail if the schema itself is invalid, which is a
            // build-time bug, not something a user's device can cause.
            return (try! makeContainer(inMemory: true), true)
        }
    }

    /// Renames the store and its sidecars to `<name>.corrupt-<timestamp>` in the same directory,
    /// so the bytes stay on disk for support instead of being destroyed.
    private static func moveAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        for file in sidecars(of: url) where FileManager.default.fileExists(atPath: file.path) {
            let target = file.deletingLastPathComponent()
                .appending(path: "\(file.lastPathComponent).corrupt-\(stamp)")
            do {
                try FileManager.default.moveItem(at: file, to: target)
                log.notice("Moved \(file.lastPathComponent, privacy: .public) aside to \(target.lastPathComponent, privacy: .public)")
            } catch {
                log.error("Could not move \(file.lastPathComponent, privacy: .public) aside: \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
