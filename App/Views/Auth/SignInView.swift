import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("AnimalTracker")
                .font(.largeTitle.bold())
            Text("Sign in to back up your animals, recordings and tags.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !auth.isConfigured {
                Text("This build has no Supabase key, so sign-in is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
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
            if let message = auth.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            #if DEBUG
            Button("Continue offline") { auth.continueOffline() }
                .font(.footnote)
                .accessibilityIdentifier("continueOffline")
            #endif
            Spacer()
        }
        .padding(32)
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
