import Foundation
import OSLog
import SwiftData
import Supabase

/// What the store lifecycle needs from sync. Declared here rather than in `SyncService` so the
/// lifecycle can be built and tested before sync exists; Task 11's `SyncService` conforms to it and
/// the app assigns it to `AppStoreLifecycle.sync` at launch.
@MainActor
protocol SyncCoordinating: AnyObject {
    /// Stops the running sync and does not return until it has actually stopped.
    func cancelSync() async
    /// Points sync at the live container.
    func attach(container: ModelContainer, mediaStore: MediaStore)
    /// Points sync at this auth state's user and client, or at nothing.
    func update(for state: AuthState, client: SupabaseClient?)
    /// One last push before the store is destroyed. Returns true only when the cycle finished and
    /// left nothing outstanding; false on any failure, on cancellation, and on the timeout.
    /// Bounded so a dead network cannot leave the person staring at a spinner on a sign-out.
    func pushBeforeSignOut(timeout: TimeInterval) async -> Bool
    /// Rows whose `updatedAt` is newer than their table's push watermark, plus unpushed
    /// tombstones. What the second sign-out confirmation puts a number to.
    func unsyncedRowCount() -> Int
}

/// What a wipe actually managed to do, read back from the filesystem rather than assumed.
///
/// RULING 1 and RULING 2: the wipe reopens the store at the same path, so an unverified destroy is
/// not a wipe. A `.store` file that survives the unlink while its sidecars go is an intact SQLite
/// database, and reopening it would hand the previous person's records to whoever signs in next.
enum WipeOutcome: Equatable {
    /// Store, recovered copies and media root all verified gone, and a fresh store is published.
    case wiped
    /// At least one store file is still on disk. Nothing was republished: the container the UI
    /// already had is still the live one, and it still holds the previous person's records.
    case storeSurvived
    /// The store went and a fresh one is published, but the media root did not come back empty.
    /// The same class of failure as `storeSurvived`, because the files are half the person's data.
    case mediaSurvived
}

/// Owns the live `ModelContainer` and replaces it when the store has to be thrown away.
/// `AuthService` drives it through `StoreLifecycle`; the app observes `generation` so every
/// `@Query` re-subscribes to the new container.
@MainActor
final class AppStoreLifecycle: ObservableObject, StoreLifecycle {
    private static let log = Logger(subsystem: "com.ashlab.AnimalTracker", category: "storeLifecycle")

    @Published private(set) var container: ModelContainer
    /// Bumped with the container, used as the tab content's `.id(...)`.
    @Published private(set) var generation = 0
    /// True when even the recovery path failed and this store is a temporary one that loses
    /// everything at process exit.
    ///
    /// Published and reassigned by every wipe, not a launch-time `let`. It drives the only warning
    /// the person gets, and a wipe whose reopen falls through to the in-memory last resort is
    /// exactly when that warning matters: without this the app looks fine and discards everything
    /// recorded afterwards (A2). The inverse matters too, so a launch that recovered stops warning
    /// once a wipe has opened a real store on disk.
    @Published private(set) var recovered: Bool

    /// Set by the app once `SyncService` exists. Nil is a valid state: before Task 11 there is no
    /// sync, and a wipe still has to work.
    var sync: (any SyncCoordinating)?

    /// Internal rather than private so `AnimalTrackerApp` can put this exact instance into
    /// `\.mediaStore`. One object, one root: the lifecycle wipes the directory the views read and
    /// write, and after Task 11 the same instance is what `sync?.attach` is handed. Two instances
    /// agreeing by convention is a wipe that misses live files as soon as anybody injects one of
    /// them and not the other.
    let mediaStore: MediaStore
    private let storeURL: URL?

    init(container: ModelContainer,
         recovered: Bool,
         mediaStore: MediaStore = FileMediaStore(),
         storeURL: URL? = nil) {
        self.container = container
        self.recovered = recovered
        self.mediaStore = mediaStore
        self.storeURL = storeURL
    }

    // MARK: StoreLifecycle

    func cancelSync() async {
        await sync?.cancelSync()
    }

    /// "Empty" means no records the person made. The built-in voice tags are seeded on every
    /// launch, so a store holding only those is still a fresh store; counting them would make
    /// every fresh install look like data worth refusing to adopt.
    /// Throws rather than guessing. A fetch that fails must never read as "empty": the caller
    /// turns `true` into `.claimEmpty`, which adopts the store into the account signing in, with
    /// no wipe and no watermark reset. Four `try?` fetches would turn four failures into four
    /// zeros into exactly that adoption, which is the inversion of the fail-closed rule the
    /// caller is tested for. The caller collapses a throw with `(try? ...) ?? false`.
    func storeIsEmpty() throws -> Bool {
        let context = container.mainContext
        let animals = try context.fetchCount(FetchDescriptor<Animal>())
        let recordings = try context.fetchCount(FetchDescriptor<VoiceRecording>())
        let vocalizations = try context.fetchCount(FetchDescriptor<Vocalization>())
        let ownTags = try context.fetch(FetchDescriptor<VoiceTag>()).filter { !$0.isBuiltIn }.count
        return animals == 0 && recordings == 0 && vocalizations == 0 && ownTags == 0
    }

    func wipeStore() async -> WipeOutcome {
        // Belt and braces: AuthService already cancelled, but a wipe must never race a writer.
        await sync?.cancelSync()
        // RULING 1. The destroy now reports what it could not remove, and the three store paths
        // are read back, because the reopen below targets the same path. A `.store` file that
        // survived the unlink while its sidecars went is a complete SQLite database: reopening it
        // and publishing it as a clean store is how one person's animals, recordings and audio get
        // adopted into the next person's account. `storeURLs(url:)` carries the doc comment
        // "Public so a test can assert a wipe left nothing"; this is the production path asserting
        // the same thing.
        let storeLeftOnDisk = PersistenceController.destroyIncludingRecoveredCopies(url: storeURL)
        guard storeLeftOnDisk.isEmpty else {
            AppStoreLifecycle.log.error("Wipe refused, these files survived the destroy: \(storeLeftOnDisk.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
            // Nothing is republished and `generation` does not move, so the UI keeps the container
            // it already had and nothing new is shown to anybody. The caller keeps its
            // `PendingTeardown` marker set and refuses to establish: "signed out, your data is
            // still on this device, we could not finish this" is the only safe state here.
            return .storeSurvived
        }
        // RULING 2. The rows are only half the person's data. Documents/Media/ holds the audio, the
        // photos, the thumbnails and the videos, and file sharing makes that folder browsable in
        // the Files app, so leaving it behind would show the previous person's recordings to the
        // next one and would make "Delete account" a lie on the device (verification defect D-D6).
        // The error is captured rather than discarded, because a leftover there is the same class
        // of failure as a store left behind. It must not abort the reopen though: an app that
        // cannot open its store because one file would not unlink is the worse failure.
        _ = removeMediaAndReportLeftovers(stage: "before the reopen")
        let opened = PersistenceController.makeContainerWithRecovery(url: storeURL)
        container = opened.container
        // A2. The reopen's own verdict, not the one this object was built with: `recovered` is true
        // only for the in-memory last resort, which is exactly the outcome a just-failed destroy
        // makes more likely, and it is the only warning the person gets.
        recovered = opened.recovered
        generation += 1
        // `Seeds.runAll` runs every entry of `Seeds.all`, including `VoiceTagSeed.run`, which
        // seeds on every call: Plan B's fix wave removed
        // the once-per-install UserDefaults guard precisely so a store recreated after a wipe still
        // gets its built-in tags. The ids are deterministic, so a later pull of the same tags merges
        // onto these rows instead of doubling them.
        Seeds.runAll(context: container.mainContext)
        // RULING 3, and this is deliberately the last step rather than the first. `cancelSync()`
        // does not stop every writer: `RecordView.finish()` and `AskView.finish()` each run a bare
        // `Task` that view teardown does not cancel, and it writes audio through
        // `mediaStore.saveAudio(from:)` before inserting its row. Signing out mid-analysis sends
        // the row to the dead container, where it is discarded, while the file lands in the media
        // directory that was just recreated and survives for the next person, with no filesystem
        // error anywhere. After the reseed the store holds nothing but built-in tags, so every file
        // in the media root is orphaned by definition and removing them again is correct rather
        // than destructive. A writer slower than this still wins, which is why the reconciliation
        // is here, at the latest point in the wipe, and not before the reopen.
        let mediaLeftBehind = removeMediaAndReportLeftovers(stage: "after the reseed")
        sync?.attach(container: container, mediaStore: mediaStore)
        return mediaLeftBehind.isEmpty ? .wiped : .mediaSurvived
    }

    /// Removes everything the media store holds and reports what is still there afterwards.
    ///
    /// Fail closed on both halves: a removal that threw is not trusted, and a root that cannot
    /// even be listed counts as not empty rather than as clean.
    private func removeMediaAndReportLeftovers(stage: String) -> [String] {
        do {
            try mediaStore.removeAll()
        } catch {
            AppStoreLifecycle.log.error("Media removal \(stage, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        do {
            let left = try mediaStore.contents()
            if !left.isEmpty {
                AppStoreLifecycle.log.error("Media root not empty \(stage, privacy: .public): \(left.joined(separator: ", "), privacy: .public)")
            }
            return left
        } catch {
            AppStoreLifecycle.log.error("Could not list the media root \(stage, privacy: .public): \(String(describing: error), privacy: .public)")
            return ["the media root could not be listed"]
        }
    }

    func configureSync(for state: AuthState, client: SupabaseClient?) {
        sync?.update(for: state, client: client)
    }
}
