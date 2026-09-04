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
| Anything that sends, deletes, assigns, bulk-updates, or provisions | `support_replyToTicket`, `support_deleteTicket`, `support_assignTicket`, `support_bulkUpdateTickets`, `support_provisioning*` | **not exposed** | Wingman does not register these tools with the model at all. |

The tool allow-list is a static array in the app (`WingmanToolCatalog.swift`); a tool not on it is
never described to the model, so the model cannot call it even if the gateway would allow it.

## 4. Refusals in the UI

| Cause | Where detected | What the user sees |
|-------|----------------|--------------------|
| No role / expired role | gateway `401` on `tools/call` | Panel banner "Wingman access denied for `<upn>`" and the spoken reply "I can't do that with your current access." |
| Level too low (Viewer asks to draft) | gateway `403` on `tools/call` | Spoken reply names the missing level: "That needs Operator access." |
| Tool not on the allow-list | app, before the call | Spoken reply "That isn't something Wingman can do." |
| Relay refuses (guest, bad audience) | relay `401` | Panel shows "Signed in with the wrong account" and offers sign-out. |

## 5. Known gaps (reported to the Commander, owned elsewhere)

1. **No per-user tenant scoping on `support_*`.** The gateway calls support.forit.io with one shared
   `SUPPORT_API_KEY` (`for-mcp/manifests/support.json:5-7`, `server.py:1368-1376`); `tenant` is a filter the
   caller supplies, not a constraint derived from the user. A Viewer at one client could, in principle, ask
   about another client's tickets. The fix is gateway-side (`for-mcp/docs/per-user-rbac.md`, phases 1-3,
   unbuilt, Ben-gated; routed by the Commander as WO#1908). **INTERIM for phase 1, accepted by the Commander
   2026-09-04, not the design:** Wingman is **ForIT staff only** and the relay rejects any UPN outside
   `@forit.io`. The design is per-user identity pass-through on `support_*`; when WO#1908 lands, the UPN
   filter comes out and no Wingman code changes. Owner: for-mcp / for-Support.
2. **Delegated scopes for the native client: resolved on the Entra side, open on the gateway side.**
   The gateway registration `api://861db494…` exposes the delegated scopes `tools.read` and `tools.write`, and
   the **ForIT Wingman** public client (`36021471-d468-4f12-9c83-e5a73f957752`) was granted admin consent for
   both on 2026-09-04, so the app obtains a gateway access token from its own PKCE sign-in. What remains is
   item 4 below: the gateway does not yet honour those scopes. Owner: for-mcp.
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
