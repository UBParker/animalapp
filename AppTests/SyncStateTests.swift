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

    /// The exact wording Settings shows. Asserting non-emptiness over `allCases` could not fail:
    /// `text` is an exhaustive switch, so a missing case is a compile error and the only way to
    /// make an emptiness check red is to write an empty literal on purpose. The strings themselves
    /// are the thing worth pinning, because they are what a person reads when sync breaks.
    func testStatusTextIsTheExactWordingSettingsShows() {
        XCTAssertEqual(SyncStatus.never.text, "Never synced")
        XCTAssertEqual(SyncStatus.idle.text, "Synced")
        XCTAssertEqual(SyncStatus.syncing.text, "Syncing")
        XCTAssertEqual(SyncStatus.offline.text, "Offline. Records stay on this phone.")
        XCTAssertEqual(SyncStatus.notSignedIn.text, "Not signed in")
        XCTAssertEqual(SyncStatus.cancelled.text, "Sync stopped")
        XCTAssertEqual(SyncStatus.failedNetwork.text, "Sync failed. No connection.")
        XCTAssertEqual(SyncStatus.failedServer.text, "Sync failed. The server rejected the change.")
        XCTAssertEqual(SyncStatus.failedLocal.text, "Sync failed. Could not read or write on this phone.")
        XCTAssertEqual(SyncStatus.allCases.count, 9, "a new status needs its own wording asserted here")
    }

    /// Tasks 10 and 11 page against these three, and nothing asserted their values: every other
    /// reference compares a constant against itself, so changing one would keep the suite green.
    func testThePagingConstantsAreTheValuesTheEngineDependsOn() {
        XCTAssertEqual(SyncState.epoch.timeIntervalSince1970, 0)
        XCTAssertEqual(SyncCoding.string(from: SyncState.epoch), "1970-01-01T00:00:00.000Z",
                       "the epoch has to be below every real server stamp and has to survive the wire")
        XCTAssertEqual(SyncState.pageLimit, 500)
        XCTAssertEqual(SyncState.audioUploadsPerCycle, 10)
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

    // MARK: an ownership record that cannot be read must never wipe the store (review C1)

    private static let userA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let userB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Three different things, and collapsing the last two into the first is the data-loss bug:
    /// absent is a fresh install, decoded is a real owner, unreadable is a fault.
    func testOwnershipLoadTellsAbsentFromDecodedFromUnreadable() {
        XCTAssertEqual(StoreOwner.loadOutcome(defaults: defaults), .absent)

        let owner = StoreOwner(userID: Self.userA.uuidString.lowercased(),
                               claimedAt: Date(timeIntervalSince1970: 10))
        owner.save(defaults: defaults)
        XCTAssertEqual(StoreOwner.loadOutcome(defaults: defaults), .decoded(owner))

        defaults.set(Data("{ this is not json".utf8), forKey: StoreOwner.defaultsKey)
        XCTAssertEqual(StoreOwner.loadOutcome(defaults: defaults), .unreadable)

        // A field whose type changed under an existing key is the other realistic shape.
        defaults.set(Data(#"{"userID":{"unexpected":"shape"}}"#.utf8), forKey: StoreOwner.defaultsKey)
        XCTAssertEqual(StoreOwner.loadOutcome(defaults: defaults), .unreadable)
    }

    /// The whole point of this fix wave. Before it, an unreadable record came back as a fresh
    /// `StoreOwner` with `userID == nil`, the policy read that as "nobody owns this store", and a
    /// non-empty store was wiped with no dialog on the sign-in path. The same person signing back
    /// into their own account lost every row that had not reached the server.
    func testAnUnreadableOwnershipRecordNeverDecidesResetOnANonEmptyStore() {
        defaults.set(Data("{ this is not json".utf8), forKey: StoreOwner.defaultsKey)

        // The call shape AuthService.establish uses.
        let viaLoad = StoreOwnerPolicy.decision(ownerID: StoreOwner.load(defaults: defaults).userID,
                                                newUserID: Self.userA,
                                                storeIsEmpty: false)
        XCTAssertNotEqual(viaLoad, .reset, "an unreadable ownership record must never wipe a store")
        XCTAssertEqual(viaLoad, .keep)

        // The explicit shape, for a caller that has the outcome in hand.
        XCTAssertEqual(StoreOwnerPolicy.decision(ownership: StoreOwner.loadOutcome(defaults: defaults),
                                                 newUserID: Self.userA,
                                                 storeIsEmpty: false), .keep)
    }

    /// Why keeping is safe: the claim that follows re-establishes ownership, so a different user
    /// signing in after it still reads a real owner id, still mismatches, and still resets.
    func testTheClaimAfterAnUnreadableRecordPutsTheMismatchGuardBack() {
        defaults.set(Data("{ this is not json".utf8), forKey: StoreOwner.defaultsKey)
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: StoreOwner.load(defaults: defaults).userID,
                                                 newUserID: Self.userA,
                                                 storeIsEmpty: false), .keep)

        // What establish does next, unchanged.
        StoreOwner(userID: Self.userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)

        XCTAssertEqual(StoreOwner.loadOutcome(defaults: defaults),
                       .decoded(StoreOwner(userID: Self.userA.uuidString.lowercased(),
                                           claimedAt: StoreOwner.load(defaults: defaults).claimedAt)))
        XCTAssertEqual(StoreOwnerPolicy.decision(ownerID: StoreOwner.load(defaults: defaults).userID,
                                                 newUserID: Self.userB,
                                                 storeIsEmpty: false), .reset)
    }

    /// The unreadable marker is a signal `load` produces, never an owner. Writing it back would
    /// turn a soft fault into a persisted owner id that matches nobody, which is a wipe next time.
    func testTheUnreadableMarkerIsNeverPersisted() {
        defaults.set(Data("{ this is not json".utf8), forKey: StoreOwner.defaultsKey)
        let loaded = StoreOwner.load(defaults: defaults)
        XCTAssertEqual(loaded.userID, StoreOwner.unreadableOwnerID)
        XCTAssertNil(UUID(uuidString: StoreOwner.unreadableOwnerID),
                     "the marker must not be parseable as a user id")

        loaded.save(defaults: defaults)
        XCTAssertEqual(StoreOwner.loadOutcome(defaults: defaults), .unreadable,
                       "save refused the marker, so the corrupt blob is still there to be inspected")
    }

    // MARK: a blob this build cannot fully read must not cost the watermarks (review C1)

    /// A status raw value from a newer build, seen by an older one after a rollback or a staged
    /// release. It shares one blob with every watermark, so a throwing decode would reset the lot
    /// and re-push and re-pull the whole store.
    func testAnUnknownStatusRawValueFallsBackWithoutTakingTheWatermarks() throws {
        let pushed = Date(timeIntervalSince1970: 1_750_000_500.25)
        let cursor = Date(timeIntervalSince1970: 1_750_000_900.5)
        var state = SyncState()
        state.setPushedThrough(.animals, pushed)
        state.setPullCursor(.vocalizations, cursor, offset: 7)
        state.status = .idle
        state.save(defaults: defaults)

        let stored = try XCTUnwrap(defaults.data(forKey: SyncState.defaultsKey))
        let tampered = try XCTUnwrap(String(data: stored, encoding: .utf8))
            .replacingOccurrences(of: "\"idle\"", with: "\"syncingFromABuildThatDoesNotExistYet\"")
        defaults.set(Data(tampered.utf8), forKey: SyncState.defaultsKey)

        let loaded = SyncState.load(defaults: defaults)
        XCTAssertEqual(loaded.status, .never, "an unrecognised status falls back to a defined case")
        XCTAssertEqual(loaded.pushedThrough(.animals).timeIntervalSince1970,
                       pushed.timeIntervalSince1970, accuracy: 0.001,
                       "and it does not take the watermarks with it")
        XCTAssertEqual(loaded.pullCursor(.vocalizations).timeIntervalSince1970,
                       cursor.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.pullOffset(.vocalizations), 7)
    }

    func testAnUnknownStatusRawValueDecodesToTheFallbackOnItsOwn() throws {
        let decoded = try JSONDecoder().decode([SyncStatus].self,
                                               from: Data(#"["idle","notAStatusThisBuildKnows"]"#.utf8))
        XCTAssertEqual(decoded, [.idle, .never])
    }

    /// A blob written by a struct with fewer fields. This is the shape every existing install has
    /// the moment anyone adds a property, and Swift's synthesized `init(from:)` would reject it:
    /// it calls `decode`, not `decodeIfPresent`, for non-optionals and ignores their defaults.
    func testABlobWrittenByAStructWithFewerFieldsStillDecodes() {
        defaults.set(Data(#"{"userID":"11111111-1111-1111-1111-111111111111","claimedAt":0}"#.utf8),
                     forKey: StoreOwner.defaultsKey)
        let owner = StoreOwner.load(defaults: defaults)
        XCTAssertEqual(owner.userID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(owner.claimedAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(owner.schemaVersion, StoreOwner.currentSchemaVersion)

        defaults.set(Data(#"{"pushedThroughAt":{"animals":0},"pullCursorAt":{},"pullOffsetAt":{},"status":"idle"}"#.utf8),
                     forKey: SyncState.defaultsKey)
        let state = SyncState.load(defaults: defaults)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.schemaVersion, SyncState.currentSchemaVersion)
        XCTAssertEqual(state.pushedThrough(.animals), Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertNil(state.lastSyncedAt)
    }

    /// And a blob from a later build, carrying a key this one has never heard of, is additive.
    func testABlobWrittenByAStructWithMoreFieldsStillDecodes() {
        defaults.set(Data(#"{"userID":"11111111-1111-1111-1111-111111111111","schemaVersion":2,"somethingLater":true}"#.utf8),
                     forKey: StoreOwner.defaultsKey)
        let owner = StoreOwner.load(defaults: defaults)
        XCTAssertEqual(owner.userID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(owner.schemaVersion, 2, "the stored version is reported, not overwritten")
    }

    /// Falling back to a fresh state costs bandwidth, so it is allowed, but it must not destroy
    /// the evidence: the unreadable blob stays under its key until something deliberately saves.
    func testACorruptStateBlobIsLeftInPlaceToBeRecovered() {
        defaults.set(Data("{ this is not json".utf8), forKey: SyncState.defaultsKey)
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
        XCTAssertNotNil(defaults.data(forKey: SyncState.defaultsKey),
                        "load never destroys the blob it could not read")
    }
}
