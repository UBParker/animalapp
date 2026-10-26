import AuthenticationServices
import SwiftUI

/// What the sign-in screen offers. Kept out of the view so the one rule that matters here is
/// unit-testable: while a teardown is pending the app does not offer a sign-in (B-F2).
enum SignInOffer: Equatable {
    /// The Apple button, enabled.
    case signIn
    /// No Apple button. A teardown the person asked for has not finished, and signing in on top of
    /// one leaves the marker set, so the next launch wipes the store belonging to the account that
    /// just signed in. The only action is finishing the teardown.
    case finishTeardown(PendingTeardown)
    /// A build with no anon key. Nothing to offer, and nothing destructive either.
    case unavailable
}

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    /// A pending teardown outranks everything, a keyless build included: finishing a teardown
    /// needs no client, and a build that cannot sign in must still be able to finish one.
    static func offer(pendingTeardown: PendingTeardown?, isConfigured: Bool) -> SignInOffer {
        if let pendingTeardown { return .finishTeardown(pendingTeardown) }
        return isConfigured ? .signIn : .unavailable
    }

    private var offer: SignInOffer {
        SignInView.offer(pendingTeardown: auth.pendingTeardown, isConfigured: auth.isConfigured)
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("AnimalTracker")
                .font(.largeTitle.bold())
            switch offer {
            case .signIn:
                tagline
                appleButton
            case .unavailable:
                tagline
                Text("This build has no Supabase key, so sign-in is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                appleButton
            case .finishTeardown(let pending):
                // B-F2. No Apple button here on purpose. A sign-in from this screen would leave
                // the marker set and the next launch would destroy the records of the account that
                // just signed in, so the teardown is finished first and only a teardown that
                // verified itself unlocks the button.
                Text("This phone has not finished clearing the last account's records. That has to finish before anyone signs in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(pending.retryButtonTitle) {
                    Task { await auth.retryPendingTeardown() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(auth.isSigningOut)
                .accessibilityIdentifier("finishPendingTeardown")
            }
            if let message = auth.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            #if DEBUG
            // Also gated on the teardown: offline mode puts the tabs over the very store the
            // pending teardown exists to destroy.
            if auth.pendingTeardown == nil {
                Button("Continue offline") { auth.continueOffline() }
                    .font(.footnote)
                    .accessibilityIdentifier("continueOffline")
            }
            #endif
            Spacer()
        }
        .padding(32)
    }

    private var tagline: some View {
        Text("Sign in to back up your animals, recordings and tags.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.email]
            do {
                // Apple gets the digest; the raw nonce stays inside AuthService.
                request.nonce = try auth.beginSignIn()
            } catch {
                auth.abortSignIn(message: "Could not start sign-in securely on this device. Try again.")
            }
        } onCompletion: { result in
            handle(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 48)
        .disabled(auth.isWorking || !auth.isConfigured)
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            Task {
                do {
                    try await auth.signInWithApple(authorization: authorization)
                } catch {
                    auth.message = (error as? LocalizedError)?.errorDescription
                        ?? "Could not sign in. Try again."
                }
            }
        case .failure(let error):
            // A cancel is not an error worth shouting about, but the pending nonce still has to go.
            if (error as? ASAuthorizationError)?.code == .canceled {
                auth.abortSignIn(message: "")
                auth.message = nil
            } else {
                auth.abortSignIn(message: "Could not sign in. Try again.")
            }
        }
    }
}
