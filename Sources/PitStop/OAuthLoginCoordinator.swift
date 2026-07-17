import Foundation

/// Runs one OAuth re-login end to end. Provider-agnostic; UI actions are
/// injected so the flow is testable. Writes only to the profile slot.
final class OAuthLoginCoordinator {
    struct UI {
        var openURL: @MainActor (URL) -> Void
        /// Show the paste field; return the pasted string, or nil if cancelled.
        var promptPaste: @MainActor () async -> String?
        var loopbackTimeout: TimeInterval = 120
    }

    /// Match the authenticated result to the exact saved target. Email remains
    /// normalized, while provider-specific stable IDs must match when supplied.
    static func identityMatches(target: LoginTarget, _ identity: LoginIdentity) -> Bool {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard norm(target.email) == norm(identity.email) else { return false }
        if let expected = target.accountID, expected != identity.accountID { return false }
        if let expected = target.organizationID?.lowercased(),
           expected != identity.organizationID?.lowercased() { return false }
        return true
    }

    /// Exchange → identity → match → persist. Nothing is written on mismatch.
    func finish(adapter: LoginAdapter, target: LoginTarget,
                code: String, state: String, verifier: String, redirectURI: String) async throws {
        let tokens = try await adapter.exchange(code: code, state: state,
                                                verifier: verifier, redirectURI: redirectURI)
        let identity = try await adapter.identity(from: tokens)
        guard Self.identityMatches(target: target, identity) else {
            throw LoginError.identityMismatch(expected: target, got: identity)
        }
        try await adapter.persist(tokens, target: target)
    }

    /// Full flow: loopback first, then (Claude) paste fallback.
    func run(adapter: LoginAdapter, target: LoginTarget, ui: UI) async throws {
        let pkce = OAuthPKCE.generate()

        // --- Attempt A: loopback ---
        let server = LoopbackServer()
        do {
            try server.start(ports: adapter.loopbackPorts)
        } catch is LoopbackServer.ServerError {
            // No bindable loopback port: fall through to paste if supported.
            if !adapter.supportsPaste { throw LoginError.portUnavailable }
            try await runPaste(adapter: adapter, target: target, pkce: pkce, ui: ui)
            return
        }
        defer { server.stop() }

        let redirectURI = "http://localhost:\(server.port)\(adapter.loopbackPath)"
        let authURL = adapter.authorizeURL(challenge: pkce.challenge, state: pkce.state,
                                           redirectURI: redirectURI, pasteMode: false, target: target)
        await MainActor.run { ui.openURL(authURL) }

        do {
            let cap = try await server.waitForCallback(timeout: ui.loopbackTimeout)
            guard cap.state == pkce.state else { throw LoginError.stateMismatch }
            try await finish(adapter: adapter, target: target,
                             code: cap.code, state: cap.state,
                             verifier: pkce.verifier, redirectURI: redirectURI)
            return
        } catch is LoopbackServer.ServerError {
            // No callback (timeout / socket closed): fall through to paste if the
            // provider supports it. Any other error — state mismatch, identity
            // mismatch, exchange failure — has already propagated out as terminal.
            guard adapter.supportsPaste else { throw LoginError.timedOut }
        }

        server.stop()
        try await runPaste(adapter: adapter, target: target, pkce: pkce, ui: ui)
    }

    /// --- Attempt B: paste (Claude) ---
    private func runPaste(adapter: LoginAdapter, target: LoginTarget,
                          pkce: (verifier: String, challenge: String, state: String), ui: UI) async throws {
        let redirectURI = adapter.pasteRedirectURI
        let authURL = adapter.authorizeURL(challenge: pkce.challenge, state: pkce.state,
                                           redirectURI: redirectURI, pasteMode: true, target: target)
        await MainActor.run { ui.openURL(authURL) }
        let pasted = await ui.promptPaste()   // @MainActor closure; hops to main automatically
        guard let pasted else { throw LoginError.cancelled }
        guard let cap = LoopbackServer.parsePasted(pasted) else {
            throw LoginError.badResponse("Could not read the pasted code")
        }
        guard cap.state == pkce.state else { throw LoginError.stateMismatch }
        try await finish(adapter: adapter, target: target,
                         code: cap.code, state: cap.state,
                         verifier: pkce.verifier, redirectURI: redirectURI)
    }
}
