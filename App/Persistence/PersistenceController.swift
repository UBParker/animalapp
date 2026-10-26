import Foundation
import OSLog
import SwiftData

enum PersistenceController {
    private static let log = Logger(subsystem: "com.ashlab.AnimalTracker", category: "persistence")

    /// Every @Model type in the app. Later plans append their models here.
    ///
    /// Anything added here has to be counted in `AppStoreLifecycle.storeIsEmpty()` as well. A model
    /// this list knows about and that function does not makes a store full of that model read as
    /// empty, which is `.claimEmpty`, which adopts it into the account signing in with no wipe and
    /// no watermark reset. `ContainerResetTests.testEveryModelTypeIsCountedByStoreIsEmpty` fails
    /// when the two lists drift (A7).
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
            // A url the caller chose may name a directory that does not exist yet, and
            // `ModelContainer` does not create one. The app now passes `storeURL` explicitly (A5),
            // and Application Support is not present in a fresh app container.
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        } else {
            config = ModelConfiguration(cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Deletes the store and its sidecars, and reports every path that is still on disk.
    ///
    /// Three unchecked `try?` is what made A1 possible: a `.store` file that would not unlink while
    /// its two sidecars went left an intact SQLite database at the path the wipe then reopened and
    /// published as a clean store. So every removal is checked and the three paths are read back.
    /// An empty return is the only evidence a caller may act on.
    ///
    /// Up to three passes, because a still-retained SQLite connection on an unlinked inode can
    /// recreate `-wal` or `-shm` on a checkpoint (documented in `ContainerResetTests` since this
    /// method was written). One late checkpoint must not read as a store that survived.
    @discardableResult
    static func destroy(url: URL? = nil) -> [URL] {
        var remaining = sidecars(of: url ?? storeURL)
        for pass in 1...3 {
            for file in remaining {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch CocoaError.fileNoSuchFile {
                    // Already gone, which is the end state this wants.
                } catch {
                    log.error("Pass \(pass, privacy: .public) could not remove \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            remaining = remaining.filter { FileManager.default.fileExists(atPath: $0.path) }
            if remaining.isEmpty { break }
        }
        return remaining
    }

    /// The store file and its two sidecars. Public so a test can assert a wipe left nothing.
    static func storeURLs(url: URL? = nil) -> [URL] {
        sidecars(of: url ?? storeURL)
    }

    /// `destroy` plus every `<name>.corrupt-<timestamp>` copy `moveAside` left behind. Sign-out and
    /// a user change have to use this one: a recovered copy is a complete copy of the previous
    /// person's records sitting next to the live store.
    @discardableResult
    static func destroyIncludingRecoveredCopies(url: URL? = nil) -> [URL] {
        let target = url ?? storeURL
        var remaining = destroy(url: target)
        let directory = target.deletingLastPathComponent()
        let base = target.lastPathComponent
        func recoveredCopies() -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.hasPrefix(base) && $0.contains(".corrupt-") }
                .map { directory.appending(path: $0) }
        }
        for copy in recoveredCopies() {
            do {
                try FileManager.default.removeItem(at: copy)
            } catch {
                log.error("Could not remove \(copy.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Read back, like the store itself: a recovered copy is a complete copy of the previous
        // person's records, so one left behind is the same failure as a store left behind.
        remaining += recoveredCopies()
        return remaining
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
