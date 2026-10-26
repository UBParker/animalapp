import XCTest
@testable import AnimalTracker

final class RootGateTests: XCTestCase {
    func testUnknownShowsLoading() {
        XCTAssertEqual(RootGate.screen(for: .unknown), .loading)
    }

    func testSignedOutShowsTheSignInScreen() {
        XCTAssertEqual(RootGate.screen(for: .signedOut), .signIn)
    }

    func testSignedInShowsTheTabsWithNoBanner() {
        XCTAssertEqual(RootGate.screen(for: .signedIn(userID: UUID(), email: "ash@example.com")),
                       .main(showsOfflineBanner: false))
    }

    func testSignedInWithoutAnEmailStillShowsTheTabs() {
        XCTAssertEqual(RootGate.screen(for: .signedIn(userID: UUID(), email: nil)),
                       .main(showsOfflineBanner: false))
    }

    func testOfflineShowsTheTabsWithTheBanner() {
        XCTAssertEqual(RootGate.screen(for: .offline), .main(showsOfflineBanner: true))
    }

    /// Fail closed. A build with no anon key must never reach `RootTabView`.
    func testMisconfiguredIsBlockedAndIsNeverTheTabs() {
        XCTAssertEqual(RootGate.screen(for: .misconfigured), .blocked)
        XCTAssertNotEqual(RootGate.screen(for: .misconfigured), .main(showsOfflineBanner: true))
        XCTAssertNotEqual(RootGate.screen(for: .misconfigured), .main(showsOfflineBanner: false))
    }

    /// The scripted walk a real session takes: launch, restore fails, sign in, sign out.
    func testScriptedStateSequence() {
        let userID = UUID()
        let script: [AuthState] = [.unknown, .signedOut, .signedIn(userID: userID, email: nil), .signedOut]
        XCTAssertEqual(script.map(RootGate.screen(for:)),
                       [.loading, .signIn, .main(showsOfflineBanner: false), .signIn])
    }

    /// Five states, five distinct screens: loading, signIn, main(false), main(true), blocked.
    /// Counting four, as v2 did, would let `.misconfigured` collapse onto one of the others and
    /// still pass, which is the one collapse that must never happen.
    func testEveryStateMapsToItsOwnScreen() {
        let all: [AuthState] = [.unknown, .signedOut, .signedIn(userID: UUID(), email: nil), .offline, .misconfigured]
        let screens = all.map(RootGate.screen(for:))
        XCTAssertEqual(screens, [.loading, .signIn, .main(showsOfflineBanner: false),
                                 .main(showsOfflineBanner: true), .blocked])
        XCTAssertEqual(Set(screens.map { String(describing: $0) }).count, 5)
    }
}

/// Addendum item 2: a `.refused` sign-out is not a sign-out, and what the person is told has to
/// say what happened to their records. Branching on the `AuthError` case rather than on
/// `auth.message` is what keeps the two refusals from reading the same.
final class SignOutNoticeTests: XCTestCase {
    func testTheKeychainRefusalSaysNothingWasDeleted() {
        let notice = SettingsView.refusedSignOutNotice(.sessionStillPresent)
        XCTAssertTrue(notice.contains("Nothing was deleted"), notice)
        XCTAssertTrue(notice.contains("still on this phone"), notice)
        XCTAssertTrue(notice.contains("still signed in"), notice)
    }

    /// The opposite case, and the one a shared message would get wrong: here the wipe did run, so
    /// telling the person their records are still on the phone would be a lie.
    func testTheSurvivingSessionSaysTheRecordsAreAlreadyGone() {
        let notice = SettingsView.refusedSignOutNotice(.sessionSurvivedSignOut)
        XCTAssertTrue(notice.contains("are gone"), notice)
        XCTAssertFalse(notice.contains("Nothing was deleted"), notice)
    }

    func testASecondTapIsToldToWait() {
        XCTAssertTrue(SignOutNoticeTests.notice(.signOutAlreadyRunning).contains("already under way"))
    }

    /// Every refusal has to produce something to show, including cases this screen does not
    /// expect, and none of them may offer to force past the retry the next launch will make.
    func testEveryRefusalHasANoticeAndNoneOffersToForceTheSignOut() {
        let refusals: [AuthError] = [.sessionStillPresent, .sessionSurvivedSignOut,
                                     .signOutAlreadyRunning, .signOutRefused, .notConfigured]
        for error in refusals {
            let notice = SignOutNoticeTests.notice(error)
            XCTAssertFalse(notice.isEmpty, "no notice for \(error)")
            XCTAssertFalse(notice.lowercased().contains("force"), "offers to force past the retry: \(notice)")
        }
    }

    private static func notice(_ error: AuthError) -> String { SettingsView.refusedSignOutNotice(error) }
}
