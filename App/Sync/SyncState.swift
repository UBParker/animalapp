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

    var pushedThroughAt: [String: Date] = [:]
    var pullCursorAt: [String: Date] = [:]
    var pullOffsetAt: [String: Int] = [:]
    var status: SyncStatus = .never
    var lastSyncedAt: Date?

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

    static func load(defaults: UserDefaults = .standard) -> SyncState {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SyncState.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Who the local store belongs to. Written the moment a session is established, before any sync
/// runs, and kept under its own defaults key so clearing sync history never clears ownership and
/// vice versa.
struct StoreOwner: Codable, Equatable {
    static let defaultsKey = "animalTracker.storeOwner"

    var userID: String?
    var claimedAt: Date?

    static func load(defaults: UserDefaults = .standard) -> StoreOwner {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(StoreOwner.self, from: data) else { return StoreOwner() }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: StoreOwner.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
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
    static func decision(ownerID: String?, newUserID: UUID, storeIsEmpty: Bool) -> StoreOwnerDecision {
        let owner = (ownerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
