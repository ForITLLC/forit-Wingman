# Wingman decisions

Append-only. Newest at the bottom. Each entry: context, options, decision, reasons, consequences,
evidence (file:line in this or sibling ForIT repos at the time of writing).

## 001 — Model backend: a ForIT-owned relay in the ForIT subscription, Anthropic behind it, no key on the laptop

**Date:** 2026-09-04 · **Status:** accepted · **Owner:** for-Wingman · **Work order:** WO#1907 / WO#1907-R1

### Context

Upstream Clicky routes every model call through an unauthenticated Cloudflare Worker that holds
the Anthropic, ElevenLabs and AssemblyAI keys (`docs/UPSTREAM-DEPENDENCIES.md` rows 1-4). Anyone
with the Worker URL can spend the keys. Wingman must make every model call through a
ForIT-controlled endpoint, hold no key in the app, keep the provider pluggable with Claude as the
default, and run with no OpenAI or Gemini dependency (goal item 2). Tool calls must run as the
signed-in user and be scoped server-side (goal item 4).

### Options considered

| # | Option | Verdict |
|---|--------|---------|
| A | Re-home `worker/` as-is on Cloudflare under a ForIT account | Rejected. Cloudflare is not ForIT platform standard (Azure first; Cloudflare infra needs Ben's approval) and the Worker has no caller authentication at all. |
| B | Call the ForIT AI Engine (`forit-ai-engine.azurewebsites.net/api/v1/chat/completions`) | Rejected for phase 1. Its SSE is buffered, not token-by-token, by its own comment (`for-AI/platform/src/functions/openai-compat.ts:632-724`); it runs an engine-owned tool loop, so tools would execute under the engine's service identity (`for-AI/platform/src/gateway-auth.ts:1-50` mints client-credential tokens for the gateway), which defeats "every tool call runs as the signed-in user"; and it does not pass through a Messages-API body with screenshots and client-side `tool_use` blocks. Kept as a **second provider adapter** for later (see Consequences). |
| C | Direct Anthropic from the app with a key fetched from Key Vault at runtime | Rejected. The key would sit in a laptop process; that is a god-key in the client, the exact thing goal item 4 forbids. |
| D | **A Wingman relay: Azure Functions in the ForIT subscription, Entra-authenticated per user, Anthropic Messages API behind it with a ForIT key from Key Vault** | **Accepted.** |

### Decision

1. **Relay** = Azure Functions (Node 22, TypeScript) in subscription `147a19b0-f6a7-4b0b-89e9-49f4aabd1435`,
   resource group `rg-forit-wingman`, app `wingman-func`, Key Vault `kv-forit-wingman`, read-only managed
   identity resolving `@Microsoft.KeyVault(SecretUri=…)` app settings. This follows
   `for-Common/docs/adding-a-new-app.md:436-438` (own RG per product) and
   `for-Common/docs/patterns/product-secret-provisioning.md:7-24` (secret lives in KV and process memory only).
   The relay source lives in this repo under `relay/` and replaces `worker/`.
2. **Routes**
   - `POST /api/chat` — validates the caller's Entra access token for Wingman's own API app registration
     (tenant `c0efa09e-4bda-4a9d-a177-4c77076b7f76`; audience `api://<wingman-app-id>`; `rejectGuests`),
     then forwards the Messages-API body to the selected provider and streams the SSE back unchanged.
     Provider is selected by `WINGMAN_MODEL_PROVIDER` (`anthropic` default; `engine` adapter reserved for
     option B). The signed-in user's UPN is logged per request and forwarded as `X-ForIT-User` for attribution.
   - `POST /api/tts` — ElevenLabs behind the same auth, enabled only if `elevenlabs-api-key` exists in
     `kv-forit-wingman`. ForIT already holds an ElevenLabs key in the AI Engine's settings
     (`for-AI/platform/src/functions/voice.ts:38-82`), so this is a reuse, not a new vendor.
   - No `/transcribe-token`. AssemblyAI is not a ForIT vendor and a new signup is out of scope; speech-to-text
     is on-device Apple Speech (`AppleSpeechTranscriptionProvider.swift`, already in tree). ElevenLabs TTS
     falls back to on-device `AVSpeechSynthesizer` when the relay reports TTS disabled.
3. **Tool calls do not go through the relay.** The app is the MCP client and calls the for-mcp gateway
   (`for-mcp.graycoast-522b9cfd.eastus.azurecontainerapps.io/mcp`, Streamable HTTP) with the user's own
   delegated Entra token for the gateway's API (`api://861db494-6d36-4d7d-83c4-39352d3e9576`). The gateway
   already validates that token, maps app roles to `tools.read/write/admin` and audit-logs the human
   (`for-mcp/server.py:200-241`, `:592-606`). Per-user tenant scoping of `support_*` is a gateway/Support gap
   reported to the Commander, not worked around in the app (see `docs/PERMISSIONS.md`).
4. **Model** default `claude-sonnet-4-6`, optional `claude-opus-4-6`, both selectable in the panel as upstream;
   provider names never leak into the UI.
5. `OpenAIAPI.swift` and `OpenAIAudioTranscriptionProvider.swift` are deleted; there is no OpenAI or Gemini
   code path.

### Reasons

- Only option D keeps all four properties at once: ForIT-controlled endpoint, no key on the laptop,
  true token streaming with vision and `tool_use`, and tool execution under the user's identity.
- The relay is a thin passthrough, so provider swaps are a server change with no app release.
- The relay is the app-owned "chat proxy that runs the app's own auth check" that the ForIT AI tier
  standard requires for any human-facing AI surface (`for-Common/docs/AI-START-HERE.md:104-148`).
  The deviation is that the provider key sits in `kv-forit-wingman` instead of the AI Engine, because
  the Engine cannot yet stream or pass through client tool use. Revisit when
  `openai-compat.ts` gains a real token stream and a passthrough mode; the `engine` provider adapter
  is the migration path.

### Consequences

- New Azure resources: `rg-forit-wingman`, `wingman-func` (consumption plan), `kv-forit-wingman`,
  storage account, App Insights. Provisioned by the deploy workflow with the OIDC deploy identity.
- **Key provenance (hard line from WO#1907-R2):** the relay uses an Anthropic key ForIT **already holds**.
  Source of truth today: the `ANTHROPIC_API_KEY` application setting on Function App `forit-ai-engine`
  (subscription `147a19b0-f6a7-4b0b-89e9-49f4aabd1435`; `for-AI/platform/src/config.ts:67`). The copy in
  Key Vault `forit-ai-secrets/anthropic-api-key` is **stale since 2026-03-03** and must not be used
  (`for-AI/docs/plans/2026-07-27-keyvault-migration-plan.md:41-44`). The live value is copied into
  `kv-forit-wingman/anthropic-api-key` by the provisioning pipeline, never a portal paste. No new Anthropic
  account, organisation, billing or top-up is created for Wingman; if the held key is unusable, that is a
  money step reported to the Commander, not worked around. Same rule for ElevenLabs: reuse the
  `ELEVENLABS_API_KEY` setting on the same Function App into `kv-forit-wingman/elevenlabs-api-key`, or ship
  with on-device TTS only.
- Two Entra app registrations are needed: Wingman API (exposes `access_as_user`) and Wingman desktop
  public client (PKCE, redirect `msauth.io.forit.wingman://auth`). Both are ForIT-tenant, guests rejected.
  The desktop client must also be pre-authorised on the gateway API `861db494…` for a delegated scope —
  a for-mcp item, reported.
- The relay is observable per `for-Common/docs/patterns/service-observability-golden-standard.md`:
  health endpoint asserting KV + provider reachability, errors to the fleet sink, alert route
  `support+wingman@forit.io`.

### Implementation record (2026-09-04, WO#1907-R2 "build it, no Ben ask")

What was built differs from the Decision text in three places. The intent is unchanged; the record is
kept here so the paragraphs above remain the decision as accepted and this is what exists.

- **Function App is `forit-wingman-relay`**, not `wingman-func`, matching the `forit-<product>` naming of
  the other ForIT Function Apps. Hostname `forit-wingman-relay.azurewebsites.net`. Template:
  `relay/infra/main.bicep`; pipeline: `.github/workflows/relay-deploy.yml` (ref-gated to `main`).
- **One Entra app registration, not two.** The public client **ForIT Wingman** (the original registration;
  replaced on 2026-09-04 by **ForIT-Wingman-Client** `acc81527-1818-4c79-8f59-0bfc111701d4`, see
  `docs/PERMISSIONS.md` 5.2, and deleted by for-mcp on 2026-09-05 under WO#1910; redirect
  `msauth.io.forit.wingman://auth`) signs the user in with PKCE. Its **id_token** (`aud` = that client id,
  RS256 against the ForIT tenant keys) is the relay credential; a separate "Wingman API" registration
  exposing `access_as_user` adds nothing the relay can check that the id_token does not already carry. The
  same sign-in yields the **access token for the gateway** (`api://861db494-6d36-4d7d-83c4-39352d3e9576`,
  delegated scopes `tools.read`, `tools.write`, admin consent granted 2026-09-04), so the app holds one
  refresh token and two audiences.
- **Models are the current generation:** `WINGMAN_ALLOWED_MODELS=claude-sonnet-5,claude-opus-5`,
  `WINGMAN_DEFAULT_MODEL=claude-sonnet-5`. The Decision named `claude-sonnet-4-6` / `claude-opus-4-6`
  from the upstream Clicky code; both are relay settings, so a model change is never an app release.

Key provenance, as executed: `kv-forit-wingman` (RBAC mode, `rg-forit-wingman`, eastus) holds
`anthropic-api-key` and `elevenlabs-api-key`, both copied by a ForIT Global Administrator through the
`mm_run` Azure module from the `ANTHROPIC_API_KEY` and `ELEVENLABS_API_KEY` application settings of
Function App `forit-ai-engine`; the values were never printed, pasted, or committed. **No Anthropic or
ElevenLabs account, organisation, billing, card or top-up was created.** The relay's managed identity holds
only *Key Vault Secrets User* on that vault.

Deploy identity: Entra app **GitHub Actions - ForIT Wingman** (`fca3bde8-953a-4beb-bcce-18c7b5cb3a71`),
federated to `ForITLLC/forit-Wingman` branch `main` and environment `production` (four credentials: the plain `repo:ForITLLC/forit-Wingman:…` subjects and GitHub's id-augmented `repo:ForITLLC@225032539/forit-Wingman@1357537282:…` subjects, which is the form GitHub presents for this repo; the first deploy run failed with AADSTS700213 until the id-augmented pair was added on 2026-09-04), with *Contributor* and
*Role Based Access Control Administrator* scoped to `rg-forit-wingman` only. GitHub holds
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (secrets) and `WINGMAN_ENTRA_CLIENT_ID`
(variable). Nothing in GitHub can read the vault.

Interim access rule (accepted by the Commander 2026-09-04 as phase 1, not the design): the relay refuses
any signed-in account whose email domain is not `forit.io` (`WINGMAN_ALLOWED_EMAIL_DOMAINS`). The design is
per-user identity pass-through on `support_*` (for-mcp WO#1908); the domain filter comes out when that lands.

## 002 — Support skill: the app runs the tool loop and calls the gateway itself; the relay only forwards tool blocks

### Context

WO#1907 makes Support the primary skill: "open tickets for a client", "summarise ticket n and what
blocks it", "draft a reply to ticket n". The Support database may be reached only through the for-mcp
gateway's `support_*` tools (no connection string, SQL or driver in the app), and a draft must never
reach a customer. for-mcp WO#1908 (2026-09-04) gave Wingman a delegated gateway token
(`ForIT-Wingman-Client` `acc81527…`, scope `access_as_user`), so the gateway can see the person.

### Options considered

1. **Relay executes tools.** The relay would need the user's gateway token (or its own service
   identity), and every audited call would carry the relay's identity or a token the relay should not
   hold. It also puts ForIT support data through a component that otherwise stores and sees nothing.
2. **App executes tools, relay forwards the blocks (chosen).** The relay stays a dumb, stateless
   passthrough to Anthropic (it validates `tools` / `tool_use` / `tool_result` shapes and sizes, nothing
   more). The app calls the gateway over MCP with the user's own token, so the gateway's role check and
   audit trail name the person, and the relay never sees ticket data.
3. **Prompt-only safety for drafts.** Asking the model to "only write drafts" is not enforcement.

### Decision

Option 2, with deterministic app-side policy in `WingmanToolCatalog`:

- Only three tools are described to the model (`support_listTickets`, `support_addTicketNote`,
  `forit_avops_search_flights`). `support_replyToTicket`, delete, assign, bulk-update and provisioning
  tools do not exist as far as the model knows.
- "Draft a reply" is always `support_addTicketNote` with content prefixed `DRAFT (Wingman): ` and
  `author_name` = "Wingman for <name> <email>". The prefix is applied by code, once, whatever the model
  sent. The gateway records the note under the ForIT Automation identity; it emails nobody.
- At most four tool rounds per spoken question, then a forced answer (`tool_choice: none`).
- Gateway `401` / `403` are not fed back to the model: the turn ends with the fixed spoken refusal from
  `docs/PERMISSIONS.md` 4 and a panel banner, so a user without a role hears the same sentence every time.
- Tool results are condensed (ticket lists keep the fields needed to answer or draft) and capped at 64
  KB by the relay.

### Consequences

- The relay's `/api/chat` accepts `tools`, `tool_choice` and the two tool block types; it still
  stores nothing and never calls a tool.
- Tool rounds are not kept in the conversation history between turns, so the context stays small and
  a stale tool result is never reasoned from twice; the spoken reply is what the model remembers.
- A gateway or protocol change shows up as an error `tool_result` the model reads aloud ("that
  failed"), not as an invented answer.

## 003 — FL3XX and how-to questions are answered from the for-Support knowledge base, read through two gateway tools the app hides until they exist

### Context

Ben (2026-09-04): "Get those ready to answer Flex questions" and "the integration with support is the key
part". Staff asking Wingman how to do something in FL3XX (the flight operations platform ForIT supports;
Planet Nine Private Air is the first FL3XX operator) must get the ForIT-curated procedure, not a model's
recollection of FL3XX. The knowledge base already lives in for-Support (`kb_articles`, per tenant plus
global articles, published/draft, `content` + `content_plain`), but it has no read route a bearer token can
call, the gateway has no `support_*` KB tool, and the `forit` tenant holds no FL3XX article yet. The
`for-FL3XX` repo holds a 442-page markdown mirror of FL3XX's public help centre and a 315-page mirror of its
developer portal; a curated 346-page import set (for-FL3XX `46244dc`, `docs/for-support-kb-import-set.txt`)
leaves out release notes, marketing and crawl artifacts. Ben scoped the first cut: "let's scope to forit for now but we'd basically put this
planet 9 scoped".

### Options considered

1. **Ship the FL3XX corpus inside the app or the relay** (embed the mirror, or a vector index of it).
   Puts FL3XX's text in a build artefact, bypasses the support team's editing and publishing flow, and
   drifts from whatever ForIT actually tells clients.
2. **A new "AI harness" service that indexes the KB and answers questions.** Another service to own,
   another identity, and the tool loop the app already runs is exactly that harness.
3. **Two read-only tools on the gateway backed by two for-Support admin routes (chosen).** The app
   searches, then reads one article, and answers from it. Content stays where support staff edit it.

### Decision

Option 3.

- **for-Support** adds `GET /api/admin/kb/search` (new) and opens the existing `GET /api/admin/kb/{articleId}`
  to bearer callers, both in `openapi.json` with operationIds `searchKbArticles` / `getKbArticle`; the
  gateway mounts them as `support_searchKbArticles` / `support_getKbArticle` from the spec with no gateway
  code. Contract: `docs/common-proposed/for-support-kb-read-api.md`.
- **The app** describes both tools to the model (`WingmanToolCatalog`, Viewer level). Search always carries a
  tenant: the model's, lower-cased, or `forit` when it gave none, so a search can never widen to every
  tenant. Article bodies are cut at 12,000 characters before the model sees them.
- **The catalog is narrowed to the gateway's `tools/list`** per account (cached 15 minutes). Until
  for-Support ships, the KB tools are simply not offered and the prompt tells the model to say that part is
  not connected. When the routes land and for-mcp refreshes its spec, they appear without an app release.
  (That is what happened: for-Support shipped `a24e57f` on 2026-09-05, the gateway re-mounted the support
  family from the spec, and both tools showed up in `tools/list` with no Wingman change.)
- **The prompt** makes the KB the first stop for any "how do I / where is / why does" question about FL3XX or
  another supported system, requires naming the article, and forbids inventing an FL3XX procedure when the
  search comes back empty.
- **Content** is a for-Support / Ben matter, not an app one: seeding the `forit` tenant from the
  `for-FL3XX` mirror (staff-facing, attributed to the FL3XX source URL each page carries) is proposed in the
  same document and waited for Ben's yes, because the text is FL3XX's. Ben said yes on 2026-09-05 with the
  constraint "nothing should be public"; for-Support imported the 346-page curated set the same day
  (`f38e469`) as staff-only articles (`visibility: internal`, admin-page `url`, absent from the public KB),
  and the gateway returns them to a bearer caller (re-verified from this repo: `q=tsa` → 10, `q=fl3xx` → 346).
  No app change was needed for the content to appear.

### Consequences

- No FL3XX text, index or vendor key enters the app or the relay; the relay still forwards blocks only.
- A tenant-scoped KB is one argument away: Planet Nine's own articles are searched with `tenant: planet-nine`
  once that tenant exists in for-Support (it does not today; the six tenants are cayres-inc, connect, forit,
  great-north, wma, xceljet).
- The model can cite ("the article How to activate TSA Secure Flight says…") because search results carry
  `title` and `url`; it cannot quote a draft because the search route returns published articles only. For the
  FL3XX mirror the `url` is the support admin page, so a citation never points a client at the internal copy.
- The `tools/list` narrowing applies to every catalog tool, so a gateway that withdraws a tool stops it being
  offered rather than producing "that failed" answers.

## 004 — Voice turns speak while the model is still writing; the relay keeps its prompt cache and its worker warm

Date: 2026-09-05. Status: accepted.

### Context

Ben, on a measured turn (2026-09-05, 19:21 PDT): relay call 2.3 s, two model rounds of 5.5 s and about 7 s,
TTS 2.0 s, then 28 s of playback. "Any thoughts on the speed" and "can you make it faster?". Nothing was
spoken until the last token had arrived and the whole reply's audio had been fetched, so the user waited
for the sum of every stage before hearing the first word. The relay runs on a consumption plan whose worker
goes cold between calls, and every call re-sent the full system prompt and screenshot to Anthropic with no
cache marker.

### Decision

- **Speak sentence by sentence.** The app cuts the streamed reply at sentence boundaries
  (`WingmanSpokenSentenceSplitter`: the first sentence as soon as it ends, later ones once about 60
  characters are pending, never anything from `[POINT` onward), queues each sentence for TTS
  (`ElevenLabsTTSClient.enqueueSentence`, two fetches ahead, played in order) and the turn ends when the
  queue drains (`finishEnqueuedSpeech`). A tool round's preamble ("Let me check the tickets.") is spoken
  too, so a tool call is no longer a silent spinner. The transcript, history and pointing tag handling are
  unchanged: the full text is still parsed once the stream ends.
- **Use the key-down.** While the user holds the push-to-talk key the app wakes the relay
  (`GET /api/health`, unauthenticated, at most once a minute) and refreshes the gateway `tools/list` in the
  background if the 15-minute cache is stale; the turn joins that refresh instead of starting its own.
- **Relay: prompt caching and a keep-warm timer.** `/api/chat` sends the system prompt as a text block with
  `cache_control: ephemeral` and marks the last block of the last user message the same way, so Anthropic
  reuses the prefix within a conversation; a timer function runs every four minutes so the Function App's
  worker is rarely cold. The relay still stores nothing (001 stands): the cache lives at Anthropic, keyed
  by prompt content, for minutes.
- **Errors become readable.** `tool_refused`, `tool_failed`, `response_error` and `tts_error` are logged at
  error level with public fields so they survive in the unified log; ordinary events stay debug. Nothing
  logged carries user content: labels, tool names and error descriptions only.

### Consequences

- The first spoken word arrives after the first sentence plus one TTS fetch (about 2 to 4 s after the model
  starts) instead of after the whole reply. Model rounds and tool calls are not shorter; they are overlapped
  with speech.
- The relay makes more, smaller TTS calls per reply (one per sentence or clause). ElevenLabs bills per
  character, so the cost per reply is unchanged; only request count rises.
- The keep-warm timer costs a few hundred trivial executions a day on the consumption plan.
- A reply that fails mid-way is now partly spoken before the fallback message. The queue is dropped on the
  first error so nothing stale plays after it.
- Measurement after install is by the Mac's unified log (relay and TTS request timings) and by ear.

## 005 — Releases are signed with an interim self-signed certificate so permission grants survive updates

### Context

Every CI build was ad-hoc signed. macOS keys an app's Accessibility and Screen Recording grants to its
designated requirement, and an ad-hoc signature's requirement is the build's own cdhash, so every
install of a new build invalidated both grants. On 2026-09-05 Ben re-granted them twice in one evening
("Now screen recording is a problem"). Sparkle updates would have had the same effect. A ForIT Developer
ID would fix it properly but needs an Apple Developer Program membership, which is Ben's decision.

### Decision

Sign the Release build with a self-signed code-signing certificate (CN "ForIT Wingman Interim Code
Signing", valid to 2036) held as two repo secrets, `MACOS_SIGNING_P12_BASE64` and
`MACOS_SIGNING_P12_PASSWORD`. The workflow imports it into a temporary keychain, trusts it for code
signing on the runner, builds with `CODE_SIGN_STYLE=Manual` and that identity, and fails the job if the
app's designated requirement still names a cdhash. Without the secrets the build is ad-hoc signed as
before. The hardened runtime stays off (library validation wants a Team ID, see `CLAUDE.md`).

### Consequences

- The designated requirement becomes `identifier "io.forit.wingman" and certificate root = H"…"`, the
  same for every build signed by this certificate, so grants made on one build hold on the next.
- A Mac that granted permissions to an ad-hoc build needs a one-time reset when it first runs a
  certificate-signed build. macOS keeps the ad-hoc rows, keyed to that build's cdhash, shows their
  switches as ON, and denies the new build without prompting (`tccd`: `matchesCodeRequirement …
  status: -67050`, `matches platform requirements: No`, `notified-of-denial`). Seen on Ben's MacBook
  on 2026-09-05 after 0.1.35: several restarts and re-grants changed nothing until
  `tccutil reset Accessibility io.forit.wingman` and `tccutil reset ScreenCapture io.forit.wingman`,
  after which the app prompted again and the new rows carry the certificate requirement.
- Gatekeeper treats the app exactly as it treated the ad-hoc build (unidentified developer, not
  notarised). Nothing about distribution changes.
- The private key exists only in the repo secret. Losing or rotating it means one more grant of each
  permission on every Mac, not a broken app.
- Replace with a ForIT Developer ID when one exists; the same workflow step takes that PKCS#12 and the
  hardened runtime can then go back on.

**Verified 2026-09-05 05:34Z.** The MacBook went from 0.1.35 to 0.1.41 (both signed with the interim certificate) and kept the Accessibility, Screen Recording and microphone grants with no re-grant: the new process logged `permission_granted` three times and `all_permissions_granted` at 22:34:52 local. One caveat found the same night: a build started by running its binary from an ssh shell has the shell as its TCC responsible process, so the microphone and screen-recording checks are denied regardless of the signature. Start it with `open -b io.forit.wingman` (LaunchServices), which is what Finder does.

## 006 — Taught vocabulary is applied on the Mac, in the app, not in the relay or the model

### Context

Ben, 2026-09-05: "fl3xx is Flex, how can we train on that?" and "we'll make this so it could be any
vocabulary that we could teach". Apple Speech hears "Flex" for FL3XX, the model then searches the
knowledge base for the wrong word, and ElevenLabs spells F-L-3-X-X back. Every product ForIT supports
has a name like this, and the list differs per person.

### Decision

A vocabulary of terms (canonical spelling, spoken forms, one-line meaning) lives in a JSON file in
Application Support on each Mac, seeded with FL3XX, and is edited in the panel. It is applied by the
app at four points: the terms are Apple Speech contextual keyterms; the final transcript is rewritten
from spoken form to canonical spelling before the model sees it; the system prompt carries a vocabulary
section; and each sentence sent to text-to-speech is rewritten from canonical spelling to the first
spoken form. The tool policy also refuses a vocabulary term as a knowledge base tenant. Nothing about
the vocabulary is sent anywhere except as words inside the prompt and transcript that already go to the
relay.

### Consequences

- Rewrites are whole-word and case-insensitive, longest spoken form first, so "Flex" inside
  "flexible" is untouched and a two-word form is not eaten by its first word.
- The on-screen reply keeps the canonical spelling; only the spoken audio is rewritten.
- The vocabulary is per Mac. A shared, tenant-level vocabulary would be a for-Support or for-mcp
  concern and is not designed here.
- Adding a term changes the system prompt, which invalidates the relay's Anthropic prompt cache once
  per change; the prompt is otherwise stable.

## 007 — The Sparkle updater is on; the build that carries it is the last manual install

### Context

Ben, 2026-09-05: "Why are you suddenly asking me to install this?" Every change since the fork has reached
his Mac only as a DMG he installs by hand, because the updater start was commented out in
`WingmanApp.swift`, carried over from upstream with the note that it stays off until the first signed
release is verified. 0.1.31 and 0.1.33 are signed with the interim certificate (005), the appcast on
`main` holds an EdDSA-signed entry for every release, and the CI launch smoke test runs on every build.

### Decision

`startSparkleUpdater()` runs at launch. `SUEnableAutomaticChecks` is set in `Info.plist` so Sparkle checks
without first asking the person for permission, and `SUScheduledCheckInterval` is 3600 seconds so a fix
reaches a running Wingman within the hour. Installing stays Sparkle's standard prompt (Install and
Relaunch); nothing is installed silently.

### Consequences

- One more manual install: the build that carries this decision. The copy on a Mac before it has no
  updater, so nothing can move it.
- The update path is proven only when a later release arrives through it. The evidence is that release
  running on the Mac and Sparkle's own log lines, not the merge or the CI run.
- Both bundles are signed with the same interim certificate, so the new bundle satisfies the running
  app's designated requirement and the Accessibility and Screen Recording grants survive (005). A later
  switch to a Developer ID is one more manual install and one more grant of each permission.
- Each running Wingman fetches `appcast.xml` from raw.githubusercontent.com once an hour. No ForIT
  service is involved and nothing about the person is sent.

### Outcome (2026-09-05)

Proven the same morning, and more silent than the decision expected. Ben's MacBook was running 0.1.41
with `SUAutomaticallyUpdate` set (Sparkle's own "automatically download and install" box). It downloaded
0.1.45 in the background at 06:09Z and installed it at the 06:11Z quit, then did the same for 0.1.48
between 06:15Z and 06:20Z, each time with the Autoupdate log line "OK: EdDSA signature is correct for
update" and no prompt at all. All three permission grants survived both installs. So "installing stays
Sparkle's standard prompt" holds only for a Mac where that box is unticked; with it ticked, a release
reaches a running Wingman within the hour and lands at the next quit. Sparkle also warns once per launch
that this background app "does not implement gentle reminders": its scheduled alert can open behind other
windows on a menu-bar-only app. Left as is; the gentle-reminder delegate hooks are the fix if anyone is
ever left waiting on an alert they cannot see.

## 008 — Jamf distribution: an unsigned installer package on every release

### Context

Ben, 2026-09-05: "Can you make this a Jamf package and push it to Christine's laptop? Talk with for-Jamf to
coordinate that." Then: "it's not the support group that would use this. Every employee would use this
potentially. So for anyone with a Mac I want it installed." Until now a Mac got Wingman only from a DMG a
person dragged into `/Applications` (right-click, Open, because the interim certificate is not a Developer
ID), which does not scale past Ben's own machines.

### Decision

The release job builds `Wingman-<version>.pkg` with `pkgbuild` next to the DMG and attaches both, plus
`designated-requirement.txt`, to the GitHub release. The package is a component package for
`/Applications/Wingman.app` with one postinstall script that quits a stale running copy and launches the
new one for the console user through LaunchServices. It is unsigned: there is no Developer ID Installer
certificate, and Jamf documents that packages deployed by a policy need no signature (only packages sent
through an MDM install command, such as a PreStage enrollment package, must be signed). The job proves the
package by installing it on the runner as root and checking the copy in `/Applications`.

The Jamf side (uploading the package, the PPPC profile, the policy and its scope) belongs to the for-Jamf
session; this repo only makes the artifacts. The PPPC profile grants Accessibility by the designated
requirement (`identifier "io.forit.wingman" and certificate root = H"d7c3a46d58542739ca68ac152fda8f10f0c674df"`)
and sets Screen Recording so a standard user can approve it. Microphone and Speech Recognition cannot be
allowed by MDM at all, so each person approves those once on first use.

### Consequences

- A Mac that gets Wingman from the policy never sees Gatekeeper: `installer` runs as root and adds no
  quarantine attribute, so the interim certificate is enough. Sparkle then keeps that copy current (007).
- When a ForIT Developer ID arrives, the package should be signed with the matching Developer ID Installer
  certificate and notarised, which also unlocks MDM install commands; until then a policy is the only route.
- Scope starts as Christine's laptop and grows to every ForIT Mac. Sign-in stays the person's ForIT Entra
  account with no group restriction, so nothing in the app changes per person.

### Amendment, 2026-09-05 evening: the package must hand the bundle to the console user

Installer leaves `/Applications/Wingman.app` owned by `root:wheel`. Sparkle installs an update as the signed-in
person and will not silently replace a bundle they cannot write to, so after the first Jamf install Ben's Mac
downloaded 0.1.53 twice and 0.1.55 once and installed none, idle or relaunched, while the drag-installed copy
had updated within two minutes that morning. The postinstall now runs `chown -R <console user>:staff` on the
bundle before launching it. The Macs that received the root-owned package (Ben's, Christine's) need the fixed
package pushed once more; from then on Sparkle updates them within the hour as designed in decision 007.

## 009 — A FL3XX question the knowledge base cannot answer gets labelled general guidance, not a dead end

### Context

Ben, 2026-09-05: "every time that it's like, I can't find an article for it because that's not a good
response … when we realize that it's pulling from Flex, we insert some general instructions or something."
Decision 003 told the model to stop at "the knowledge base has nothing on it yet". Measured the same day
against the `forit` tenant (1,017 FL3XX articles): keyword searches ("create quote", "crew assignment")
return the right how-tos, while a whole spoken question ("how do I add a crew member to a flight") ranks the
Data Processing Agreement and a blog post above them, because for-Support matches every word against title,
summary and body, orders title matches first and then by date. The model, seeing junk or nothing, said it
could not find an article and stopped.

### Decision

Two changes in the app, none in the relay or in for-Support:

- `WingmanToolCatalog.prepareCall` sends the keywords of the query only (`searchKeywords`): question words,
  articles, pronouns, auxiliaries, prepositions and the taught product names are dropped before the search
  leaves the Mac; a query that would become empty is sent as spoken.
- The prompt tells the model to search with two to four keywords, to search a second time with different
  keywords when the hits look off, and, when the second search still finds nothing relevant, to say so
  briefly and then give general FL3XX guidance (module, screen, the usual way) marked plainly as general
  knowledge rather than a ForIT-verified procedure, to be confirmed in FL3XX. A guessed menu, field or
  setting is still never presented as if it came from an article.

A proposal to for-Support (`docs/common-proposed/for-support-kb-read-api.md`, "Ranking") asks that staff
search rank the `kb-*` and `appui-*` how-tos above the `web-*` marketing, press and legal pages.

### Consequences

- Staff get an answer on every FL3XX question; the label tells them which answers to double-check.
- Decision 003's "never invent" softens to "never pass off": general knowledge is allowed when labelled.
- Dropping "Flex" and "FL3XX" from the query means a ForIT how-to that never mentions the product is no
  longer hidden behind its name.

## 010 — Usage sharing is on by default, disclosed before the first question, and the relay keeps one row per turn

Date: 2026-09-05. Amends 001's "the relay stores nothing".

### Context

Ben, 2026-09-05, when asked whether ForIT should keep what people ask Wingman: "with something like this,
I think we should opt in, but we should basically just also put a message of, hey, on the onboarding that
ForIT uses this to help determine something along the telemetry, make people-- and give them the option to
opt out." Until now nothing about a turn left the Mac except the model call and the tool calls, and the only
record was the Mac's own unified log (decision 001, 004). That made "which questions does Wingman fail on",
"how slow is a turn", "what do people search the knowledge base for" unanswerable without sitting next to
someone. The same day's timing complaints (the first sentence took several seconds to be spoken) had to be
diagnosed from `log show` on Ben's Mac.

### Decision

- **On by default, with a disclosure the person sees before their first question.** The panel shows a
  usage sharing notice (`WingmanUsageSharingNotice`) above the Start button: what ForIT keeps, what it never
  keeps, and a switch. Pressing Start counts as having read it. A Mac that onboarded before this build sees
  the same notice once, with a "Got it" button, and the panel opens on its own at launch until it is seen.
  The switch stays in the panel, next to the model picker, as "Share usage with ForIT". The preference is
  `sharesUsageWithForIT` in UserDefaults (missing = on).
- **One report per spoken turn** (`WingmanUsageReport`, `WingmanTurnUsageRecorder`): the question as the
  model saw it (after the vocabulary rewrite), the spoken answer, the model, the app version, which tools
  ran with their outcome (and, for a knowledge base search, the keywords that went to for-Support), how
  many model rounds the turn took, whether the cursor pointed, whether the turn was answered, failed or
  interrupted, and five timings measured from the moment the transcript was final: how long the key was
  held, first model text, first spoken audio, answer complete, turn finished. **Never** the screenshot, the
  audio, a tool result, or a conversation history. The report is sent after the turn ends, in its own task,
  and is dropped on failure: it never delays or retries.
- **The relay keeps it** (`POST /api/usage`, `relay/src/usage.ts`) as one row in an Azure Table
  (`wingmanusage`) in the relay's own storage account, attributed to the person from the verified token,
  never from the body. The route validates and bounds every field and drops anything else, so the relay
  cannot be made to store a screenshot by an older or modified app. No new secret and no new SDK: the table
  is declared in `relay/infra/main.bicep` and written over the Table REST API with the host storage
  account's key (`AzureWebJobsStorage`), Shared Key Lite from `node:crypto`. `WINGMAN_USAGE_RECORDING=off`
  is the server-side switch for the whole fleet; the app then gets `{stored:false}` and logs it.
- **The Mac log says what left**: `usage_report_sent stored=true|false` and `usage_report_failed` are
  notice/error-level lines with public fields under `subsystem == "io.forit.wingman"`.

### Consequences

- 001's "the relay stores nothing" becomes "the relay stores nothing but the usage rows people have not
  opted out of". The other guarantees hold: no screenshot, no audio, no tool result, no vendor key outside
  Key Vault.
- The rows are personal data about ForIT staff (who asked what, when). They live in the ForIT subscription
  behind the storage account key, which the relay's identity and subscription owners hold. **Retention is
  a Ben decision, not made here**: rows are kept until deleted. A lifecycle rule or a purge job is a
  one-line follow-up once he names a period.
- A person who switches sharing off is invisible to the table from that turn on; nothing already stored is
  removed by the switch. Removing a person's rows is a manual operation on the table for now.
- The report is the timing instrumentation for the "why is the first sentence slow" question: the five
  milestones cover listening, model, speech and total, per turn, per Mac, without anyone reading `log show`.
