import XCTest
@testable import AnimalTracker

final class SyncStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncStateTests-\(UUID().uuidString)"))
    }

    func testServerFunctionNamesAreTheOnesTheMigrationDefines() {
        // MigrationFileTests asserts the other half: that the SQL defines exactly this name.
        XCTAssertEqual(ServerFunctions.deleteMyAccount, "delete_my_account")
    }

    func testTableRawValuesMatchTheServerTableNames() {
        XCTAssertEqual(SyncTable.animals.rawValue, "animals")
        XCTAssertEqual(SyncTable.voiceRecordings.rawValue, "voice_recordings")
        XCTAssertEqual(SyncTable.vocalizations.rawValue, "vocalizations")
        XCTAssertEqual(SyncTable.voiceTags.rawValue, "voice_tags")
        XCTAssertEqual(SyncTable.allCases.count, 4)
    }

    func testUnsetWatermarksAreTheEpoch() {
        let state = SyncState()
        XCTAssertEqual(state.pushedThrough(.animals), SyncState.epoch)
        XCTAssertEqual(state.pullCursor(.voiceTags), SyncState.epoch)
        XCTAssertEqual(state.pullOffset(.voiceTags), 0)
    }

    func testWatermarksAndCursorsRoundTripThroughUserDefaults() {
        var state = SyncState()
        let pushed = Date(timeIntervalSince1970: 1_750_000_500.25)
        let cursor = Date(timeIntervalSince1970: 1_750_000_900.5)
        state.setPushedThrough(.animals, pushed)
        state.setPullCursor(.vocalizations, cursor, offset: 7)
        state.status = .idle
        state.lastSyncedAt = pushed
        state.save(defaults: defaults)

        let loaded = SyncState.load(defaults: defaults)
        XCTAssertEqual(loaded.pushedThrough(.animals).timeIntervalSince1970, pushed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.pullCursor(.vocalizations).timeIntervalSince1970, cursor.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.pullOffset(.vocalizations), 7)
        XCTAssertEqual(loaded.pullCursor(.animals), SyncState.epoch)
        XCTAssertEqual(loaded.status, .idle)
    }

    func testLoadOnEmptyDefaultsReturnsAFreshState() {
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
    }

    func testForgetSyncHistoryClearsEveryWatermarkAndCursor() {
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 1_750_000_000))
        state.setPullCursor(.animals, Date(timeIntervalSince1970: 1_750_000_000), offset: 4)
        state.status = .idle
        state.lastSyncedAt = Date()
        state.forgetSyncHistory()
        XCTAssertEqual(state.pushedThrough(.animals), SyncState.epoch)
        XCTAssertEqual(state.pullCursor(.animals), SyncState.epoch)
        XCTAssertEqual(state.pullOffset(.animals), 0)
        XCTAssertEqual(state.status, .never)
        XCTAssertNil(state.lastSyncedAt)
    }

    func testClearRemovesTheStoredBlobEntirely() {
        var state = SyncState()
        state.status = .idle
        state.save(defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: SyncState.defaultsKey))
        SyncState.clear(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: SyncState.defaultsKey))
    }

    /// Sync bookkeeping and store ownership are two different keys, because wiping the store on a
    /// user change must not take the record of who owns the store with it.
    func testStoreOwnerIsStoredUnderItsOwnKey() {
        XCTAssertNotEqual(StoreOwner.defaultsKey, SyncState.defaultsKey)
        let owner = StoreOwner(userID: "11111111-1111-1111-1111-111111111111", claimedAt: Date(timeIntervalSince1970: 10))
        owner.save(defaults: defaults)
        var state = SyncState()
        state.forgetSyncHistory()
        state.save(defaults: defaults)
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, "11111111-1111-1111-1111-111111111111")
        StoreOwner.clear(defaults: defaults)
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
    }

    func testStoreOwnerPolicyKeepsTheStoreForTheSameUser() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: a.uuidString, newUserID: a, storeIsEmpty: false), .keep)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: a.uuidString.lowercased(), newUserID: a, storeIsEmpty: true), .keep)
    }

    func testStoreOwnerPolicyResetsForADifferentUser() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let b = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: b.uuidString, newUserID: a, storeIsEmpty: false), .reset)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: b.uuidString, newUserID: a, storeIsEmpty: true), .reset)
    }

    /// Offline or pre-auth data is never adopted into an account.
    func testStoreOwnerPolicyResetsUnownedDataThatIsNotEmpty() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: nil, newUserID: a, storeIsEmpty: false), .reset)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: "", newUserID: a, storeIsEmpty: false), .reset)
    }

    /// The fresh-install case: a session survives in the keychain, the store is empty and there is
    /// no owner. Nothing to wipe, but the watermarks must start from scratch, which is what
    /// `claimEmpty` tells AuthService to do.
    func testStoreOwnerPolicyClaimsAnEmptyUnownedStore() {
        let a = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: nil, newUserID: a, storeIsEmpty: true), .claimEmpty)
    }

    func testClampNeverLetsAWatermarkRunAheadOfTheDeviceClock() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SyncClock.clamp(Date(timeIntervalSince1970: 9_999), notAfter: now), now)
        XCTAssertEqual(SyncClock.clamp(Date(timeIntervalSince1970: 500), notAfter: now),
                       Date(timeIntervalSince1970: 500))
    }

    func testHighestFallsBackToTheFloorAndClamps() {
        let now = Date(timeIntervalSince1970: 1_000)
        let floor = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(SyncClock.highest(of: [], floor: floor, notAfter: now), floor)
        XCTAssertEqual(SyncClock.highest(of: [Date(timeIntervalSince1970: 50)], floor: floor, notAfter: now), floor,
                       "a value below the floor never moves the watermark backwards")
        XCTAssertEqual(SyncClock.highest(of: [Date(timeIntervalSince1970: 9_999)], floor: floor, notAfter: now), now)
    }

    /// A raw server error string can carry a token, a row id or a table name. The status the UI
    /// shows is a category, never the message.
    func testStatusTextIsACategoryAndNeverEchoesAServerString() {
        struct Leaky: Error, LocalizedError {
            var errorDescription: String? { "PGRST301: JWT eyJhbGciOiJIUzI1NiJ9.leak expired for user 1234" }
        }
        let status = SyncStatus.category(for: Leaky())
        XCTAssertEqual(status, .failedServer)
        XCTAssertFalse(status.text.contains("eyJ"))
        XCTAssertFalse(status.text.contains("PGRST"))
        XCTAssertEqual(status.text, "Sync failed. The server rejected the change.")
    }

    func testStatusCategoriesCoverNetworkAndCancellation() {
        XCTAssertEqual(SyncStatus.category(for: URLError(.notConnectedToInternet)), .failedNetwork)
        XCTAssertEqual(SyncStatus.category(for: SyncCancelled()), .cancelled)
    }

    func testEveryStatusHasHumanText() {
        for status in SyncStatus.allCases {
            XCTAssertFalse(status.text.isEmpty, "\(status) has no text")
        }
    }

    // MARK: the sign-out warning count (verification defect D-D7)

    /// The number this produces is what a destructive dialog tells the person they are about to
    /// lose, so the boundary condition matters: a row stamped exactly at the watermark was
    /// included in the last successful push and is not outstanding.
    func testUnsyncedCountUsesAStrictlyNewerComparisonPerTable() {
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 1_000))
        state.setPushedThrough(.voiceRecordings, Date(timeIntervalSince1970: 2_000))

        let count = UnsyncedCount.count(
            updatedAtByTable: [
                .animals: [Date(timeIntervalSince1970: 999),    // pushed
                           Date(timeIntervalSince1970: 1_000),  // pushed, exactly at the watermark
                           Date(timeIntervalSince1970: 1_001)], // outstanding
                .voiceRecordings: [Date(timeIntervalSince1970: 2_500)], // outstanding
                .vocalizations: [Date(timeIntervalSince1970: 1)],       // never pushed: epoch watermark
            ],
            pendingTombstones: 0,
            state: state)

        XCTAssertEqual(count, 3)
    }

    func testUnsyncedCountAddsPendingTombstonesAndIsZeroWhenEverythingIsPushed() {
        var state = SyncState()
        for table in SyncTable.allCases { state.setPushedThrough(table, Date(timeIntervalSince1970: 5_000)) }
        let rows: [SyncTable: [Date]] = [.animals: [Date(timeIntervalSince1970: 4_000)]]

        XCTAssertEqual(UnsyncedCount.count(updatedAtByTable: rows, pendingTombstones: 0, state: state), 0)
        XCTAssertEqual(UnsyncedCount.count(updatedAtByTable: rows, pendingTombstones: 2, state: state), 2,
                       "a delete that has not reached the server is outstanding work too")
        XCTAssertEqual(UnsyncedCount.count(updatedAtByTable: [:], pendingTombstones: 0, state: state), 0)
    }
}
