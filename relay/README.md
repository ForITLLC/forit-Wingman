# Wingman relay

Azure Functions app (`forit-wingman-relay`, Node 22, TypeScript) in `rg-forit-wingman`, subscription
`147a19b0-f6a7-4b0b-89e9-49f4aabd1435`. It is the only thing the desktop app talks to for model and
speech calls. It holds the vendor keys (as Key Vault references) so the app never does, and it
proves who is calling on every request. Decision record: `.ai/decisions.md` 001.

## Routes

| Route | Auth | What it does |
|-------|------|--------------|
| `GET /api/health` | none | Reports `version` (git sha), provider, allowed models, and whether the model and TTS keys resolved. No secrets. |
| `POST /api/chat` | Entra id_token | Validates the request, pins the model to the allow-list, forwards the Anthropic Messages body with the ForIT key, streams the SSE back unchanged. Stores nothing. |
| `POST /api/tts` | Entra id_token | ElevenLabs text-to-speech with a fixed server-side voice. Answers `501 tts_not_configured` when no key or voice is set, and the app uses on-device speech instead. |

## Authentication

The app signs the user in with the Entra public client **ForIT Wingman**
(**ForIT-Wingman-Client**, `acc81527-1818-4c79-8f59-0bfc111701d4`, PKCE, redirect `msauth.io.forit.wingman://auth`) and sends
the id_token as `Authorization: Bearer`. `src/entraToken.ts` checks the RS256 signature against the
ForIT tenant keys, the audience (that client id), the validity window, and that the account's email
domain is on `WINGMAN_ALLOWED_EMAIL_DOMAINS` (`forit.io` for now; see `docs/PERMISSIONS.md` 5.1).
Nothing else in the request identifies the caller.

Tool calls do not pass through here. The app calls the for-mcp gateway directly with the user's own
delegated token (`tools.read`, `tools.write` on `api://861db494-6d36-4d7d-83c4-39352d3e9576`).

## Configuration

| Setting | Source | Purpose |
|---------|--------|---------|
| `ANTHROPIC_API_KEY` | Key Vault reference to `kv-forit-wingman/anthropic-api-key` | Model key ForIT already held on `forit-ai-engine`. |
| `ELEVENLABS_API_KEY` | Key Vault reference to `kv-forit-wingman/elevenlabs-api-key` | TTS key, same provenance. |
| `ELEVENLABS_VOICE_ID` | repo variable `WINGMAN_ELEVENLABS_VOICE_ID` | Empty disables TTS. |
| `WINGMAN_ENTRA_CLIENT_ID` | repo variable `WINGMAN_ENTRA_CLIENT_ID` | Expected `aud`. |
| `WINGMAN_ALLOWED_EMAIL_DOMAINS` | Bicep default `forit.io` | Interim access rule. |
| `WINGMAN_ALLOWED_MODELS` / `WINGMAN_DEFAULT_MODEL` | Bicep defaults | `claude-sonnet-5,claude-opus-5` / `claude-sonnet-5`. Changing the model is a relay setting, not an app release. |
| `RELAY_VERSION` | deploy workflow | Commit sha; the pipeline asserts it after deploy. |

Key rotation: write the new value to `kv-forit-wingman` (a new secret version), restart the app.
The bootstrap copy from `forit-ai-engine` was done once by a Global Administrator through the
`mm_run` Azure module without the value ever being printed; repeat that command to re-copy.

## Local development

```bash
cd relay
npm install
npm test                      # tsc + node --test
cp local.settings.example.json local.settings.json   # fill in a local key; the file is git-ignored
npx func start                # needs Azure Functions Core Tools v4
```

## Deploy

`.github/workflows/relay-deploy.yml`: `build` (npm ci, tests, zip) on every PR and push;
`deploy` only on `main`, with OIDC login as **GitHub Actions - ForIT Wingman**
(`fca3bde8-953a-4beb-bcce-18c7b5cb3a71`; Contributor + RBAC Administrator on `rg-forit-wingman`
only), then `az deployment group create` with `infra/main.bicep`, Kudu zip deploy, and a health
check that fails the run unless the live `version` equals the commit and `chatConfigured` is true.
