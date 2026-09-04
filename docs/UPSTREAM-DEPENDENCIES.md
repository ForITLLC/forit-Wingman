# Upstream dependencies inherited from farzaa/clicky

Wingman is a fork of [farzaa/clicky](https://github.com/farzaa/clicky) (MIT, upstream
snapshot `a80fa80`). This file is the inventory of every external thing the upstream
app calls out to, keyed by the ForIT decision on each: **STOP** (must not be called from
Wingman), **REPLACE** (same capability on ForIT-controlled infrastructure), or
**KEEP** (a neutral build-time dependency that ships no data anywhere).

Nothing in this list may remain in a Wingman build unless its row says KEEP.

## Runtime calls the app makes

| # | What | Where in upstream | Who receives the data | Decision |
|---|------|-------------------|-----------------------|----------|
| 1 | Relay base URL `https://your-worker-name.your-subdomain.workers.dev` (placeholder for Farza's Cloudflare Worker). Routes `/chat`, `/tts`, `/transcribe-token`. | `CompanionManager.swift:73`, `AssemblyAIStreamingTranscriptionProvider.swift:22` | A Cloudflare Worker outside ForIT control | **REPLACE** with the ForIT relay (see `.ai/decisions.md` 001). Cloudflare Workers are not ForIT platform standard (Azure first). |
| 2 | Anthropic Messages API via the Worker (`api.anthropic.com/v1/messages`, key `ANTHROPIC_API_KEY` as a Worker secret). Screenshots of the user's screen and the voice transcript are sent here. | `worker/src/index.ts:54` | Anthropic, billed to the Worker owner's key | **REPLACE**: same API, called only from the ForIT relay with a ForIT key held in Key Vault. Never a key in the app. |
| 3 | ElevenLabs TTS via the Worker (`api.elevenlabs.io/v1/text-to-speech/{voiceId}`, key `ELEVENLABS_API_KEY`, voice id `kPzsL2i3teMYv0FxEYQ6` baked into `wrangler.toml`). Every spoken response goes here. | `worker/src/index.ts:114`, `worker/wrangler.toml:5`, `ElevenLabsTTSClient.swift` | ElevenLabs | **REPLACE** behind the ForIT relay as one pluggable TTS provider; on-device `AVSpeechSynthesizer` is the zero-vendor default until a ForIT ElevenLabs key exists. No new paid signup. |
| 4 | AssemblyAI real-time streaming STT: temp token from the Worker (`streaming.assemblyai.com/v3/token`, key `ASSEMBLYAI_API_KEY`), then a direct websocket from the app to AssemblyAI carrying the microphone audio. | `worker/src/index.ts:84`, `AssemblyAIStreamingTranscriptionProvider.swift` | AssemblyAI | **REPLACE** behind the ForIT relay as one pluggable STT provider; on-device Apple Speech (`AppleSpeechTranscriptionProvider.swift`, already in tree) is the zero-vendor default. |
| 5 | OpenAI chat completions (`api.openai.com/v1/chat/completions`) — alternate vision model client. | `OpenAIAPI.swift:17` | OpenAI | **STOP** — delete. Phase-1 constraint: no OpenAI/Gemini dependency. |
| 6 | OpenAI audio transcription upload (`api.openai.com/v1/audio/transcriptions`) — STT fallback. | `OpenAIAudioTranscriptionProvider.swift:66`, `BuddyTranscriptionProvider.swift:35-79` | OpenAI | **STOP** — delete the provider and the `openai` case. |
| 7 | PostHog analytics (`https://us.i.posthog.com`, project key `phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C`). Fires on app open, every push-to-talk, every message, every error; `identify()` with the user's email. | `ClickyAnalytics.swift:17-21`, `CompanionManager.swift:161`, SPM package `posthog-ios` | Farza's PostHog project | **STOP** — remove the SPM package and the key; keep the event surface as a local no-op logger so call sites stay intact. Any future telemetry goes to ForIT-owned App Insights. |
| 8 | FormSpark email capture (`https://submit-form.com/RWbGJxmIs`) — the onboarding "enter your email" step posts the user's email here. | `CompanionManager.swift:167` | Farza's FormSpark form | **STOP** — delete. Identity comes from Entra sign-in, not an email box. |
| 9 | Mux-hosted onboarding video (`https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8`). | `CompanionManager.swift:830` | Mux (Farza's account) | **STOP** — remove the video step; Wingman onboarding is permissions + sign-in. |
| 10 | Sparkle auto-update feed `https://raw.githubusercontent.com/julianjear/makesomething-mac-app/main/appcast.xml` with the upstream EdDSA public key `/l3d2rw5ZZFRU3AadP/w2Zf8FHfhA6bKv16BQOV5OSk=`; `appcast.xml` in the tree lists `makesomething.dmg` releases from `julianjear/makesomething-mac-app`. (Updater start is commented out upstream, but the feed and key ship in Info.plist.) | `Info.plist:7-10`, `appcast.xml`, `leanring_buddyApp.swift:75-87` | A third party's GitHub repo; a third party's signing key would be trusted for updates | **REPLACE**: feed → `ForITLLC/forit-Wingman` `appcast.xml`, a ForIT-generated EdDSA key pair (public key in Info.plist, private key only in GitHub Actions secrets). |
| 11 | Login-item registration (`SMAppService.mainApp`) — auto-launch at login. | `leanring_buddyApp.swift:61-71` | Local only | **KEEP** (local OS feature, no data leaves the Mac). |

## Build-time / release-time dependencies

| # | What | Where | Decision |
|---|------|-------|----------|
| 12 | Apple Developer Team IDs `6D7X9GGZAW` and `2UDAY4J48G` (Farza's / contributors' teams) in signing settings. | `project.pbxproj:320,384,414,452,487,508,528,547` | **STOP** — strip; CI signs ad-hoc. A ForIT Developer ID is a Ben credential step (notarization), never worked around. |
| 13 | Bundle identifiers `com.yourcompany.leanring-buddy` (+ `Tests`, `UITests`). | `project.pbxproj:431,469,491,512,531,550` | **REPLACE** with `io.forit.wingman` (+ `.tests`, `.uitests`). |
| 14 | Product / display name `Clicky`, target names `leanring-buddy*`, scheme `leanring-buddy`, module `leanring_buddy`. | `project.pbxproj`, all Swift file headers, `leanring-buddyTests/*.swift` | **REPLACE** with `Wingman` end to end. |
| 15 | Release script targets `julianjear/makesomething-mac-app`, app name `makesomething`, Apple notarization profile `AC_PASSWORD`, Sparkle key in a personal Keychain. | `scripts/release.sh:37-47`, `scripts/README.md` | **REPLACE** with the GitHub Actions workflow (`.github/workflows/build.yml`); the script is deleted. |
| 16 | SPM package `sparkle-project/Sparkle` (auto-update framework). | `project.pbxproj:603-610`, `Package.resolved` | **KEEP** (neutral framework; only its feed/key change, rows 10). |
| 17 | SPM package `PostHog/posthog-ios`. | `project.pbxproj:611-618`, `Package.resolved` | **STOP** (row 7). |
| 18 | Cloudflare `wrangler` toolchain and the `worker/` project (`clicky-proxy`). | `worker/package.json`, `worker/wrangler.toml` | **REPLACE** — the relay is re-homed to Azure in the ForIT subscription (decision 001); `worker/` is deleted. |
| 19 | Onboarding image assets for Codex / "makesomething" and `steve.jpg`, Google/Discord logos. | `Assets.xcassets/*codex*`, `*makesomething*`, `steve*`, `google-logo`, `discord-logo` | **STOP** — remove with the upstream onboarding; they are another product's branding. |
| 20 | `clicky-demo.gif`, `dmg-background.png` ("drag to Applications" art with upstream branding), README links to `clicky.so`, `heyclicky.com`, Farza's tweets. | repo root, `README.md` | **REPLACE** with Wingman branding; README rewritten for ForIT. |
| 21 | Tracked personal Xcode user data (`xcuserdata/julianalvarez…`, `thorfinn…`). | `leanring-buddy.xcodeproj/xcuserdata/` | **STOP** — remove from the tree and ignore. |

## What is NOT inherited

- No secrets are in the upstream tree at `a80fa80` (the hardcoded Anthropic key was removed
  upstream in `d86c32f`; the Worker URL is a placeholder). Verified with a tree-wide grep for
  `sk-ant`, `xi-api-key` values, and `phc_` (only the PostHog project key above, which is a
  public write-only key and is removed anyway).
- Upstream has no server-side identity, permissions or tools layer at all. Those are new
  ForIT layers, not replacements (see `docs/ARCHITECTURE.md` and `docs/PERMISSIONS.md`).

## Verification rule

A Wingman build passes this inventory when a grep of the source tree for every STOP/REPLACE
host above (`workers.dev`, `posthog`, `submit-form.com`, `mux.com`, `julianjear`,
`makesomething`, `openai.com`, `com.yourcompany`, `6D7X9GGZAW`, `2UDAY4J48G`) returns only
this file and `.ai/decisions.md`.
