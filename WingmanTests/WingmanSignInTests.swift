//
//  WingmanSignInTests.swift
//  WingmanTests
//
//  Covers the pure parts of the Entra sign-in: PKCE, redirect parsing, id_token claim reading,
//  form encoding, and the model allow-list mapping. Nothing here touches the network or keychain.
//

import Foundation
import Testing
@testable import Wingman

@MainActor
struct WingmanSignInTests {

    // RFC 7636 appendix B reference vector.
    @Test func pkceChallengeMatchesTheRFCReferenceVector() {
        let referenceVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(WingmanPKCE.codeChallenge(for: referenceVerifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceVerifierIsFortyThreeUnreservedCharactersAndUnique() {
        let firstVerifier = WingmanPKCE.makeCodeVerifier()
        let secondVerifier = WingmanPKCE.makeCodeVerifier()
        let unreservedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

        #expect(firstVerifier.count == 43)
        #expect(firstVerifier.unicodeScalars.allSatisfy { unreservedCharacters.contains($0) })
        #expect(firstVerifier != secondVerifier)
    }

    @Test func authorizeURLCarriesPKCEAndTheForITScopes() throws {
        let authorizeURL = WingmanEntraSignInManager.makeAuthorizeURL(codeChallenge: "challenge-value", state: "state-value")
        let queryItems = try #require(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        func queryValue(_ name: String) -> String? { queryItems.first(where: { $0.name == name })?.value }

        #expect(authorizeURL.host == "login.microsoftonline.com")
        #expect(authorizeURL.path.contains(WingmanServiceConfiguration.entraTenantId))
        #expect(queryValue("client_id") == WingmanServiceConfiguration.entraClientId)
        #expect(queryValue("code_challenge") == "challenge-value")
        #expect(queryValue("code_challenge_method") == "S256")
        #expect(queryValue("state") == "state-value")
        #expect(queryValue("redirect_uri") == "msauth.io.forit.wingman://auth")
        #expect(queryValue("scope")?.contains("api://861db494-6d36-4d7d-83c4-39352d3e9576/tools.read") == true)
        #expect(queryValue("scope")?.contains("offline_access") == true)
    }

    @Test func redirectWithMatchingStateYieldsTheCode() throws {
        let callbackURL = try #require(URL(string: "msauth.io.forit.wingman://auth?code=abc123&state=expected&session_state=ignored"))
        let authorizationCode = try WingmanEntraSignInManager.extractAuthorizationCode(fromCallbackURL: callbackURL, expectedState: "expected")
        #expect(authorizationCode == "abc123")
    }

    @Test func redirectWithForeignStateIsRefused() throws {
        let callbackURL = try #require(URL(string: "msauth.io.forit.wingman://auth?code=abc123&state=someone-elses"))
        #expect(throws: WingmanSignInError.self) {
            try WingmanEntraSignInManager.extractAuthorizationCode(fromCallbackURL: callbackURL, expectedState: "expected")
        }
    }

    @Test func redirectCarryingAnIdentityProviderErrorIsSurfaced() throws {
        let callbackURL = try #require(URL(string: "msauth.io.forit.wingman://auth?error=access_denied&error_description=AADSTS65004&state=expected"))
        #expect(throws: WingmanSignInError.self) {
            try WingmanEntraSignInManager.extractAuthorizationCode(fromCallbackURL: callbackURL, expectedState: "expected")
        }
    }

    @Test func idTokenClaimsAreReadForDisplay() throws {
        let payload: [String: Any] = [
            "name": "Ben Thomas",
            "preferred_username": "b.thomas@forit.io",
            "exp": 1_893_456_000,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let unsignedToken = "eyJhbGciOiJub25lIn0.\(WingmanPKCE.base64URLEncodedString(payloadData)).signature"

        let claims = try #require(WingmanIdTokenClaims.parse(unsignedToken))
        #expect(claims.displayName == "Ben Thomas")
        #expect(claims.emailAddress == "b.thomas@forit.io")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 1_893_456_000))
    }

    @Test func malformedIdTokenParsesToNil() {
        #expect(WingmanIdTokenClaims.parse("not-a-token") == nil)
        #expect(WingmanIdTokenClaims.parse("a.b.c") == nil)
    }

    @Test func formEncodingKeepsTokenCharactersIntact() {
        let encoded = WingmanEntraSignInManager.formURLEncoded(["refresh_token": "abc+/=def", "grant_type": "refresh_token"])
        #expect(encoded == "grant_type=refresh_token&refresh_token=abc%2B%2F%3Ddef")
    }

    @Test func storedModelPreferenceIsMappedOntoTheRelayAllowList() {
        #expect(WingmanServiceConfiguration.normalisedModelId(nil) == "claude-sonnet-5")
        #expect(WingmanServiceConfiguration.normalisedModelId("claude-sonnet-4-6") == "claude-sonnet-5")
        #expect(WingmanServiceConfiguration.normalisedModelId("claude-opus-5") == "claude-opus-5")
    }
}
