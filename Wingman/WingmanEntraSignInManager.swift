//
//  WingmanEntraSignInManager.swift
//  Wingman
//
//  Signs the user in with their ForIT Microsoft account (Entra ID, authorization code + PKCE
//  through the system browser) and hands out the two tokens the app needs:
//    - the id_token, presented to the relay as `Authorization: Bearer` for model and speech calls;
//    - the gateway access token (tools.read / tools.write), presented to the for-mcp gateway
//      for tool calls.
//  Only the refresh token is persisted (macOS Keychain); everything else lives in memory and is
//  re-minted on launch. Sign-out wipes both.
//

import AppKit
import AuthenticationServices
import Foundation

struct WingmanSignedInAccount: Equatable {
    let displayName: String
    let emailAddress: String
}

enum WingmanSignInState: Equatable {
    case signedOut
    case signingIn
    case signedIn(WingmanSignedInAccount)
    case failed(String)
}

enum WingmanSignInError: LocalizedError {
    case notSignedIn
    case userCancelled
    case browserCouldNotStart
    case callbackMissingCode
    case stateMismatch
    case identityProviderRejected(statusCode: Int, description: String)
    case tokenResponseMalformed

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Wingman from the menu bar first."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .browserCouldNotStart:
            return "Wingman could not open the sign-in page in your browser."
        case .callbackMissingCode:
            return "The sign-in page returned without a sign-in code."
        case .stateMismatch:
            return "The sign-in response did not match the request Wingman made."
        case .identityProviderRejected(let statusCode, let description):
            return "Microsoft sign-in refused the request (\(statusCode)): \(description)"
        case .tokenResponseMalformed:
            return "Microsoft sign-in returned an unexpected response."
        }
    }
}

/// A closure that yields a token that is valid right now, refreshing first if needed.
typealias WingmanBearerTokenProvider = @MainActor () async throws -> String

@MainActor
final class WingmanEntraSignInManager: NSObject, ObservableObject {
    @Published private(set) var signInState: WingmanSignInState = .signedOut

    var isSignedIn: Bool {
        if case .signedIn = signInState {
            return true
        }
        return false
    }

    var signedInAccount: WingmanSignedInAccount? {
        if case .signedIn(let account) = signInState {
            return account
        }
        return nil
    }

    private struct TokenSet {
        let idToken: String
        let gatewayAccessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let account: WingmanSignedInAccount
    }

    private struct TokenEndpointResponse: Decodable {
        let access_token: String
        let id_token: String
        let refresh_token: String?
        let expires_in: Double
    }

    private struct TokenEndpointErrorResponse: Decodable {
        let error: String?
        let error_description: String?
    }

    private var currentTokenSet: TokenSet?
    private var activeAuthenticationSession: ASWebAuthenticationSession?

    /// Concurrent callers (chat, TTS, tool calls) share one refresh instead of racing the
    /// identity provider with the same refresh token.
    private var refreshTaskInFlight: Task<TokenSet, Error>?

    private let refreshTokenKeychainStore = WingmanKeychainStore(
        service: "io.forit.wingman",
        account: "entra-refresh-token"
    )

    /// Ephemeral: the token endpoint response must never be cached to disk.
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// ASWebAuthenticationSession needs a window to anchor its confirmation sheet to. A menu bar
    /// app has none, so this invisible window stands in for one.
    private lazy var presentationAnchorWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        return window
    }()

    // MARK: - Session lifecycle

    /// On launch: if a refresh token was kept, mint fresh tokens from it silently. Any failure
    /// leaves the user signed out; a revoked or expired refresh token is also removed.
    func restoreSessionIfPossible() async {
        guard currentTokenSet == nil else { return }
        guard let storedRefreshToken = refreshTokenKeychainStore.read() else {
            signInState = .signedOut
            return
        }

        do {
            let restoredTokenSet = try await redeemRefreshToken(storedRefreshToken)
            applyTokenSet(restoredTokenSet)
            print("🔐 Sign-in: restored session for \(restoredTokenSet.account.emailAddress)")
        } catch {
            print("🔐 Sign-in: stored session could not be restored (\(error.localizedDescription)); signing out")
            refreshTokenKeychainStore.delete()
            signInState = .signedOut
        }
    }

    /// Interactive sign-in through the system browser. Safe to call repeatedly; a second call
    /// while one is in progress is ignored.
    func signIn() async {
        guard signInState != .signingIn else { return }
        signInState = .signingIn

        let codeVerifier = WingmanPKCE.makeCodeVerifier()
        let expectedState = WingmanPKCE.makeState()
        let authorizeURL = Self.makeAuthorizeURL(
            codeChallenge: WingmanPKCE.codeChallenge(for: codeVerifier),
            state: expectedState
        )

        do {
            let callbackURL = try await presentAuthenticationSession(startingAt: authorizeURL)
            let authorizationCode = try Self.extractAuthorizationCode(
                fromCallbackURL: callbackURL,
                expectedState: expectedState
            )
            let tokenSet = try await redeemAuthorizationCode(authorizationCode, codeVerifier: codeVerifier)
            applyTokenSet(tokenSet)
            WingmanAnalytics.trackSignedIn()
            print("🔐 Sign-in: signed in as \(tokenSet.account.emailAddress)")
        } catch WingmanSignInError.userCancelled {
            // Keep whatever session existed before the attempt.
            signInState = currentTokenSet.map { .signedIn($0.account) } ?? .signedOut
        } catch {
            print("⚠️ Sign-in failed: \(error.localizedDescription)")
            signInState = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        currentTokenSet = nil
        refreshTaskInFlight?.cancel()
        refreshTaskInFlight = nil
        refreshTokenKeychainStore.delete()
        signInState = .signedOut
        print("🔐 Sign-in: signed out")
    }

    /// Called when the relay or gateway answers 401: the session is gone server-side, so drop
    /// it locally and ask the user to sign in again rather than retrying with the same token.
    func handleUnauthorizedResponse() {
        currentTokenSet = nil
        refreshTokenKeychainStore.delete()
        signInState = .failed("Your ForIT sign-in has expired. Sign in again from the menu bar.")
    }

    // MARK: - Tokens for callers

    func validIdToken() async throws -> String {
        try await validTokenSet().idToken
    }

    func validGatewayAccessToken() async throws -> String {
        try await validTokenSet().gatewayAccessToken
    }

    private func validTokenSet() async throws -> TokenSet {
        guard let tokenSet = currentTokenSet else {
            throw WingmanSignInError.notSignedIn
        }

        // Refresh two minutes early so a token never expires mid-stream.
        let secondsUntilExpiry = tokenSet.expiresAt.timeIntervalSinceNow
        if secondsUntilExpiry > 120 {
            return tokenSet
        }

        guard let refreshToken = tokenSet.refreshToken else {
            throw WingmanSignInError.notSignedIn
        }

        if let refreshTaskInFlight {
            return try await refreshTaskInFlight.value
        }

        let refreshTask = Task { [weak self] () throws -> TokenSet in
            guard let self else { throw WingmanSignInError.notSignedIn }
            return try await self.redeemRefreshToken(refreshToken)
        }
        refreshTaskInFlight = refreshTask
        defer { refreshTaskInFlight = nil }

        do {
            let refreshedTokenSet = try await refreshTask.value
            applyTokenSet(refreshedTokenSet)
            return refreshedTokenSet
        } catch {
            // The refresh token itself was rejected: the session is over.
            handleUnauthorizedResponse()
            throw error
        }
    }

    private func applyTokenSet(_ tokenSet: TokenSet) {
        currentTokenSet = tokenSet
        if let refreshToken = tokenSet.refreshToken {
            refreshTokenKeychainStore.save(refreshToken)
        }
        signInState = .signedIn(tokenSet.account)
    }

    // MARK: - Authorization request

    static func makeAuthorizeURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: WingmanServiceConfiguration.entraAuthorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: WingmanServiceConfiguration.entraClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: WingmanServiceConfiguration.signInRedirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: WingmanServiceConfiguration.signInScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    /// Reads the authorization code out of the redirect. The `state` must be the one this app
    /// generated; an identity-provider error on the redirect is surfaced as a sign-in failure.
    static func extractAuthorizationCode(fromCallbackURL callbackURL: URL, expectedState: String) throws -> String {
        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        if let providerError = queryValue("error") {
            let description = queryValue("error_description") ?? providerError
            throw WingmanSignInError.identityProviderRejected(statusCode: 0, description: description)
        }

        guard queryValue("state") == expectedState else {
            throw WingmanSignInError.stateMismatch
        }

        guard let authorizationCode = queryValue("code"), !authorizationCode.isEmpty else {
            throw WingmanSignInError.callbackMissingCode
        }

        return authorizationCode
    }

    private func presentAuthenticationSession(startingAt authorizeURL: URL) async throws -> URL {
        activeAuthenticationSession?.cancel()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let authenticationSession = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: WingmanServiceConfiguration.signInCallbackURLScheme
            ) { callbackURL, error in
                if let error {
                    let isUserCancellation = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: isUserCancellation ? WingmanSignInError.userCancelled : error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: WingmanSignInError.callbackMissingCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            authenticationSession.presentationContextProvider = self
            // Share the browser's existing Microsoft session so a user already signed in to
            // ForIT M365 in Safari is not asked for a password again.
            authenticationSession.prefersEphemeralWebBrowserSession = false
            activeAuthenticationSession = authenticationSession

            if !authenticationSession.start() {
                continuation.resume(throwing: WingmanSignInError.browserCouldNotStart)
            }
        }
    }

    // MARK: - Token endpoint

    private func redeemAuthorizationCode(_ authorizationCode: String, codeVerifier: String) async throws -> TokenSet {
        try await requestTokens(formFields: [
            "client_id": WingmanServiceConfiguration.entraClientId,
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "redirect_uri": WingmanServiceConfiguration.signInRedirectURI,
            "code_verifier": codeVerifier,
            "scope": WingmanServiceConfiguration.signInScopes.joined(separator: " "),
        ])
    }

    private func redeemRefreshToken(_ refreshToken: String) async throws -> TokenSet {
        try await requestTokens(formFields: [
            "client_id": WingmanServiceConfiguration.entraClientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": WingmanServiceConfiguration.signInScopes.joined(separator: " "),
        ])
    }

    private func requestTokens(formFields: [String: String]) async throws -> TokenSet {
        var request = URLRequest(url: WingmanServiceConfiguration.entraTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formURLEncoded(formFields).utf8)

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WingmanSignInError.tokenResponseMalformed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(TokenEndpointErrorResponse.self, from: responseData)
            let description = errorResponse?.error_description
                ?? errorResponse?.error
                ?? String(data: responseData, encoding: .utf8)
                ?? "no details"
            throw WingmanSignInError.identityProviderRejected(statusCode: httpResponse.statusCode, description: description)
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenEndpointResponse.self, from: responseData) else {
            throw WingmanSignInError.tokenResponseMalformed
        }

        let claims = WingmanIdTokenClaims.parse(tokenResponse.id_token)
        let emailAddress = claims?.emailAddress ?? "unknown account"
        let account = WingmanSignedInAccount(
            displayName: claims?.displayName ?? emailAddress,
            emailAddress: emailAddress
        )

        return TokenSet(
            idToken: tokenResponse.id_token,
            gatewayAccessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresAt: Date().addingTimeInterval(tokenResponse.expires_in),
            account: account
        )
    }

    /// application/x-www-form-urlencoded with the unreserved set only, so `+`, `/` and `=`
    /// inside tokens survive the round trip.
    static func formURLEncoded(_ fields: [String: String]) -> String {
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~")
        return fields
            .sorted(by: { $0.key < $1.key })
            .map { field in
                let encodedValue = field.value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? ""
                return "\(field.key)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

extension WingmanEntraSignInManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // AuthenticationServices calls this on the main thread; the anchor window is main-actor state.
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? presentationAnchorWindow
        }
    }
}
