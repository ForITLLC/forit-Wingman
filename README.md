# Wingman

Wingman is ForIT's voice assistant for support work on macOS. It lives in the menu bar. Hold
**Control + Option**, ask a question, and it answers out loud using what is on your screen and the
ForIT tools your account can reach: open tickets for a client, what is blocking a ticket, a draft
reply saved as a note. A small blue cursor can fly to and point at things on screen while it talks.

Wingman is derived from [Clicky](https://github.com/farzaa/clicky) by Farza (MIT). See `NOTICE`.

## What is different from Clicky

| Clicky | Wingman |
|--------|---------|
| Cloudflare Worker holding Anthropic, ElevenLabs and AssemblyAI keys, no caller auth | ForIT relay in the ForIT Azure subscription, Entra sign-in per user, keys only in Key Vault |
| PostHog analytics, FormSpark email capture, hosted intro video, "DM Farza" | none of that; nothing leaves the machine except model calls, tool calls and, unless the person switches it off in the panel, one usage report per question (question, answer, tools, timings; never the screen or the voice) |
| AssemblyAI streaming speech-to-text | on-device Apple Speech |
| General "AI teacher" | support assistant that calls the for-mcp gateway as the signed-in ForIT user |

The decision record is in `.ai/decisions.md`; the dependency inventory in
`docs/UPSTREAM-DEPENDENCIES.md`; who can do what in `docs/PERMISSIONS.md`.

## Build

Open `Wingman.xcodeproj` in Xcode 26 or newer, select the `Wingman` scheme and run. The project is
set to ad-hoc signing with no Apple team, so it builds on any Mac without an Apple developer account.
Do not run `xcodebuild` from a terminal on a machine you also use the app on: it resets the TCC
permissions (screen recording, microphone, accessibility) the app has been granted.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and push to `main`:

1. `test` runs the `WingmanTests` unit tests on a macOS runner.
2. `build` produces a Release `Wingman.app`, verifies the bundle identifier is `io.forit.wingman`,
   packages `Wingman-0.1.<run>.dmg`, and uploads both as workflow artifacts.
3. On `main` it also publishes a GitHub release `v0.1.<run>` with the DMG and, when the
   `SPARKLE_PRIVATE_KEY` secret is present, signs the DMG for Sparkle and appends it to `appcast.xml`.

CI builds are **not notarized**. On first launch, right-click the app and choose Open. Notarization
needs Apple Developer credentials, which is a decision outside this repo.

## Permissions the app asks for

Accessibility (to see where windows are), Screen Recording (only while the hot key is held),
Microphone (only while the hot key is held) and Speech Recognition (on device). The menu bar panel
lists all four and links to the right System Settings pane.

## Repository layout

| Path | Purpose |
|------|---------|
| `Wingman/` | The macOS app (SwiftUI + AppKit bridging). The root `AGENTS.md` describes each source file. |
| `WingmanTests/` | Unit tests. |
| `WingmanUITests/` | UI test scaffold, not run in CI. |
| `relay/` | ForIT relay (Azure Functions) that fronts the model and speech vendors, checks the user's ForIT sign-in on every call, and holds no user data. |
| `docs/` | Dependency inventory, permissions, architecture notes. |
| `.ai/` | Decision log. |

## License

MIT. See `LICENSE` (upstream copyright preserved) and `NOTICE`.
