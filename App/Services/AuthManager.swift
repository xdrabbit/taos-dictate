import Foundation
import Auth

/// Sign-in against the same Supabase project as taoslite.com.
/// Email code (OTP), existing TAOS accounts only. The SDK keeps the session in the
/// Keychain (KeychainLocalStorage) and refreshes the access token itself.
@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable { case loading, signedOut, signedIn(email: String) }

    @Published private(set) var state: State = .loading

    let client: AuthClient

    init() {
        client = AuthClient(configuration: .init(
            url: TaosConfig.supabaseURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": TaosConfig.supabaseKey],
            localStorage: KeychainLocalStorage(),
            emitLocalSessionAsInitialSession: true
        ))
        Task { await listen() }
    }

    private func listen() async {
        // The stored session is emitted first, even if its access token has expired;
        // the SDK refreshes it, and a refresh that fails emits a signed-out event.
        for await (_, session) in client.authStateChanges {
            if let session {
                state = .signedIn(email: session.user.email ?? "")
            } else {
                state = .signedOut
            }
        }
    }

    /// Sends the code. `shouldCreateUser: false` — the app signs in existing TAOS accounts only.
    func sendCode(to email: String) async throws {
        try await client.signInWithOTP(email: email, shouldCreateUser: false)
    }

    func verify(email: String, code: String) async throws {
        _ = try await client.verifyOTP(email: email, token: code, type: .email)
    }

    func signOut() async {
        try? await client.signOut(scope: .local)
        state = .signedOut
    }

    /// Called when the server still says 401 after a refresh.
    func sessionRejected() {
        Task { await signOut() }
    }

    var tokenProvider: TokenProvider { SupabaseTokens(client: client) }
}

/// Hands the API client a valid access token. `session` refreshes an expired one;
/// after a 401 we force a refresh, as the contract asks.
struct SupabaseTokens: TokenProvider {
    let client: AuthClient

    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { return try await client.refreshSession().accessToken }
        return try await client.session.accessToken
    }
}
