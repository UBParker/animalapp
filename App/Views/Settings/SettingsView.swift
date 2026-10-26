import SwiftUI

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
                        .confirmationDialog("\(unsyncedCount) record\(unsyncedCount == 1 ? "" : "s") could not be backed up",
                                            isPresented: $showUnsyncedSignOutConfirmation,
                                            titleVisibility: .visible) {
                            Button("Sign out anyway", role: .destructive) {
                                Task { await performSignOut() }
                            }
                            Button("Stay signed in", role: .cancel) {}
                        } message: {
                            Text("Signing out deletes everything on this phone, including those \(unsyncedCount). They are not on the server, so they cannot be downloaded again.")
                        }
                    Button("Sign out", role: .destructive) { showSignOutConfirmation = true }
                        .disabled(isSigningOut || auth.isSigningOut)
                        // Dialog 1 of the sign-out flow.
                        .confirmationDialog("Sign out of this account?",
                                            isPresented: $showSignOutConfirmation,
                                            titleVisibility: .visible) {
                            Button("Back up and sign out") {
                                Task { await backUpThenSignOut() }
                            }
                            Button("Stay signed in", role: .cancel) {}
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
        if pushed && outstanding == 0 {
            await performSignOut()
            return
        }
        // Failed, timed out, or finished with rows still behind the watermark. Name the number and
        // make the person confirm a second time before anything is destroyed.
        unsyncedCount = outstanding
        showUnsyncedSignOutConfirmation = true
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
        case .sessionSurvivedSignOut:
            // The wipe did run, so the records really are gone. Only a session file came back.
            return "Sign out did not finish. The records on this phone are gone, but a session file could not be removed. This phone will try again the next time the app starts; restarting the phone also clears it."
        case .signOutAlreadyRunning:
            return "A sign out is already under way. Wait for it to finish."
        default:
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
