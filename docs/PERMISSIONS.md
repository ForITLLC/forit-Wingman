# Wingman permission levels

Wingman never holds a data credential. Every read or write of ForIT data is a tool call to the
for-mcp gateway made with the **signed-in user's own Entra token**, and every model call goes
through the Wingman relay with that same identity. The tables below say who can do what, where
the check runs, and what the user sees when it is refused.

Guarding lives in the server, never in the client (`for-Common/docs/mcp-platform-law.md`). The app
only mirrors the server's answer in the UI.

## 1. Sign-in

| Step | Where enforced | Behaviour |
|------|----------------|-----------|
| Sign in with a ForIT-tenant Microsoft account (PKCE, system browser) | Entra tenant `c0efa09e-4bda-4a9d-a177-4c77076b7f76` | Only tenant members. Guests are rejected by the relay (`rejectGuests`). No sign-in, no push-to-talk. |
| Token storage | macOS Keychain, app-scoped | Refresh token only; access tokens live in memory. Sign-out wipes both. |

## 2. Levels

Levels are the for-mcp gateway app roles on app `861db494-6d36-4d7d-83c4-39352d3e9576`
(`for-mcp/server.py:140-150`, `:200-241`). Wingman adds nothing on top; it asks the gateway and shows the answer.

| Level | Entra app role | Gateway scope | What Wingman lets the user do by voice |
|-------|----------------|---------------|-----------------------------------------|
| **Viewer** | `Reader` | `tools.read` | Ask questions: list tickets, summarise a ticket, look up a flight. Screenshots go to the model; nothing is written anywhere. |
| **Operator** | `Writer` | `tools.write` | Everything above, plus **draft** actions: add a ticket note, save a reply as a draft. Nothing is sent to a customer. |
| **Admin** | `Admin` | `tools.admin` | Everything above, plus gateway admin tools. Wingman exposes no extra UI for this level. |
| none | no role | rejected (`401`) | Sign-in succeeds but every tool call is refused; the panel shows "Your account has no Wingman access. Ask support+wingman@forit.io." |

Role assignment is an Entra enterprise-app assignment, done by a ForIT admin, never by the app.

## 3. Actions and their gates

| Voice intent | Tool(s) | Minimum level | Side effect |
|--------------|---------|---------------|-------------|
| "What open tickets does `<client>` have?" | `support_listTickets` | Viewer | none |
| "Summarise ticket `<n>` and what is blocking it" | `support_listTickets` (by id) | Viewer | none |
| "Draft a reply to ticket `<n>`" | `support_addTicketNote` | Operator | Writes an **internal note prefixed `DRAFT (Wingman):`** on the ticket. Never `support_replyToTicket`, never an email. |
| "What is the status of flight `<id>`?" | `forit_avops_search_flights` | Viewer | none |
| "How do I `<do something>` in FL3XX?" (or any supported system) | `support_searchKbArticles`, then `support_getKbArticle` | Viewer | none. Searches the `forit` tenant's published articles (including the staff-only FL3XX mirror, `visibility: internal`) unless the user names a client; the app fixes the default tenant, the model cannot widen it, and a product name from the taught vocabulary (`FL3XX`, "Flex") given as the tenant is sent to the default tenant instead. |
| Anything that sends, deletes, assigns, bulk-updates, or provisions | `support_replyToTicket`, `support_deleteTicket`, `support_assignTicket`, `support_bulkUpdateTickets`, `support_provisioning*` | **not exposed** | Wingman does not register these tools with the model at all. |

The tool allow-list is a static array in the app (`WingmanToolCatalog.swift`); a tool not on it is
never described to the model, so the model cannot call it even if the gateway would allow it. The
list is also narrowed, per turn, to what the gateway's `tools/list` exposes to the signed-in person
(cached 15 minutes per account): a catalog tool the gateway does not have yet is not described to
the model at all, so it cannot be "called and fail". If `tools/list` fails, the whole catalog is
offered and a missing tool surfaces as an error `tool_result`.

## 4. Refusals in the UI

| Cause | Where detected | What the user sees |
|-------|----------------|--------------------|
| Token rejected / client not allow-listed / no gateway role | gateway `401` on `tools/call` | Panel banner "Wingman access denied for `<upn>`. Ask a ForIT admin for a gateway role." and the fixed spoken reply "I can't do that with your current access." The model is not consulted for that turn. |
| Level too low (Reader asks to draft) | gateway `403 insufficient_scope` on `tools/call` | Fixed spoken reply naming the tool's minimum level from the catalog: "That needs Operator access." Panel banner names the tool and the level. |
| Tool not on the allow-list, or malformed arguments | app, before the call (`WingmanToolCatalog.prepareCall`) | Returned to the model as an error `tool_result` ("… is not something Wingman can do."); the model tells the user in its own words. Cannot normally happen: the model only sees allow-listed tools. |
| Tool ran and failed (ticket not found, gateway error) | gateway `isError` / non-2xx | Error `tool_result`; the model says what failed and never invents the answer (system prompt). |
| Relay refuses (guest, bad audience) | relay `401` | Sign-in dropped locally, spoken "Sign in to Wingman with your ForIT account…", panel opens on the account row. |

Implementation: `CompanionManager.runModelTurnWithGatewayTools` (tool loop, at most 4 tool rounds per
spoken question, then one forced answer with `tool_choice: none`), `WingmanToolCatalog` (allow-list +
argument policy), `WingmanGatewayToolClient` (MCP Streamable HTTP with the user's `access_as_user`
token). The relay forwards `tools` / `tool_use` / `tool_result` to Anthropic and never executes a tool.

## 5. Known gaps (reported to the Commander, owned elsewhere)

1. **No per-user tenant scoping on `support_*`.** The gateway calls support.forit.io with one shared
   `SUPPORT_API_KEY` (`for-mcp/manifests/support.json:5-7`, `server.py:1368-1376`); `tenant` is a filter the
   caller supplies, not a constraint derived from the user. A Viewer at one client could, in principle, ask
   about another client's tickets. The fix is gateway-side (`for-mcp/docs/per-user-rbac.md`, phases 1-3,
   unbuilt, Ben-gated; routed by the Commander as WO#1908). **INTERIM for phase 1, accepted by the Commander
   2026-09-04, not the design:** Wingman is **ForIT staff only** and the relay rejects any UPN outside
   `@forit.io`. The design is per-user identity pass-through on `support_*`; when WO#1908 lands, the UPN
   filter comes out and no Wingman code changes. Owner: for-mcp / for-Support.
2. **Delegated token for the native client: RESOLVED 2026-09-04 (for-mcp WO#1908).** The gateway accepts a
   delegated token only from an allow-listed native client; Wingman uses **ForIT-Wingman-Client** (`acc81527-1818-4c79-8f59-0bfc111701d4`)
   and requests `api://861db494…/access_as_user` (user-consentable, pre-authorised, no consent screen). The
   user's gateway app role (Reader / Writer / Admin) becomes `tools.read` / `tools.write` / `tools.admin` on the
   token; no role = HTTP 403 `insufficient_scope`. The earlier **ForIT Wingman** registration was never allow-listed, is not used by the app, and
   was deleted by for-mcp on 2026-09-05 (WO#1910); nothing in the app or the relay refers to it. Recipe:
   for-mcp `docs/native-clients.md` §3.
3. **No FL3XX tools on the gateway.** FL3XX exists only as a docs corpus (`for-FL3XX`). Flight questions run
   against the VMO-backed `forit_avops_search_flights` until FL3XX credentials exist (Ben decision).
4. **The gateway grants every verified ForIT-tenant JWT the full tool surface.** `for-mcp/server.py` (about
   lines 228-236) stamps `surface:full` on any bearer token that validates against the tenant, without
   reading the caller's app roles or `scp`. So today the Viewer / Operator / Admin levels in section 2 are
   what the gateway *will* enforce, not what it enforces. Until WO#1908 lands, the only thing that stops a
   signed-in ForIT staff member from reaching `support_replyToTicket`, `support_deleteTicket` or the
   provisioning tools through Wingman is the app's own static allow-list (section 3), which is why that list
   is compiled in and not configurable. Reported to the Commander 2026-09-04 as part of WO#1908.
   Owner: for-mcp.
5. **Knowledge base read tools: routes and gateway mount shipped 2026-09-05; content is the open part.**
   for-Support `a24e57f` added `GET /api/admin/kb/search` and opened `GET /api/admin/kb/{articleId}` to the
   bearer path (published articles only, `404` otherwise; evidence for-Support `12ff392`,
   `docs/evidence/2026-09-05-kb-read-api-for-wingman.md`). The gateway re-mounted the support family from the
   spec and `tools/list` now carries 27 `support_*` tools including `support_searchKbArticles` and
   `support_getKbArticle`, so Wingman describes both to the model. Verified from for-Wingman on 2026-09-05
   through the gateway itself: a search on tenant `forit` answers `{tenant, total, articles}`, an unknown
   tenant is `404`, an article read carries `tenant_slug` and `url`, an unknown id is `404`. The contract as
   shipped is `docs/common-proposed/for-support-kb-read-api.md`. (a) **Content: closed 2026-09-05.** The `forit`
   tenant now holds the 346-page FL3XX mirror (curated set, for-FL3XX `46244dc`; import for-Support `f38e469`),
   decided GO by Ben on 2026-09-05 with one hard constraint, verbatim "nothing should be public": every article
   is `visibility: internal`, its `url` is the admin page, the public KB shows none of them (anonymous requests
   are sent to sign-in), and the gateway search returns them to a bearer caller (re-verified from for-Wingman:
   `q=tsa` → 10, `q=fl3xx` → 346, article read carries `visibility: internal`). Still open: (b) for-Support proved
   the routes with the shared `SUPPORT_API_KEY` bearer only, which is the path the gateway uses today (gap 1),
   so per-user scoping of KB reads arrives with WO#1908 like every other `support_*` call. Owner: for-Support
   (import + internal visibility), for-mcp (WO#1908).

## 6. Usage sharing (decision 010)

What leaves the Mac besides the model call and the tool calls: **one usage report per spoken turn**, sent
to the relay's `POST /api/usage` with the same id_token as `/api/chat`, unless the person has switched
"Share usage with ForIT" off in the panel. It is on by default and the panel discloses it before the first
question (above the Start button; a Mac that onboarded earlier sees it once with "Got it").

| In the report | Never in the report |
|---------------|---------------------|
| the question (after the vocabulary rewrite), the spoken answer, the model, the app version | the screenshot |
| each tool call: name, outcome (`ok` / `error` / `refused`) and, for a knowledge base search, the keywords sent | the audio, the transcript's partial results |
| model rounds, whether the cursor pointed, whether the turn was answered / failed / interrupted | any tool result (ticket bodies, article text, flight data) |
| five timings from the final transcript: listening, first model text, first speech, answer complete, total | the conversation history, the gateway token |

The relay attributes the row to the person from the verified token (email, display name, object id),
never from the body, bounds every field and drops anything it does not know, and keeps it in the Azure
Table `wingmanusage` of its own storage account. `WINGMAN_USAGE_RECORDING=off` on the relay stops the
storing fleet-wide; the app is told `{stored:false}` and logs it. A turn that ended for want of a sign-in
sends nothing. Retention: rows are kept until deleted (Ben decision pending); the switch stops future
rows and does not remove stored ones.
