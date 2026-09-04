//
//  WingmanServiceConfiguration.swift
//  Wingman
//
//  The ForIT endpoints and public identifiers the app talks to. Everything here is
//  public by design (tenant id, client id, hostnames); there is no secret in the app.
//  The Anthropic and ElevenLabs keys live only in Key Vault behind the relay
//  (.ai/decisions.md 001).
//

import Foundation

enum WingmanServiceConfiguration {
    // MARK: - Entra sign-in (ForIT tenant, "ForIT Wingman" public client)

    static let entraTenantId = "c0efa09e-4bda-4a9d-a177-4c77076b7f76"
    static let entraClientId = "36021471-d468-4f12-9c83-e5a73f957752"

    /// Registered on the Entra app as a public-client redirect. The scheme is also declared in
    /// Info.plist (CFBundleURLTypes) so macOS routes the browser's redirect back to this app.
    static let signInRedirectURI = "msauth.io.forit.wingman://auth"
    static let signInCallbackURLScheme = "msauth.io.forit.wingman"

    /// The for-mcp gateway's application id URI. Tool calls carry the user's own delegated
    /// token for this audience; the relay never sees it.
    static let gatewayApplicationIdURI = "api://861db494-6d36-4d7d-83c4-39352d3e9576"

    /// One sign-in yields both tokens the app needs: the id_token (audience = this client,
    /// presented to the relay) and an access token for the gateway (tools.read / tools.write).
    /// `offline_access` is what returns the refresh token that keeps the user signed in.
    static let signInScopes: [String] = [
        "openid",
        "profile",
        "email",
        "offline_access",
        "\(gatewayApplicationIdURI)/tools.read",
        "\(gatewayApplicationIdURI)/tools.write",
    ]

    static var entraAuthorizeEndpoint: URL {
        URL(string: "https://login.microsoftonline.com/\(entraTenantId)/oauth2/v2.0/authorize")!
    }

    static var entraTokenEndpoint: URL {
        URL(string: "https://login.microsoftonline.com/\(entraTenantId)/oauth2/v2.0/token")!
    }

    // MARK: - Relay (Azure Functions, rg-forit-wingman)

    private static let productionRelayBaseURLString = "https://forit-wingman-relay.azurewebsites.net"

    /// A developer running the relay locally (`npx func start`) can point a debug build at it by
    /// adding `WingmanRelayBaseURL` to Info.plist. Release builds carry no such key.
    static var relayBaseURL: URL {
        if let overrideBaseURLString = AppBundleConfiguration.stringValue(forKey: "WingmanRelayBaseURL"),
           let overrideBaseURL = URL(string: overrideBaseURLString) {
            return overrideBaseURL
        }
        return URL(string: productionRelayBaseURLString)!
    }

    static var relayChatURL: URL {
        relayBaseURL.appendingPathComponent("api/chat")
    }

    static var relayTTSURL: URL {
        relayBaseURL.appendingPathComponent("api/tts")
    }

    // MARK: - Models

    /// The relay pins requests to its own allow-list (WINGMAN_ALLOWED_MODELS); this is the
    /// matching list the panel offers. Anything else the app asks for becomes the relay default.
    static let selectableModels: [(label: String, modelId: String)] = [
        (label: "Sonnet", modelId: "claude-sonnet-5"),
        (label: "Opus", modelId: "claude-opus-5"),
    ]

    static let defaultModelId = "claude-sonnet-5"

    /// Maps whatever was persisted (possibly a model id from an earlier build) onto a model the
    /// relay accepts, so a stale preference never produces a silent fallback on the server.
    static func normalisedModelId(_ storedModelId: String?) -> String {
        guard let storedModelId,
              selectableModels.contains(where: { $0.modelId == storedModelId }) else {
            return defaultModelId
        }
        return storedModelId
    }
}
