import Supabase
import SwiftData
import XCTest
@testable import AnimalTracker

final class RootGateTests: XCTestCase {
    /// The one fact the whole-mapping case below does not carry: a non-nil email is ignored too.
    func testSignedInShowsTheTabsWithNoBanner() {
        XCTAssertEqual(RootGate.screen(for: .signedIn(userID: UUID(), email: "ash@example.com")),
                       .main(showsOfflineBanner: false))
    }

    /// Five states, five distinct screens: loading, signIn, main(false), main(true), blocked.
    /// This is the whole mapping in one assertion, which is why the six cases that used to sit
    /// beside it are gone: each of them was a strict subset of this one and could never fail alone
    /// (B-F7). An implementation that collapsed `.misconfigured` onto `.main`, the one collapse
    /// that must never happen, fails here.
    func testEveryStateMapsToItsOwnScreen() {
        let all: [AuthState] = [.unknown, .signedOut, .signedIn(userID: UUID(), email: nil), .offline, .misconfigured]
        XCTAssertEqual(all.map(RootGate.screen(for:)),
                       [.loading, .signIn, .main(showsOfflineBanner: false),
                        .main(showsOfflineBanner: true), .blocked])
    }
}

/// Addendum item 2: a `.refused` sign-out is not a sign-out, and what the person is told has to
/// say what happened to their records. Branching on the `AuthError` case rather than on
/// `auth.message` is what keeps the refusals from reading the same.
final class SignOutNoticeTests: XCTestCase {
    func testTheKeychainRefusalSaysNothingWasDeleted() {
        let notice = SettingsView.refusedSignOutNotice(.sessionStillPresent)
        XCTAssertTrue(notice.contains("Nothing was deleted"), notice)
        XCTAssertTrue(notice.contains("still on this phone"), notice)
        XCTAssertTrue(notice.contains("still signed in"), notice)
    }

    func testASecondTapIsToldToWait() {
        XCTAssertTrue(SettingsView.refusedSignOutNotice(.signOutAlreadyRunning).contains("already under way"))
    }

    /// RULINGs 1 and 2 land on this screen as two different sentences, because "your records are
    /// still here" and "your records went, some files did not" call for different expectations.
    func testTheTwoUnfinishedWipesDoNotReadTheSame() {
        let store = SettingsView.refusedSignOutNotice(.localDataNotCleared)
        let media = SettingsView.refusedSignOutNotice(.mediaNotCleared)
        XCTAssertNotEqual(store, media)
        XCTAssertTrue(store.contains("still here"), store)
        XCTAssertFalse(media.contains("Nothing was deleted"), media)
    }

    /// Every refusal this screen can be handed gets its own words. The old version of this asserted
    /// only `!notice.isEmpty`, which no input can fail: every arm returns a string literal and the
    /// default arm falls back to one (B-F7).
    func testEveryRefusalGetsItsOwnNotice() {
        // `Supabase` exports an `AuthError` too, and this file now imports it for `SyncCoordinating`.
        let refusals: [AnimalTracker.AuthError] = [.sessionStillPresent, .sessionSurvivedSignOut, .signOutAlreadyRunning,
                                                   .signOutRefused, .localDataNotCleared,
                                                   .mediaNotCleared, .notConfigured]
        let notices = refusals.map(SettingsView.refusedSignOutNotice)
        XCTAssertEqual(Set(notices).count, refusals.count, "two refusals read the same: \(notices)")
    }

    /// B-F7. Addendum item 2 requires that the screen offer no way past a refused teardown. The old
    /// test asserted that six notice strings did not contain the word "force", which a
    /// "Sign out anyway, I accept the risk" button would have left green. The Account section's
    /// buttons take their titles, roles and effects from this list, so this inspects what the
    /// screen renders rather than an unrelated string.
    func testTheAccountSectionOffersExactlyTheseButtons() {
        XCTAssertEqual(AccountButtons.all.map(\.title),
                       ["Sign out", "Back up and sign out", "Stay signed in", "Sign out anyway"])
        XCTAssertEqual(AccountButtons.all.filter { $0.effect == .signsOut }.map(\.title),
                       ["Back up and sign out", "Sign out anyway"],
                       "the only two taps that sign out, both behind a confirmation, both through performSignOut()")
        XCTAssertEqual(AccountButtons.all.filter(\.isDestructive).map(\.title),
                       ["Sign out", "Sign out anyway"])
    }
}

/// B-F3 and A13. `backUpThenSignOut()`'s failure branch used to end with nothing but a dialog flag,
/// so a dialog that did not present made the tap a silent no-op. The decision is lifted out of the
/// view so the branch can be asserted rather than watched.
final class SignOutStepTests: XCTestCase {
    func testACleanPushGoesStraightToTheSignOut() {
        XCTAssertEqual(SettingsView.step(pushed: true, outstanding: 0), .signOut)
    }

    /// A push that failed or timed out while leaving nothing behind the watermark still warns:
    /// "nothing outstanding" from a push that did not run is not evidence of a backup.
    func testAFailedPushWithNothingOutstandingStillWarns() {
        XCTAssertEqual(SettingsView.step(pushed: false, outstanding: 0), .warn(count: 0))
    }

    func testRowsBehindTheWatermarkWarnWithTheirCount() {
        XCTAssertEqual(SettingsView.step(pushed: true, outstanding: 3), .warn(count: 3))
    }

    /// A13. The destructive dialog used to be titled "0 records could not be backed up", which
    /// reads like a bug and invites tapping through it.
    func testTheDialogNeverCountsZeroRecords() {
        XCTAssertFalse(SettingsView.unsyncedDialogTitle(count: 0).contains("0 record"),
                       SettingsView.unsyncedDialogTitle(count: 0))
        XCTAssertFalse(SettingsView.unsyncedDialogMessage(count: 0).contains("those 0"),
                       SettingsView.unsyncedDialogMessage(count: 0))
        XCTAssertEqual(SettingsView.unsyncedDialogTitle(count: 1), "1 record could not be backed up")
        XCTAssertEqual(SettingsView.unsyncedDialogTitle(count: 2), "2 records could not be backed up")
    }

    /// The notice the row shows whether or not the dialog presents, and it says nothing was
    /// deleted, because nothing has been at that point.
    func testThePausedNoticeSaysNothingHasBeenDeletedYet() {
        for count in [0, 1, 4] {
            let notice = SettingsView.unsyncedSignOutNotice(count: count)
            XCTAssertFalse(notice.isEmpty)
            XCTAssertTrue(notice.contains("Nothing has been deleted yet"), notice)
        }
    }
}

/// B-F2. While a teardown the person asked for has not finished, the app does not offer a
/// sign-in: signing in on top of one leaves the marker set and the next launch wipes the store
/// belonging to the account that just signed in. The retry outranks everything, including a build
/// with no anon key, because a teardown needs no client to finish.
final class SignInOfferTests: XCTestCase {
    func testAPendingTeardownOutranksTheSignInButton() {
        XCTAssertEqual(SignInView.offer(pendingTeardown: .signOut, isConfigured: true),
                       .finishTeardown(.signOut))
        XCTAssertEqual(SignInView.offer(pendingTeardown: .accountDeleted, isConfigured: true),
                       .finishTeardown(.accountDeleted))
        XCTAssertEqual(SignInView.offer(pendingTeardown: .signOut, isConfigured: false),
                       .finishTeardown(.signOut),
                       "a teardown needs no client, so a keyless build still offers to finish it")
    }

    func testWithNothingPendingTheScreenOffersWhatTheBuildCanDo() {
        XCTAssertEqual(SignInView.offer(pendingTeardown: nil, isConfigured: true), .signIn)
        XCTAssertEqual(SignInView.offer(pendingTeardown: nil, isConfigured: false), .unavailable)
    }

    /// Each teardown names its own button, and neither offers to skip the retry.
    func testEachTeardownNamesItsOwnRetryButton() {
        let titles = [PendingTeardown.signOut, .accountDeleted].map(\.retryButtonTitle)
        XCTAssertEqual(Set(titles).count, 2, "the two teardowns do not read the same: \(titles)")
        for title in titles {
            XCTAssertFalse(title.lowercased().contains("skip"), title)
            XCTAssertFalse(title.lowercased().contains("anyway"), title)
        }
    }
}

/// B-F6 and B-F4. The `finalPushBeforeSignOut` closure was the one piece of wiring this task added
/// on its own judgement, it sits on the unattended destructive path, and it lived inside a `.task`
/// where nothing could reach it. Lifted to a function, and the `?? true` that made a missing
/// lifecycle read as a completed backup is gone.
@MainActor
final class FinalPushTests: XCTestCase {
    private func makeLifecycle() throws -> AppStoreLifecycle {
        AppStoreLifecycle(container: try PersistenceController.makeContainer(inMemory: true),
                          recovered: false,
                          mediaStore: InMemoryMediaStore())
    }

    /// "The lifecycle is gone" is not "there is nothing to push", and it must not read as success.
    func testNoLifecycleIsNotASuccessfulPush() async {
        let pushed = await RootView.finalPush(nil)(AuthService.finalPushTimeout)
        XCTAssertFalse(pushed)
    }

    /// No sync attached genuinely is nothing to push, which is the only meaning `true` has here.
    func testNoSyncAttachedIsNothingToPush() async throws {
        let store = try makeLifecycle()
        let pushed = await RootView.finalPush(store)(AuthService.finalPushTimeout)
        XCTAssertTrue(pushed, "nil sync is the only thing true means here")
    }

    func testTheResultAndTheTimeoutAreForwardedUnchanged() async throws {
        let store = try makeLifecycle()
        let sync = FakeSyncCoordinator()
        store.sync = sync

        sync.pushResult = false
        let failed = await RootView.finalPush(store)(12.5)
        XCTAssertFalse(failed)
        XCTAssertEqual(sync.pushTimeout, 12.5, "the closure re-sources nothing of its own")

        sync.pushResult = true
        let succeeded = await RootView.finalPush(store)(AuthService.finalPushTimeout)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(sync.pushTimeout, AuthService.finalPushTimeout)
    }
}

/// The sync Task 11 will supply, with only what the final push needs.
@MainActor
private final class FakeSyncCoordinator: SyncCoordinating {
    var pushTimeout: TimeInterval?
    var pushResult = true

    func cancelSync() async {}
    func attach(container: ModelContainer, mediaStore: MediaStore) {}
    func update(for state: AuthState, client: SupabaseClient?) {}
    func pushBeforeSignOut(timeout: TimeInterval) async -> Bool {
        pushTimeout = timeout
        return pushResult
    }
    func unsyncedRowCount() -> Int { 0 }
}
