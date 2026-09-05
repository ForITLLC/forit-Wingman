# Wingman architecture

Wingman is a macOS menu bar voice assistant for ForIT support staff. The user holds ctrl+option, speaks,
and Wingman answers aloud, optionally pointing its blue cursor at something on screen. This page is the
map: which component holds what, and where each byte goes. Product rules (who may do what) are in
[PERMISSIONS.md](PERMISSIONS.md); the reasoning behind the shape is in the decisions log at the repo
root, `.ai/decisions.md`.

## Components

```
┌──────────────────────────────── the user's Mac ────────────────────────────────┐
│  Wingman.app (Swift, menu bar only)                                             │
│   ├─ Apple Speech (on-device)          transcript never leaves the Mac as audio │
│   ├─ ScreenCaptureKit                  JPEG of every display, per question      │
│   ├─ WingmanEntraSignInManager         PKCE sign-in, refresh token in keychain  │
│   ├─ ClaudeAPI  ───────────────────────────────┐                                │
│   ├─ ElevenLabsTTSClient ──────────────────────┤  Bearer: Entra id_token        │
│   └─ WingmanGatewayToolClient ────────┐        │                                │
└───────────────────────────────────────┼────────┼────────────────────────────────┘
                                        │        │
        Bearer: gateway access token    │        ▼
        (scope access_as_user)          │   ForIT relay (Azure Functions, rg-forit-wingman)
                                        │    /api/chat  → api.anthropic.com  (key from Key Vault)
                                        │    /api/tts   → api.elevenlabs.io  (key from Key Vault)
                                        │    stores nothing; one log line per call (user, model, status)
                                        ▼
                                   for-mcp gateway (Container App, MCP Streamable HTTP)
                                    support_listTickets · support_addTicketNote · forit_avops_search_flights
                                    support_searchKbArticles · support_getKbArticle (live since for-Support a24e57f, 2026-09-05)
                                    role check + audit under the signed-in person; tools/list narrows the catalog
```

| Component | Where it runs | Holds | Never holds |
|-----------|---------------|-------|-------------|
| Wingman.app | the user's Mac | Entra refresh token (login keychain), UI preferences | any vendor key, any connection string |
| Relay | Azure Functions `forit-wingman-relay` (compute in Canada Central) | Anthropic and ElevenLabs keys as Key Vault references | transcripts, screenshots, completions, tool results, the gateway token |
| for-mcp gateway | ForIT Container App (owned by for-mcp) | the Support database credentials | — (out of this repo) |

## One spoken question, end to end

1. **Sign-in gate.** Push-to-talk is refused unless `WingmanEntraSignInManager` holds a valid session
   (`CompanionManager.handleShortcutTransition`). Sign-in is authorization-code + PKCE in the system
   browser against the ForIT tenant, client `ForIT-Wingman-Client`. One sign-in returns the id_token
   (audience = that client; the relay's credential) and a gateway access token
   (`api://861db494-…/access_as_user`; the tools credential). The refresh token is the only thing persisted.
2. **Capture.** Apple Speech transcribes on-device while the key is held; on release ScreenCaptureKit
   takes a JPEG of every display, labelled with its pixel size and which one holds the cursor.
3. **Model turn.** `ClaudeAPI.streamTurn` POSTs the conversation to the relay's `/api/chat` with the
   allow-listed tool definitions (five in the catalog, narrowed to what the gateway's `tools/list` exposes). The relay checks the id_token (issuer, audience, signature,
   `@forit.io`), pins the model to its allow-list, adds the Anthropic key and streams the SSE back.
4. **Tool loop** (`CompanionManager.runModelTurnWithGatewayTools`). If the model stops with `tool_use`,
   the app runs each call through `WingmanToolCatalog.prepareCall` (allow-list, argument policy, the
   `DRAFT (Wingman): ` prefix) and `WingmanGatewayToolClient.callTool` (MCP `tools/call` with the user's
   gateway token). Results go back as `tool_result` blocks and the model is called again; four rounds at
   most, then one forced answer. A gateway 401 or 403 ends the turn with a fixed spoken refusal instead.
5. **Speak and point.** The final text is split into the spoken part and the `[POINT:…]` tag. Speech
   goes through the relay's `/api/tts` (ElevenLabs) or the on-device synthesiser when the relay has no
   voice configured. The overlay flies the cursor to the pointed element on the right display.
6. **Remember.** Only the transcript and the spoken reply are kept (last ten exchanges, in memory).
   Screenshots and tool rounds are not carried into later turns.

## Identity and access

| Token | Issued to | Audience | Used for | Checked by |
|-------|-----------|----------|----------|------------|
| id_token | ForIT-Wingman-Client (`acc81527…`) | that client id | relay `/api/chat`, `/api/tts` | relay (`relay/src/entraToken.ts`): ForIT tenant issuer, JWKS signature, `@forit.io` email |
| access token | same sign-in | for-mcp gateway (`861db494…`), scope `access_as_user` | gateway `tools/call` | gateway: allow-listed client, the user's app role (Reader / Writer / Admin → `tools.read` / `tools.write` / `tools.admin`) |

Interim rule while Support is @forit.io-only: the relay's `WINGMAN_ALLOWED_EMAIL_DOMAINS` is `forit.io`.
Nothing in the app decides who is allowed; the relay and the gateway do.

## Repository layout

| Path | What |
|------|------|
| `Wingman/` | the macOS app (SwiftUI + AppKit bridging); see the key-files table in `AGENTS.md` |
| `WingmanTests/` | Swift Testing unit tests for the pure parts (sign-in helpers, tool policy, stream parsing) |
| `relay/src/` | the Azure Functions relay (TypeScript, Node 22); `*.test.ts` beside the sources |
| `relay/infra/main.bicep` | relay infrastructure; Key Vault is `existing`, compute defaults to `canadacentral` |
| `.github/workflows/ci.yml` | app build + tests on a macOS runner (unsigned) |
| `.github/workflows/relay.yml`, `relay-deploy.yml` | relay tests on PRs; Bicep + code deploy on `main` via OIDC |
| `docs/PERMISSIONS.md` | who may do what, the tool allow-list, refusals, known gaps |
| `.ai/decisions.md` | numbered architecture decisions with context and consequences |

## Build and deploy

- **App**: Xcode 16, scheme `Wingman`; CI builds and runs the tests on every PR. Local `xcodebuild` is
  avoided on developer Macs because it invalidates TCC permissions (`AGENTS.md`).
- **Relay**: `cd relay && npm test` runs the TypeScript build and the tests. Merging to `main` runs
  `relay-deploy.yml`: Bicep to `rg-forit-wingman`, then the Functions package. `GET /api/health` reports
  the deployed commit.
