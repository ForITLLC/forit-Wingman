//
//  WingmanSignInSupport.swift
//  Wingman
//
//  Pure helpers behind the Entra sign-in: PKCE values, id_token claim reading, and the
//  keychain slot for the refresh token. Kept free of AppKit so they are unit-testable.
//

import CryptoKit
import Foundation
import Security

// MARK: - PKCE (RFC 7636)

enum WingmanPKCE {
    /// 32 random bytes, base64url-encoded: a 43-character verifier from the unreserved set.
    static func makeCodeVerifier() -> String {
        base64URLEncodedString(randomBytes(count: 32))
    }

    /// S256 challenge: base64url(SHA-256(verifier)).
    static func codeChallenge(for codeVerifier: String) -> String {
        let verifierDigest = SHA256.hash(data: Data(codeVerifier.utf8))
        return base64URLEncodedString(Data(verifierDigest))
    }

    /// Opaque value echoed back on the redirect so a callback can be matched to the request
    /// that started it (and a stray or forged redirect can be discarded).
    static func makeState() -> String {
        base64URLEncodedString(randomBytes(count: 16))
    }

    static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecodedData(_ base64URLString: String) -> Data? {
        var base64String = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingNeeded = (4 - base64String.count % 4) % 4
        base64String += String(repeating: "=", count: paddingNeeded)
        return Data(base64Encoded: base64String)
    }

    private static func randomBytes(count: Int) -> Data {
        var randomBytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &randomBytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes only fails if the system RNG is unavailable; fall back to the
            // Swift system generator rather than returning zeros.
            randomBytes = (0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(randomBytes)
    }
}

// MARK: - id_token claims (display only)

/// The few id_token claims the app shows in the panel. The app does not verify the signature:
/// the relay does that on every request. These values are for labelling the signed-in account.
struct WingmanIdTokenClaims: Equatable {
    let displayName: String?
    let emailAddress: String?
    let expiresAt: Date?

    static func parse(_ idToken: String) -> WingmanIdTokenClaims? {
        let tokenSegments = idToken.split(separator: ".")
        guard tokenSegments.count == 3,
              let payloadData = WingmanPKCE.base64URLDecodedData(String(tokenSegments[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        let emailAddress = (payload["preferred_username"] as? String)
            ?? (payload["email"] as? String)
            ?? (payload["upn"] as? String)

        var expiresAt: Date?
        if let expirySeconds = payload["exp"] as? TimeInterval {
            expiresAt = Date(timeIntervalSince1970: expirySeconds)
        }

        return WingmanIdTokenClaims(
            displayName: payload["name"] as? String,
            emailAddress: emailAddress,
            expiresAt: expiresAt
        )
    }
}

// MARK: - Keychain slot for the refresh token

/// One generic-password item in the login keychain. Only the refresh token is stored; id and
/// access tokens stay in memory and are re-minted from it on launch.
///
/// The item is created with an access list that lets any application on this Mac read it, so
/// no launch ever shows the "Wingman wants to use your confidential information" dialog. The
/// login keychain grants silent access by the reader's code signature, and the interim
/// self-signed certificate is not one securityd trusts: on Ben's Mac every launch prompted,
/// "Always Allow" did not carry to the next launch even of the same build, and a dialog nobody
/// answered blocked the launch (`.ai/decisions.md` 014). The protection left is the keychain
/// itself (encrypted at rest, locked with the login keychain), the same posture as a token file
/// readable only by this user. Move to the data protection keychain once a ForIT Developer ID
/// gives the app a Team ID.
struct WingmanKeychainStore: Sendable {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) {
        // Replace rather than update so a value written by an older build with different
        // attributes (or a stricter access list) never leaves two items behind.
        delete()
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(value.utf8)
        if let accessWithoutPrompt = makeAccessAllowingAnyApplication() {
            addQuery[kSecAttrAccess as String] = accessWithoutPrompt
        }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain: could not store the refresh token (OSStatus \(status)); the user will sign in again next launch")
        }
    }

    /// An access list with no trusted-application restriction: every application running as
    /// this user may read the item without a dialog. A nil trusted list is how the Security
    /// framework spells "any application" (`SecAccessCreate`). Falls back to the default list
    /// (this build only, prompts for every other build) if the framework refuses.
    private func makeAccessAllowingAnyApplication() -> SecAccess? {
        var access: SecAccess?
        let status = SecAccessCreate("Wingman sign-in" as CFString, nil, &access)
        guard status == errSecSuccess, let access else {
            print("⚠️ Keychain: could not create the open access list (OSStatus \(status)); the default list will prompt other builds")
            return nil
        }
        return access
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
