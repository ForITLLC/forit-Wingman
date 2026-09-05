# Wingman - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

ForIT's macOS menu bar voice assistant for support work, derived from Clicky (MIT, see NOTICE). Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device with Apple Speech, and sends the transcript + a screenshot of the user's screen to Claude through the ForIT relay. Claude responds with text (streamed via SSE) and voice (ElevenLabs through the relay, on-device speech when the relay has no voice configured). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

The user signs in with their ForIT (Entra) account. Every relay call carries that sign-in; the relay holds the vendor keys in Azure Key Vault and nothing sensitive ships in the app. Without a signed-in account the app captures nothing and sends nothing.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **Sign-in**: Microsoft Entra authorization-code + PKCE in the system browser (`WingmanEntraSignInManager.swift`), custom URL scheme `msauth.io.forit.wingman://auth`, refresh token in the login keychain. The id_token is the bearer for the relay; a gateway access token (`api://861db494-…/access_as_user`, client `acc81527-…`, see for-mcp `docs/native-clients.md`) is minted for the for-mcp tools layer.
- **AI Chat**: Claude (Sonnet 5 default, Opus 5 optional; allow-list in `WingmanServiceConfiguration.swift`) via the ForIT relay `/api/chat` with SSE streaming. Each spoken question runs a tool loop (`CompanionManager.runModelTurnWithGatewayTools`): the model may call the allow-listed gateway tools, the app executes them and feeds `tool_result` blocks back, at most four rounds, then a forced spoken answer.
- **Speech-to-Text**: on-device Apple Speech only (`AppleSpeechTranscriptionProvider.swift`); audio never leaves the Mac
- **Text-to-Speech**: ElevenLabs via the relay `/api/tts`; `AVSpeechSynthesizer` on-device when the relay answers 501 (no voice configured). Replies are spoken sentence by sentence while the model is still streaming: `WingmanSpokenSentenceSplitter` cuts the accumulated text at sentence boundaries (never from `[POINT` onward), `ElevenLabsTTSClient` queues each sentence, fetches at most two ahead and plays them in order, and the turn waits on `finishEnqueuedSpeech()`. The push-to-talk key-down also wakes the relay (`ClaudeAPI.warmUpRelay`, GET `/api/health`, once a minute) and starts a background `tools/list` refresh when the 15-minute cache is stale.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: local debug log only via `WingmanAnalytics.swift` (no third-party SDK; nothing leaves the machine). A tool that ran and failed logs `tool_error_http_NNN` when the gateway's error text names an HTTP status (`WingmanGatewayToolClient.failureOutcomeLabel`), so the Mac log says why without holding the body.
- **Taught vocabulary** (`WingmanVocabulary.swift`, 2026-09-05, Ben: "fl3xx is Flex, how can we train on that? … it could be any vocabulary that we could teach"): each term has a canonical spelling, spoken forms and a meaning, edited in the panel's Vocabulary section and stored as JSON in Application Support (seeded with `FL3XX` said as "Flex"). Applied on the Mac in four places: the spellings and spoken forms are Apple Speech contextual keyterms; the final transcript has every spoken form rewritten to the canonical spelling (whole words, longest first) before the model sees it; the system prompt gains a vocabulary section; and each sentence handed to text-to-speech has the canonical spelling rewritten to the first spoken form, so the voice says "Flex" while the screen shows `FL3XX`. `WingmanToolCatalog.prepareCall` takes the vocabulary and sends a knowledge base search whose tenant is a vocabulary term to the default tenant instead.
- **Colours**: the accent and the overlay cursor are the ForIT brand cyan `#8EDCEF` with brand navy `#142F43` as the text on it (`DS.Colors.foritCyan`, `foritNavy`, `overlayCursorColor`; Ben, 2026-09-05: "make the blue for Wingman one of the ForIT colors"). The upstream Tailwind blue scale is still declared but no longer drives the accent. The app icon and the menu bar glyph (2026-09-05, Ben: "should we make the icon on this, like the ForIT icon, with an arrow on top", then, once the pointer became the mark, "I need you to also update the menu bar icon and the app icon") are the ForIT mark alone, turned to the angle the live pointer rests at (the two SVG sources rotate it -90.7 degrees: the pointer image's -55.7 that puts the chevron corner up, plus the -35 rest rotation), so the mark is the pointer and neither carries a separate arrow any more: the icon is a navy tile with the mark's white line and cyan facets (`Assets.xcassets/AppIcon.appiconset`, 16 to 1024 px), the menu bar glyph is the same line and facets in black as a template image (`Assets.xcassets/MenuBarIcon.imageset`, 1x/2x/3x, loaded by `MenuBarPanelManager.makeWingmanMenuBarIcon()` with the old drawn triangle as the fallback). Both are rendered with `rsvg-convert` from `docs/brand/wingman-app-icon.svg` and `docs/brand/wingman-menu-bar-glyph.svg`, whose geometry is the ForIT logo SVG's own paths. The live overlay pointer (`BlueCursorView` in `OverlayWindow.swift`) is, since 2026-09-05 (Ben: "you can just rotate the thing and it'll look like a pointer"), the ForIT mark itself turned so the corner where its two cyan chevron arms meet leads: the `WingmanPointer` image set (24/48/72 px, rendered from `docs/brand/wingman-pointer.svg`, chevron corner straight up, navy line and white halo baked in) drawn at 24 pt and aimed by the same rotation the old triangle used (-35 degrees at rest, the flight tangent while pointing). `DS.Colors.overlayCursorOutlineColor` and `overlayCursorHaloColor` remain the line and halo colours. The small cyan bubbles beside the pointer use `DS.Colors.textOnAccent` (navy) rather than white text.

### ForIT relay (`relay/`, Azure Functions, Node 20)

The app never calls a vendor directly. Every request goes to the relay with `Authorization: Bearer <Entra id_token>`; the relay validates the token against the ForIT tenant (issuer, audience = the Wingman app registration, signature via JWKS) and only then calls the vendor with a key read from Key Vault.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `GET /api/health` | none | Version + which vendors are configured (no auth) |
| `POST /api/chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat; model must be on the relay allow-list |
| `POST /api/tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs audio; answers 501 when no key or voice is configured |

Relay settings come from Key Vault references (`ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`) and app settings (`ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ELEVENLABS_VOICE_ID`, `ALLOWED_MODELS`). Infra is `relay/infra/main.bicep`; deploy is `.github/workflows/relay-deploy.yml`. The relay stores nothing: no transcripts, no screenshots, no user records (`.ai/decisions.md` 001).

### Tools layer (for-mcp gateway)

Support data is reached only through the for-mcp gateway's `support_*` MCP tools, called by the app itself (`WingmanGatewayToolClient.swift`, MCP Streamable HTTP, `POST …/mcp`) with the user's own gateway access token (scope `access_as_user`, client `ForIT-Wingman-Client`). The relay never sees that token and never executes a tool; it only forwards tool definitions and `tool_use` / `tool_result` blocks to Anthropic. There is no connection string, SQL, or database driver in the app.

The static allow-list is `WingmanToolCatalog.swift`: `support_listTickets`, `support_addTicketNote`, `forit_avops_search_flights`, `support_searchKbArticles`, `support_getKbArticle`. Nothing else is described to the model, and per turn the list is narrowed to what the gateway's `tools/list` exposes to the signed-in person (`CompanionManager.toolDefinitionsForThisTurn`, cached 15 minutes per account; whole catalog on failure), so a tool the gateway does not have yet is never offered. The catalog also applies the app-side policy before a call leaves the machine: a "draft reply" is always an internal note whose content starts with `DRAFT (Wingman): ` and whose `author_name` labels the signed-in person's Wingman; a knowledge base search always carries a tenant slug (`forit` unless the model named one) and a limit of 1…10; unknown argument keys are dropped; ticket lists and article search results are condensed to the fields the model needs and an article body is cut at 12,000 characters. Gateway `401` / `403` end the turn with the fixed spoken refusals in `docs/PERMISSIONS.md` 4 and a panel banner (`gatewayAccessProblemMessage`).

The two knowledge base tools answer FL3XX and other "how do I" questions from the for-Support KB (`.ai/decisions.md` 003). The two read-only routes on for-Support they call went live at for-Support `a24e57f` (2026-09-05) and the gateway exposes both tools; the contract as shipped is `docs/common-proposed/for-support-kb-read-api.md`. The `forit` tenant holds no FL3XX articles yet (seeding is a Ben decision, recorded in that document). `docs/common-proposed/` holds proposals this repo writes for other ForIT repos (cross-project writes are not made from here).

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Sign-in gate**: `CompanionManager.handleShortcutTransition` refuses push-to-talk while `signInManager.isSignedIn` is false and posts `.wingmanShowPanel` so the panel opens on the account row. A 401 from the relay clears the stored session (`handleUnauthorizedResponse`) rather than retrying with the same token.

**Transient Cursor Mode**: When "Show Wingman" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `WingmanApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1230 | Central state machine. Owns the sign-in manager, the vocabulary store, dictation, shortcut monitoring, screen capture, the relay chat client, the gateway tool client, TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, cursor visibility, the gateway access banner and the cached gateway `tools/list`. Coordinates the full push-to-talk → screenshot → Claude (tool loop) → TTS → pointing pipeline and refuses it while signed out. The voice system prompt, including the ForIT support and knowledge base section, lives here. Feeds the sentence splitter from the stream callback and warms the relay and tool list on key-down. |
| `MenuBarPanelManager.swift` | ~270 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor, and opens the panel on `.wingmanShowPanel`. |
| `CompanionPanelView.swift` | ~960 | SwiftUI panel content for the menu bar dropdown. Shows companion status, the account row (sign in / signed-in user / sign out), the gateway access banner, push-to-talk instructions, model picker from the relay allow-list, the collapsible Vocabulary editor (term rows with remove, three-field add form), permissions UI, and quit button. Dark aesthetic using `DS` design system. |
| `WingmanEntraSignInManager.swift` | ~330 | Entra sign-in state machine (`signedOut`/`signingIn`/`signedIn`/`failed`). Browser PKCE flow, custom-scheme callback, token refresh, keychain persistence, `validIdToken()` for the relay and `validGatewayAccessToken()` for for-mcp. |
| `WingmanSignInSupport.swift` | ~170 | PKCE helpers, id_token claim reader (display only, no local signature check), keychain store. |
| `WingmanServiceConfiguration.swift` | ~94 | Relay URLs, Entra tenant/client ids, gateway scope and MCP endpoint, and the selectable model allow-list. |
| `WingmanVocabulary.swift` | ~265 | The taught vocabulary: a term is its canonical spelling (`FL3XX`), its spoken forms (`Flex`) and a one-line meaning. Pure functions for the four uses (Apple Speech keyterms, whole-word transcript rewrite to the canonical spelling, the prompt section, canonical-to-spoken rewrite before text-to-speech) plus `containsTerm` for the tool policy, and `WingmanVocabularyStore`, the JSON file in `~/Library/Application Support/io.forit.wingman/vocabulary.json` seeded with FL3XX. |
| `WingmanToolCatalog.swift` | ~440 | The static allow-list of gateway tools described to the model (five: tickets, draft note, flights, KB search, KB article), their JSON schemas, the narrowing to the gateway's `tools/list` (`modelToolDefinitions(exposedByGateway:)`), the app-side argument policy (`prepareCall`: draft-note prefix and author label, forced KB tenant, key whitelisting, limit clamping) and result condensing (ticket lists, article search results, article body cap). |
| `WingmanGatewayToolClient.swift` | ~330 | MCP Streamable HTTP client for the for-mcp gateway: `initialize`, `tools/list` (all pages) and `tools/call` with the user's gateway token, JSON or SSE responses, `mcp-session-id` handling with one retry when the gateway forgets the session, 401 → `accessDenied`, 403 → `insufficientAccess`. Pure parsing helpers are unit-tested. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~42 | Protocol surface for voice transcription backends and the factory, which returns Apple Speech only. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | On-device transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~464 | Relay chat client (SSE streaming). `streamTurn` sends an explicit message list plus tool definitions and returns a `ClaudeStreamedTurn` (text, `tool_use` requests, stop reason, echo blocks); `ClaudeSSEStreamParser` is the pure event parser. `analyzeImageStreaming` remains for the onboarding demo. Bearer via `WingmanBearerTokenProvider`, `WingmanRelayError` with 401 → `notAuthorized`, TLS warmup, `warmUpRelay()` (health GET on key-down, throttled to once a minute), image MIME detection. |
| `ElevenLabsTTSClient.swift` | ~316 | Sentence queue for speech: `enqueueSentence` fetches audio through the relay `/api/tts` (two fetches ahead) and plays sentences in order, `finishEnqueuedSpeech()` waits for the last one, `onQueuedPlaybackStarted` fires when the first starts, `stopPlayback` drops the queue. On-device `AVSpeechSynthesizer` after a 501. Exposes `isPlaying` for transient cursor scheduling. |
| `WingmanSpokenSentenceSplitter.swift` | ~96 | Pure splitter for streamed replies: releases the first sentence at its boundary, later ones once at least 60 characters are pending, never speaks from `[POINT` onward and holds back a partial tag; `flushRemaining` at end of stream. Unit-tested. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WingmanAnalytics.swift` | ~145 | Local analytics wrapper: same static API upstream used for PostHog, now `os.Logger` lines only. Ordinary events are debug lines; `tool_refused`, `tool_failed`, `response_error` and `tts_error` are error-level with public fields so `log show --predicate 'subsystem == "io.forit.wingman"'` can read them back. Tool events log the tool name and a stable outcome label, never arguments or results. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `WingmanTests/WingmanSignInTests.swift` | ~99 | Swift Testing coverage for PKCE, authorize URL, callback parsing, id_token claims, form encoding, model allow-list mapping. |
| `WingmanTests/WingmanSpokenSentenceSplitterTests.swift` | ~74 | Swift Testing coverage for the sentence splitter: early first sentence, batching, number periods, newlines, the pointing tag, the final flush. |
| `WingmanTests/WingmanVocabularyTests.swift` | ~146 | Swift Testing coverage for the vocabulary: keyterms, whole-word transcript rewrite (longest spoken form first), pronunciation rewrite, prompt section, product-name-as-tenant fallback in the tool policy, the `tool_error_http_NNN` label, and the store round trip. |
| `WingmanTests/WingmanToolUseTests.swift` | ~420 | Swift Testing coverage for the tool allow-list and draft policy, the knowledge base argument policy and condensing, the `tools/list` narrowing and parsing, the SSE `tool_use` parser, and gateway response / refusal parsing. |
| `packaging/pkg-scripts/postinstall` | ~18 | Shell script inside the Jamf `.pkg`: quits a stale running Wingman and launches the installed copy for the console user via `launchctl asuser` + `open -b`, never failing the install. |
| `relay/src/` | ~870 | Azure Functions relay: `health`, `chat` (tool passthrough validation, Anthropic prompt caching on the system prompt and the last user message), `tts` handlers, `keepWarm` timer (every four minutes, keeps the consumption-plan worker warm), Entra token validation, model allow-list. Tests are the `*.test.ts` files beside the sources (`npm test`). |

## Build & Run

```bash
# Open in Xcode
open Wingman.xcodeproj

# Select the Wingman scheme (shared, ad-hoc signed, no team needed), Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Relay

```bash
cd relay
npm ci
npm test          # vitest: token validation, allow-list, handlers
npm run build

# Deploy: push to main (.github/workflows/relay-deploy.yml builds, deploys the bicep in
# relay/infra/main.bicep, then publishes the Function App). No manual wrangler/az step.
# Vendor keys are never added by hand from a workstation: they are Key Vault secrets the
# workflow references by name. Adding a new vendor is a decision-log entry, not a signup.
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

## Rename and provenance (2026-09-04)

- Targets, directories, bundle ids (`io.forit.wingman`, `.tests`, `.uitests`), display name and scheme are `Wingman`.
- Removed from upstream: PostHog SDK, FormSpark email capture, the hosted Mux intro video, the "DM Farza" button,
  bundled game-soundtrack mp3s, the Codex/makesomething image sets, per-user `xcuserdata`, `scripts/release.sh`.
- Sparkle feed is `https://raw.githubusercontent.com/ForITLLC/forit-Wingman/main/appcast.xml`; the EdDSA private key
  is the `SPARKLE_PRIVATE_KEY` repo secret and the matching public key is in `Info.plist`. Since 2026-09-05 the updater
  starts at launch (`startSparkleUpdater()` in `WingmanApp.swift`; Ben: "Why are you suddenly asking me to install this?"):
  `SUEnableAutomaticChecks` is on so Sparkle never asks permission to check, and `SUScheduledCheckInterval` is 3600 s so a
  fix reaches a running Wingman within the hour. Installing is silent once the person has ticked "automatically download
  and install" in Sparkle's own alert (the user default `SUAutomaticallyUpdate`, which nothing in the app sets): the update
  downloads in the background and is swapped in at the next quit with no prompt. Proven on Ben's MacBook on 2026-09-05:
  0.1.41 to 0.1.45 between 06:09Z and 06:11Z and 0.1.45 to 0.1.48 between 06:15Z and 06:20Z, each with the Autoupdate log
  line "OK: EdDSA signature is correct for update". Sparkle logs once per launch that this background app schedules checks
  but "does not implement gentle reminders": a scheduled update alert for a menu-bar-only app can open behind other windows,
  and the `SPUStandardUserDriverDelegate` gentle-reminder hooks are the fix if that ever matters (not asked for). The first
  build with the updater on was the last manual install (decision `.ai/decisions.md` 007).
- CI: `.github/workflows/ci.yml` (jobs `test` and `build`), DMG and `.pkg` artifacts, GitHub release on main. Since 2026-09-05 the Release
  build is signed with an **interim self-signed certificate** held as the repo secrets `MACOS_SIGNING_P12_BASE64` and
  `MACOS_SIGNING_P12_PASSWORD` (ad-hoc when they are absent). macOS keys the Accessibility and Screen Recording grants to the
  app's designated requirement; with a certificate that requirement is the same for every build, so the grants survive an
  update, whereas an ad-hoc signature pins the build's cdhash and every install wiped both grants (Ben, twice, 2026-09-05).
  The job fails if the requirement still names a cdhash. **A Mac that granted permissions to an ad-hoc build needs one reset when it first runs a certificate-signed build**: macOS keeps the old rows keyed to the ad-hoc cdhash, shows their switches as ON, and denies the new build (`tccd`: `matchesCodeRequirement … status: -67050`, `matches platform requirements: No`), so re-granting and restarting change nothing (Ben, 2026-09-05, "after several restarts, it's still not working"). The fix is `tccutil reset Accessibility io.forit.wingman` and `tccutil reset ScreenCapture io.forit.wingman`, then grant once more; the new rows carry the certificate requirement and survive updates. Verified 2026-09-05 05:34Z: the 0.1.35 to 0.1.41 update kept all three grants with no re-grant. **Start a build from ssh with `open -b io.forit.wingman`, never by running the binary from the shell**: macOS then makes the shell the process responsible for the microphone and screen-recording checks and denies both, so only Accessibility logs as granted and the app looks unable to recover its permissions (Ben, 2026-09-05, "why can't it recover … from permissions"; fixed by relaunching through LaunchServices). It is not a Developer ID: Gatekeeper is unchanged and there is no
  notarisation; a new certificate costs one more grant of each permission. Decision `.ai/decisions.md` 005. The Release build passes `ENABLE_HARDENED_RUNTIME=NO`: neither an ad-hoc signature nor the interim certificate has a Team ID, so with the hardened runtime on, library validation rejects the embedded Sparkle framework and the app dies in dyld at launch (found 2026-09-05). The job launches the built app and requires it to stay up for eight seconds. Turn the hardened runtime back on when the build is signed with a ForIT Developer ID.
- Jamf (2026-09-05, Ben: "make this a Jamf package and push it to Christine's laptop", then "every employee would use this
  potentially, so for anyone with a Mac I want it installed"): every release also carries `Wingman-<version>.pkg` and
  `designated-requirement.txt`. The package is a `pkgbuild` component package that installs `Wingman.app` to `/Applications`;
  its postinstall (`packaging/pkg-scripts/postinstall`) quits a stale running copy and launches the new one for the person at
  the console through LaunchServices, never as root. It is unsigned (no Developer ID Installer certificate yet), which a Jamf
  policy accepts and an MDM install command does not. The job installs the package on the runner as root and checks the copy in
  `/Applications` before anything is released. The PPPC profile grants Accessibility by the code requirement in
  `designated-requirement.txt` (`identifier "io.forit.wingman" and certificate root = H"d7c3…"`) and lets standard users approve
  Screen Recording; Microphone and Speech Recognition cannot be pre-granted by MDM, so each person approves those once. The
  for-Jamf session owns the policy and its scope (Christine's laptop first, then every ForIT Mac). Decision `.ai/decisions.md` 008.
- Decision log: `.ai/decisions.md`. Dependency inventory: `docs/UPSTREAM-DEPENDENCIES.md`. Permissions: `docs/PERMISSIONS.md`.
