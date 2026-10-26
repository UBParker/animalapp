import Foundation
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

/// Owns the live `ModelContainer` and replaces it when the store has to be thrown away.
/// `AuthService` drives it through `StoreLifecycle`; the app observes `generation` so every
/// `@Query` re-subscribes to the new container.
@MainActor
final class AppStoreLifecycle: ObservableObject, StoreLifecycle {
    @Published private(set) var container: ModelContainer
    /// Bumped with the container, used as the tab content's `.id(...)`.
    @Published private(set) var generation = 0
    /// True when even the recovery path failed and this launch is on a temporary store.
    let recovered: Bool

    /// Set by the app once `SyncService` exists. Nil is a valid state: before Task 11 there is no
    /// sync, and a wipe still has to work.
    var sync: (any SyncCoordinating)?

    private let mediaStore: MediaStore
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

    func wipeStore() async {
        // Belt and braces: AuthService already cancelled, but a wipe must never race a writer.
        await sync?.cancelSync()
        PersistenceController.destroyIncludingRecoveredCopies(url: storeURL)
        // The rows are only half the person's data. Documents/Media/ holds the audio, the photos,
        // the thumbnails and the videos, and file sharing makes that folder browsable in the Files
        // app, so leaving it behind would show the previous person's recordings to the next one and
        // would make "Delete account" a lie on the device (verification defect D-D6). `try?`: a
        // wipe that cannot reopen the store is a worse failure than one file that would not unlink,
        // and the directory is recreated by `removeAll` either way.
        try? mediaStore.removeAll()
        let opened = PersistenceController.makeContainerWithRecovery(url: storeURL)
        container = opened.container
        generation += 1
        // `Seeds.runAll` runs every entry of `Seeds.all`, including `VoiceTagSeed.run`, which
        // seeds on every call: Plan B's fix wave removed
        // the once-per-install UserDefaults guard precisely so a store recreated after a wipe still
        // gets its built-in tags. The ids are deterministic, so a later pull of the same tags merges
        // onto these rows instead of doubling them.
        Seeds.runAll(context: container.mainContext)
        sync?.attach(container: container, mediaStore: mediaStore)
    }

    func configureSync(for state: AuthState, client: SupabaseClient?) {
        sync?.update(for: state, client: client)
    }
}
