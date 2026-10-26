import SwiftUI

/// One button the Account section renders while signed in.
///
/// B-F7: addendum item 2 requires that the screen offer no way to force past a refused teardown,
/// and the test for it used to grep notice strings for the word "force", which a
/// "Sign out anyway, I accept the risk" button would have left green. The section's buttons take
/// their titles and roles from `AccountButtons` below, so a test on that list is a test on what
/// the screen renders. A button written straight into the view would still escape it, which is the
/// residual limit of inspecting SwiftUI without a view-inspection library.
struct AccountButton: Equatable {
    enum Effect: Equatable {
        /// Opens a confirmation dialog. Destroys nothing by itself.
        case opensConfirmation
        /// Reaches `performSignOut()`, which calls `auth.signOut()` and nothing else, so the
        /// outcome is always rendered and a refusal is always left for the next launch to retry.
        case signsOut
        case cancels
    }

    let title: String
    let isDestructive: Bool
    let effect: Effect
}

enum AccountButtons {
    static let signOut = AccountButton(title: "Sign out", isDestructive: true, effect: .opensConfirmation)
    static let backUpAndSignOut = AccountButton(title: "Back up and sign out", isDestructive: false, effect: .signsOut)
    static let staySignedIn = AccountButton(title: "Stay signed in", isDestructive: false, effect: .cancels)
    static let signOutAnyway = AccountButton(title: "Sign out anyway", isDestructive: true, effect: .signsOut)

    /// Every button the signed-in Account section offers, in render order. There is deliberately
    /// nothing here that signs out while skipping the pending-teardown retry.
    static let all = [signOut, backUpAndSignOut, staySignedIn, signOutAnyway]
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var store: AppStoreLifecycle
    @AppStorage("checkInQuestionCap") private var questionCap = 8
    @AppStorage("speakQuestions") private var speakQuestions = true
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = KeychainStore().get(KeychainStore.apiKeyAccount) != nil
    @State private var keyMessage: String?
    @State private var showLeaveOfflineConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showUnsyncedSignOutConfirmation = false
    @State private var unsyncedCount = 0
    @State private var isSigningOut = false
    /// What a refused sign-out left behind, in the person's terms. Separate from `auth.message`
    /// so the Account section can say what happened to the records, not only what the keychain
    /// did.
    @State private var signOutNotice: String?

    var body: some View {
        Form {
            Section("Account") {
                switch auth.state {
                case .signedIn(let userID, let email):
                    LabeledContent("Signed in as", value: email ?? userID.uuidString)
                        // Dialog 2 of the sign-out flow, on its own host view so it is never
                        // stacked on the same view as dialog 1.
                        .confirmationDialog(SettingsView.unsyncedDialogTitle(count: unsyncedCount),
                                            isPresented: $showUnsyncedSignOutConfirmation,
                                            titleVisibility: .visible) {
                            Button(AccountButtons.signOutAnyway.title, role: .destructive) {
                                Task { await performSignOut() }
                            }
                            Button(AccountButtons.staySignedIn.title, role: .cancel) {}
                        } message: {
                            Text(SettingsView.unsyncedDialogMessage(count: unsyncedCount))
                        }
                    Button(AccountButtons.signOut.title, role: .destructive) { showSignOutConfirmation = true }
                        .disabled(isSigningOut || auth.isSigningOut)
                        // Dialog 1 of the sign-out flow.
                        .confirmationDialog("Sign out of this account?",
                                            isPresented: $showSignOutConfirmation,
                                            titleVisibility: .visible) {
                            Button(AccountButtons.backUpAndSignOut.title) {
                                Task { await backUpThenSignOut() }
                            }
                            Button(AccountButtons.staySignedIn.title, role: .cancel) {}
                        } message: {
                            Text("Signing out deletes the records on this phone. Anything already backed up is downloaded again next time you sign in.")
                        }
                case .offline:
                    Text("Offline. Records stay on this phone and are not backed up.")
                        .font(.footnote).foregroundStyle(.secondary)
                    // The only state that offers to leave offline mode, and only behind the
                    // confirmation below, because leaving discards the offline records.
                    Button("Sign in") { showLeaveOfflineConfirmation = true }
                        .confirmationDialog("Leaving offline mode deletes the records on this phone",
                                            isPresented: $showLeaveOfflineConfirmation,
                                            titleVisibility: .visible) {
                            Button("Delete and sign in", role: .destructive) {
                                Task {
                                    signOutNotice = nil
                                    await auth.leaveOfflineMode()
                                }
                            }
                            Button("Stay offline", role: .cancel) {}
                        } message: {
                            Text("Offline records belong to no account, so they are not carried into the one you sign in to.")
                        }
                case .signedOut, .unknown:
                    // Unreachable in practice: RootGate shows the sign-in screen or the loading
                    // screen for these, never the tabs, so Settings is not on screen. Rendered as
                    // text rather than a button on purpose. v2 wired a "Sign in" button here to
                    // `leaveOfflineMode()`, which wipes the store; firing that from a state that
                    // never created offline data would destroy a signed-in person's records
                    // between a sign-out and the next screen.
                    Text("Not signed in.").font(.footnote).foregroundStyle(.secondary)
                case .misconfigured:
                    Text("This build has no Supabase key, so it cannot sign in or back anything up.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                // A refused sign-out says more than `auth.message` does, so it wins the row while
                // it stands. There is deliberately no "force sign out" next to it: a refusal is
                // persisted as a pending teardown and retried at the next launch, and forcing past
                // it here would skip that retry.
                if let signOutNotice {
                    Text(signOutNotice).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("signOutRefusedNotice")
                } else if let message = auth.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            Section("Animals") {
                NavigationLink("Manage Animals") { ManageAnimalsView() }
            }
            Section("Oral check-in") {
                SecureField(hasStoredKey ? "API key saved (enter to replace)" : "Anthropic API key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    // Borderless: a Form row otherwise hands the whole row's taps to the first button.
                    Button("Save key") { saveKey() }
                        .buttonStyle(.borderless)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if hasStoredKey {
                        Button("Remove key", role: .destructive) { removeKey() }
                            .buttonStyle(.borderless)
                    }
                }
                if let keyMessage { Text(keyMessage).font(.footnote).foregroundStyle(.secondary) }
                Stepper("Max follow-up questions: \(questionCap)", value: $questionCap, in: 1...20)
                Toggle("Speak questions aloud", isOn: $speakQuestions)
            }
            Section("Tags") {
                SettingsPlaceholderRow(title: "Poop tags")
                NavigationLink("Voice tags") { ManageVoiceTagsView() }
            }
            Section("Data") {
                SettingsPlaceholderRow(title: "Export")
                SettingsPlaceholderRow(title: "Import")
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Text("Animals, voice recordings and tags sync to your Supabase account. Oral check-in transcripts are sent to Anthropic, using your own key.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    /// Sign out is the one ordinary setting that destroys data, and everything created since the
    /// last successful push exists only on this phone. So: push first, and only warn if that push
    /// did not clear the backlog (verification defect D-D7).
    ///
    /// The timeout is what keeps this honest. A dead network would otherwise hang the sign-out on
    /// an engine retry, and a person who has decided to sign out will force-quit instead, which
    /// loses exactly the records this is trying to save. `AuthService.finalPushTimeout` rather
    /// than a literal, so the bound this button uses and the bound an unattended sign-out uses
    /// cannot drift apart.
    @MainActor
    private func backUpThenSignOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        signOutNotice = nil
        let pushed = await store.sync?.pushBeforeSignOut(timeout: AuthService.finalPushTimeout) ?? true
        let outstanding = store.sync?.unsyncedRowCount() ?? 0
        switch SettingsView.step(pushed: pushed, outstanding: outstanding) {
        case .signOut:
            await performSignOut()
        case .warn(let count):
            // Failed, timed out, or finished with rows still behind the watermark. Name the number
            // and make the person confirm a second time before anything is destroyed.
            unsyncedCount = count
            // B-F3. This branch used to set nothing but the dialog flag, so a dialog that did not
            // present made the whole tap a silent no-op: nothing signed out, nothing said, and
            // `isSigningOut` already back down. The row now says what happened whether or not the
            // dialog appears.
            signOutNotice = SettingsView.unsyncedSignOutNotice(count: count)
            showUnsyncedSignOutConfirmation = true
        }
    }

    /// What `backUpThenSignOut()` does with the push result, lifted out of the view so the branch
    /// can be asserted rather than watched (B-F3).
    ///
    /// A push that failed or timed out warns even with nothing behind the watermark: "nothing
    /// outstanding" reported by a push that did not run is not evidence that anything was backed
    /// up.
    enum SignOutStep: Equatable {
        case signOut
        case warn(count: Int)
    }

    static func step(pushed: Bool, outstanding: Int) -> SignOutStep {
        pushed && outstanding == 0 ? .signOut : .warn(count: outstanding)
    }

    /// A13. `pushed == false` with nothing behind the watermark used to open a destructive dialog
    /// titled "0 records could not be backed up", which reads like a bug and invites tapping
    /// through it. A count of zero in this branch always means the push itself did not finish, so
    /// that is what it says.
    static func unsyncedDialogTitle(count: Int) -> String {
        count == 0
            ? "Could not finish backing up"
            : "\(count) record\(count == 1 ? "" : "s") could not be backed up"
    }

    static func unsyncedDialogMessage(count: Int) -> String {
        count == 0
            ? "Signing out deletes the records on this phone. The backup did not finish, so anything that had not already reached the server cannot be downloaded again."
            : "Signing out deletes everything on this phone, including those \(count). They are not on the server, so they cannot be downloaded again."
    }

    /// The row's own words for the same pause, shown whether or not the dialog presents.
    static func unsyncedSignOutNotice(count: Int) -> String {
        count == 0
            ? "Sign out paused: the backup did not finish. Nothing has been deleted yet. Confirm the sign-out to continue, or stay signed in and try again later."
            : "Sign out paused: \(count) record\(count == 1 ? "" : "s") on this phone \(count == 1 ? "is" : "are") not backed up. Nothing has been deleted yet."
    }

    /// Signs out and renders the outcome. `signOut()` returns `SignOutOutcome` rather than
    /// throwing, and a `.refused` result is not a sign-out: the person has to be told what
    /// actually happened to their records instead of being shown a signed-out app.
    @MainActor
    private func performSignOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        signOutNotice = nil
        switch await auth.signOut() {
        case .signedOut:
            break
        case .refused(let error):
            signOutNotice = SettingsView.refusedSignOutNotice(error)
        }
    }

    /// What each refusal means for the person's data. Branching on the case rather than on
    /// `auth.message`, so a copy edit upstream cannot change which of these is shown.
    static func refusedSignOutNotice(_ error: AuthError) -> String {
        switch error {
        case .sessionStillPresent:
            // Nothing was destroyed: the keychain refused before the wipe, so the session, the
            // records and the media are all still here and still theirs.
            return "Sign out did not complete. Nothing was deleted: your records are still on this phone and still yours, and you are still signed in. This phone will try again the next time the app starts."
        case .localDataNotCleared:
            // RULING 1. The session went, the records did not. Nothing is shown and the next launch
            // retries, so the one thing not to say here is that this is finished.
            return "Sign out did not finish. This phone is signed out, but it could not delete the records it was holding, so they are still here. It will finish clearing them before anyone signs in."
        case .mediaNotCleared:
            // RULING 2. The rows went; some files did not.
            return "Sign out did not finish. The records on this phone are gone, but some audio or photo files could not be removed. This phone will try again the next time the app starts."
        case .signOutAlreadyRunning:
            return "A sign out is already under way. Wait for it to finish."
        default:
            // `.sessionSurvivedSignOut` lands here on purpose, and so does anything later added.
            // That case sets `state = .signedOut` before `performSignOut()` resumes, so this view
            // and its `@State` are already gone and no screen can render a notice written here
            // (A-minor 9, B-F5). The reachable surface is `auth.message`, which `AuthService` has
            // already set to the same error's `errorDescription` and which `SignInView` renders;
            // `AuthServiceTests.testASessionThatSurvivesTheSecondSweepIsReportedAndLeavesARetryMarker`
            // is what pins it. Routing it twice would mean two strings to keep in step, one of
            // which nobody can see.
            return error.errorDescription ?? "Sign out did not complete. Nothing was deleted."
        }
    }

    private func saveKey() {
        do {
            try KeychainStore().set(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines), account: KeychainStore.apiKeyAccount)
            apiKeyDraft = ""
            hasStoredKey = true
            keyMessage = "Key saved to the keychain."
        } catch {
            keyMessage = "Could not save key: \(error)"
        }
    }

    private func removeKey() {
        KeychainStore().delete(KeychainStore.apiKeyAccount)
        hasStoredKey = false
        keyMessage = "Key removed."
    }
}

/// Rows that later plans replace with real destinations.
struct SettingsPlaceholderRow: View {
    let title: String
    var body: some View {
        LabeledContent(title) { Text("Coming soon").foregroundStyle(.secondary) }
    }
}
