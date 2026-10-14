import Foundation

/// The four synced tables. The raw value is the Postgres table name.
enum SyncTable: String, CaseIterable {
    case animals = "animals"
    case voiceRecordings = "voice_recordings"
    case vocalizations = "vocalizations"
    case voiceTags = "voice_tags"
}

/// Postgres functions this app calls by name. One constant per name, so the Swift side and the
/// migration cannot drift apart without `MigrationFileTests` failing.
enum ServerFunctions {
    static let deleteMyAccount = "delete_my_account"
}

/// Thrown by the engine when the sync generation it started under is no longer current.
struct SyncCancelled: Error {}

/// What Settings shows. Deliberately a small closed set: a raw server message can carry a token, a
/// row id or a table name, and it would be persisted to UserDefaults and shown on screen.
enum SyncStatus: String, Codable, Equatable, CaseIterable {
    case never
    case idle
    case syncing
    case offline
    case notSignedIn
    case cancelled
    case failedNetwork
    case failedServer
    case failedLocal

    var text: String {
        switch self {
        case .never: return "Never synced"
        case .idle: return "Synced"
        case .syncing: return "Syncing"
        case .offline: return "Offline. Records stay on this phone."
        case .notSignedIn: return "Not signed in"
        case .cancelled: return "Sync stopped"
        case .failedNetwork: return "Sync failed. No connection."
        case .failedServer: return "Sync failed. The server rejected the change."
        case .failedLocal: return "Sync failed. Could not read or write on this phone."
        }
    }

    /// Tolerant decode. A raw value written by a newer build and read back by an older one (a
    /// TestFlight rollback, a staged release, a phone restored from a newer backup) must not
    /// throw: `status` shares one blob with every watermark, so a single unrecognised string
    /// would otherwise take the whole of `SyncState` down with it and re-push and re-pull the
    /// entire store. An unknown status is a cosmetic loss; a lost watermark is not.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncStatus(rawValue: raw) ?? .never
    }

    /// Maps an error to a category without ever keeping its text.
    static func category(for error: any Error) -> SyncStatus {
        if error is SyncCancelled || error is CancellationError { return .cancelled }
        if error is URLError { return .failedNetwork }
        if error is MediaStoreError { return .failedLocal }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .failedNetwork }
        if nsError.domain == NSCocoaErrorDomain { return .failedLocal }
        return .failedServer
    }
}

/// Watermark arithmetic, kept in one place so the clock-skew rule is testable.
enum SyncClock {
    /// A watermark never runs ahead of the device's own clock. One row accidentally dated years in
    /// the future would otherwise suppress every later push.
    static func clamp(_ date: Date, notAfter now: Date) -> Date { min(date, now) }

    /// The highest of `dates`, never below `floor` and never after `now`.
    static func highest(of dates: [Date], floor: Date, notAfter now: Date) -> Date {
        let candidate = dates.max() ?? floor
        return clamp(max(candidate, floor), notAfter: now)
    }
}

/// Sync bookkeeping. Small enough to live in UserDefaults as one JSON blob, and deliberately not in
/// SwiftData, because wiping the store must not wipe the record of how far sync got.
///
/// Two different kinds of watermark, on two different clocks:
/// - `pushedThroughAt` is the device's own `updatedAt` high-water mark per table. Anything newer is
///   outstanding and gets pushed.
/// - `pullCursorAt` plus `pullOffsetAt` is the server's `server_updated_at` cursor per table, with
///   the number of rows already consumed at exactly that timestamp, so a page boundary that lands
///   inside a group of rows sharing one timestamp resumes correctly.
struct SyncState: Codable, Equatable {
    static let defaultsKey = "animalTracker.syncState"
    /// The watermark for "never pulled" and "never pushed".
    static let epoch = Date(timeIntervalSince1970: 0)
    /// Rows requested per pull page.
    static let pageLimit = 500
    /// Audio files uploaded per sync cycle, so one cycle cannot hold the app on a slow link.
    static let audioUploadsPerCycle = 10
    /// The shape of the stored blob. Every field is decoded with `decodeIfPresent` and a default,
    /// so adding or dropping one stays additive on its own; this number exists for the change that
    /// cannot be expressed that way, so the migration can be deliberate instead of a decode
    /// failure. Bump it when the meaning of an existing field changes.
    static let currentSchemaVersion = 1

    var pushedThroughAt: [String: Date] = [:]
    var pullCursorAt: [String: Date] = [:]
    /// How many rows at exactly `pullCursorAt` have already been consumed.
    ///
    /// Load bearing, and only meaningful under a total order: the pull query must be
    /// `ORDER BY (server_updated_at, id)`, which is what Task 11 asks for and Task 6 indexes.
    /// Postgres defaults `server_updated_at` to the transaction timestamp, so a bulk import of
    /// more than one page's worth of rows carries one identical stamp across all of them, and
    /// offset paging inside that tie group is the only way through it. `SyncState` carries no
    /// tiebreak id of its own, so if the `id` ordering is ever dropped there is no stable order
    /// inside a tie group and paging silently skips and duplicates rows.
    var pullOffsetAt: [String: Int] = [:]
    var status: SyncStatus = .never
    var lastSyncedAt: Date?
    /// The version this blob was written under, reported as stored rather than overwritten, so a
    /// reader can tell an old blob from a new one.
    var schemaVersion: Int = SyncState.currentSchemaVersion

    enum CodingKeys: String, CodingKey {
        case pushedThroughAt
        case pullCursorAt
        case pullOffsetAt
        case status
        case lastSyncedAt
        case schemaVersion
    }

    func pushedThrough(_ table: SyncTable) -> Date { pushedThroughAt[table.rawValue] ?? SyncState.epoch }
    func pullCursor(_ table: SyncTable) -> Date { pullCursorAt[table.rawValue] ?? SyncState.epoch }
    func pullOffset(_ table: SyncTable) -> Int { pullOffsetAt[table.rawValue] ?? 0 }

    mutating func setPushedThrough(_ table: SyncTable, _ date: Date) {
        pushedThroughAt[table.rawValue] = date
    }

    mutating func setPullCursor(_ table: SyncTable, _ date: Date, offset: Int) {
        pullCursorAt[table.rawValue] = date
        pullOffsetAt[table.rawValue] = offset
    }

    /// Forgets how far sync got, so the next cycle pushes and pulls everything from scratch.
    /// Does not touch `StoreOwner`, which lives under its own key.
    mutating func forgetSyncHistory() {
        pushedThroughAt = [:]
        pullCursorAt = [:]
        pullOffsetAt = [:]
        status = .never
        lastSyncedAt = nil
    }

    /// A blob that cannot be read at all falls back to a fresh state, which costs bandwidth and
    /// nothing else: the server's last-write-wins trigger makes a re-push idempotent, so the only
    /// price is re-walking the tables from the epoch. It is not a wipe, and unlike `StoreOwner`
    /// below there is no destructive decision downstream of it. `load` never removes the blob it
    /// could not read, so the raw bytes stay under the key and can be inspected or recovered.
    static func load(defaults: UserDefaults = .standard) -> SyncState {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return decoded
    }

    /// Deliberately a bare `JSONEncoder`, not `SyncCoding.encoder`. Local persistence and the wire
    /// are two different jobs: this writes dates as raw `timeIntervalSinceReferenceDate` doubles,
    /// which round-trip exactly, while `SyncCoding` writes ISO 8601 at millisecond resolution for
    /// PostgREST. Do not unify them for consistency. Swapping `SyncCoding.encoder` in here would
    /// change the stored shape under every existing install and would quantize every watermark to
    /// the millisecond, which is exactly the rounding hazard `SyncCoding`'s header warns about.
    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SyncState.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Decoded field by field with `decodeIfPresent` rather than by the synthesized `init(from:)`.
/// The synthesized one calls `decode` for every non-optional property and ignores its default
/// value, so adding a single non-optional field, even one with a default, makes every blob an
/// existing install already wrote undecodable. That is the most likely mistake a later change can
/// make, because the default value makes the change look additive, and in `StoreOwner`'s case the
/// consequence was a wiped store.
extension SyncState {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pushedThroughAt: try container.decodeIfPresent([String: Date].self, forKey: .pushedThroughAt) ?? [:],
            pullCursorAt: try container.decodeIfPresent([String: Date].self, forKey: .pullCursorAt) ?? [:],
            pullOffsetAt: try container.decodeIfPresent([String: Int].self, forKey: .pullOffsetAt) ?? [:],
            status: try container.decodeIfPresent(SyncStatus.self, forKey: .status) ?? .never,
            lastSyncedAt: try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? SyncState.currentSchemaVersion)
    }
}

/// Who the local store belongs to. Written the moment a session is established, before any sync
/// runs, and kept under its own defaults key so clearing sync history never clears ownership and
/// vice versa.
struct StoreOwner: Codable, Equatable {
    static let defaultsKey = "animalTracker.storeOwner"
    /// See `SyncState.currentSchemaVersion`.
    static let currentSchemaVersion = 1

    /// The `userID` `load` reports when a record is there but cannot be read. Not a UUID, so it
    /// can never collide with a real owner id, and `StoreOwnerPolicy` recognises it rather than
    /// treating it as an owner who matches nobody. It exists so the existing one-argument
    /// `decision(ownerID:newUserID:storeIsEmpty:)` call path is safe without its caller having to
    /// change; a caller that can see `LoadOutcome` should use that instead.
    static let unreadableOwnerID = "animalTracker.storeOwner.unreadable"

    /// How the stored record read. Three outcomes, kept apart on purpose: collapsing `unreadable`
    /// into `absent` is what turned a corrupt sidecar into a store wipe.
    enum LoadOutcome: Equatable {
        /// No record at all. A fresh install, or after `clear`.
        case absent
        /// A record that read cleanly.
        case decoded(StoreOwner)
        /// A record is there and this build cannot read it. A fault, never a fresh install.
        case unreadable
    }

    var userID: String?
    var claimedAt: Date?
    /// See `SyncState.schemaVersion`.
    var schemaVersion: Int = StoreOwner.currentSchemaVersion

    enum CodingKeys: String, CodingKey {
        case userID
        case claimedAt
        case schemaVersion
    }

    static func loadOutcome(defaults: UserDefaults = .standard) -> LoadOutcome {
        guard let data = defaults.data(forKey: defaultsKey) else { return .absent }
        guard let decoded = try? JSONDecoder().decode(StoreOwner.self, from: data) else { return .unreadable }
        return .decoded(decoded)
    }

    /// Absent reads as a fresh, unowned store. Unreadable reads as `unreadableOwnerID`, which is
    /// not nil and not a user id, so the policy can tell the two apart.
    static func load(defaults: UserDefaults = .standard) -> StoreOwner {
        switch loadOutcome(defaults: defaults) {
        case .absent: return StoreOwner()
        case .decoded(let owner): return owner
        case .unreadable: return StoreOwner(userID: unreadableOwnerID)
        }
    }

    func save(defaults: UserDefaults = .standard) {
        // The unreadable marker is a signal `load` produces, never an owner. Persisting it would
        // turn a soft fault into a stored owner id that matches no user, which is a wipe on the
        // next sign-in. Refusing also leaves the unreadable bytes in place to be inspected.
        guard userID != StoreOwner.unreadableOwnerID else { return }
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: StoreOwner.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// See the note on `SyncState`'s decoder: every field decodes with `decodeIfPresent` and a
/// default, so a field added later cannot make an existing install's record unreadable.
extension StoreOwner {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            userID: try container.decodeIfPresent(String.self, forKey: .userID),
            claimedAt: try container.decodeIfPresent(Date.self, forKey: .claimedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? StoreOwner.currentSchemaVersion)
    }
}

enum StoreOwnerDecision: Equatable {
    /// Same person as last time: keep the store and the watermarks.
    case keep
    /// Nobody owns this store and there is nothing in it: keep the empty store, start the
    /// watermarks from scratch. This is the fresh-install-with-a-keychain-session case.
    case claimEmpty
    /// Wipe the store and the watermarks before this person sees anything.
    case reset
}

/// One person's animals must never appear under another person's account on the same phone, and
/// data created offline or before sign-in is never silently adopted into an account.
enum StoreOwnerPolicy {
    /// The explicit entry point. Prefer it: it cannot confuse "no record" with "a record this
    /// build cannot read", which is the distinction the one-argument form has to encode in a
    /// sentinel.
    static func decision(ownership: StoreOwner.LoadOutcome,
                         newUserID: UUID,
                         storeIsEmpty: Bool) -> StoreOwnerDecision {
        switch ownership {
        case .absent:
            return decision(ownerID: nil, newUserID: newUserID, storeIsEmpty: storeIsEmpty)
        case .decoded(let owner):
            return decision(ownerID: owner.userID, newUserID: newUserID, storeIsEmpty: storeIsEmpty)
        case .unreadable:
            return .keep
        }
    }

    static func decision(ownerID: String?, newUserID: UUID, storeIsEmpty: Bool) -> StoreOwnerDecision {
        let owner = (ownerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An ownership record that is present but unreadable is not the same as no owner, and it
        // must never reach `.reset`.
        //
        // `.reset` wipes the local store, and on the sign-in path it does so with no dialog, so
        // every row that had not reached the server yet is gone for good. The realistic causes of
        // an unreadable record are all benign to ownership and fatal to data: a truncated or
        // corrupt blob in UserDefaults, or a blob written by a different build. In every one of
        // them the person signing in is the person whose rows are in the store.
        //
        // Keeping does not hand the store to a stranger. The caller writes a fresh ownership
        // claim for the signing-in user immediately after this decision, so from that moment the
        // record is readable again and names a real user; the next sign-in by anybody else reads
        // it, fails the match below, and resets before they see a thing. The exposure is a single
        // sign-in by someone who already holds the unlocked phone, against the certainty of
        // silent data loss for the legitimate owner.
        //
        // The empty cases below stay `.reset`: no record at all means data that was created
        // before sign-in or offline, which is never adopted into an account.
        if owner == StoreOwner.unreadableOwnerID { return .keep }
        if owner.isEmpty {
            return storeIsEmpty ? .claimEmpty : .reset
        }
        return owner.caseInsensitiveCompare(newUserID.uuidString) == .orderedSame ? .keep : .reset
    }
}

/// How many local rows have not reached the server yet.
///
/// Sign-out wipes the store, so the person has to be told what that costs before they confirm it
/// (verification defect D-D7). "Outstanding" has exactly the meaning the push watermark gives it:
/// a row is outstanding when its `updatedAt` is strictly newer than `pushedThrough` for its table,
/// which is the same `>` the engine's own `changed*(after:)` uses, plus every tombstone still
/// waiting to be pushed.
///
/// Pure on purpose. It takes dates and a count rather than a store, so the arithmetic that decides
/// what a destructive dialog says is unit-tested without SwiftData, a container or a network.
enum UnsyncedCount {
    static func count(updatedAtByTable: [SyncTable: [Date]],
                      pendingTombstones: Int,
                      state: SyncState) -> Int {
        let rows = updatedAtByTable.reduce(0) { total, entry in
            let watermark = state.pushedThrough(entry.key)
            return total + entry.value.filter { $0 > watermark }.count
        }
        return rows + pendingTombstones
    }
}
