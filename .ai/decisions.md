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
  same document and waits for Ben's yes, because the text is FL3XX's.

### Consequences

- No FL3XX text, index or vendor key enters the app or the relay; the relay still forwards blocks only.
- A tenant-scoped KB is one argument away: Planet Nine's own articles are searched with `tenant: planet-nine`
  once that tenant exists in for-Support (it does not today; the six tenants are cayres-inc, connect, forit,
  great-north, wma, xceljet).
- The model can cite ("the article How to activate TSA Secure Flight says…") because search results carry
  `title` and `url`; it cannot quote a draft because the search route returns published articles only.
- The `tools/list` narrowing applies to every catalog tool, so a gateway that withdraws a tool stops it being
  offered rather than producing "that failed" answers.
