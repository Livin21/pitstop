import Foundation

/// Fresh tokens from an authorization_code exchange, provider-neutral.
struct FreshTokens {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?        // Codex
    var expiresAtMs: Double?    // Claude (Codex derives expiry from the id_token)
}

/// The authenticated identity, for matching against the target row.
struct LoginIdentity: Equatable {
    var email: String
    var accountID: String?      // Codex chatgpt_account_id
    var organizationID: String? // Claude organization UUID
}

/// The saved row an OAuth flow is allowed to heal. `credentialAccount` is
/// intentionally independent from identity so legacy email-keyed Claude
/// snapshots can be retained without collisions for newly captured orgs.
struct LoginTarget: Equatable {
    var email: String
    var accountID: String? = nil
    var organizationID: String? = nil
    var credentialAccount: String
}

enum LoginError: LocalizedError {
    case identityMismatch(expected: LoginTarget, got: LoginIdentity)
    case noSavedProfile(String)
    case stateMismatch
    case cancelled
    case timedOut
    case portUnavailable
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .identityMismatch(let expected, let got):
            if expected.email.caseInsensitiveCompare(got.email) == .orderedSame,
               expected.organizationID != nil {
                return "You signed in to a different Claude organization for \(got.email). "
                    + "Choose the row's organization and try again."
            }
            return "You signed in as \(got.email), but this row is \(expected.email). "
                + "Switch accounts in your browser and try again."
        case .noSavedProfile(let email): return "No saved profile for \(email)."
        case .stateMismatch: return "Sign-in could not be verified (state mismatch)."
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out waiting for the browser."
        case .portUnavailable:
            return "A sign-in may already be in progress — finish or cancel it and retry."
        case .badResponse(let why): return "Sign-in failed: \(why)"
        }
    }
}

/// The provider-varying surface of the OAuth login flow.
protocol LoginAdapter {
    var provider: Provider { get }
    /// Loopback ports to try (Codex: fixed 1455/1457; Claude: a candidate list).
    var loopbackPorts: [UInt16] { get }
    var loopbackPath: String { get }
    /// Whether a code-paste fallback exists (Claude yes, Codex no).
    var supportsPaste: Bool { get }
    /// Hosted redirect used in paste mode (unused when !supportsPaste).
    var pasteRedirectURI: String { get }

    func authorizeURL(challenge: String, state: String, redirectURI: String,
                      pasteMode: Bool, target: LoginTarget) -> URL
    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens
    func identity(from tokens: FreshTokens) async throws -> LoginIdentity
    /// Patch the existing saved blob with fresh tokens. Pure, for testing.
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data
    /// Read the saved profile blob, patch it, and write it back to the profile
    /// slot only. Throws `.noSavedProfile` if there is nothing to heal.
    func persist(_ tokens: FreshTokens, target: LoginTarget) async throws
}
