# Proposal for for-Support: declare `consent` on the ticket create route so the gateway forwards it

Written from for-Wingman on 2026-09-05 (decision 011). Cross-project writes are not made from here; this is
the ask, with the evidence, for the for-Support session to apply.

## The gap

`POST /api/admin/tickets` already does everything Wingman needs:

1. Without `confirmation_token` it returns `{ requires_confirmation: true, preview, confirmation_token }`
   and creates nothing.
2. With the token it creates the ticket, emails the requester, and runs `applySendRail` for the surface
   `ticket_create`, which answers **409 `send_rail_hold`** unless the request's `consent` string passes
   `src/lib/sendRailConsent.ts` (approve `\b(send|create|go ahead|approved?|proceed|ship it|do it)\b`,
   deny `\b(don'?t|do not|stop|cancel|deny|denied|nope|no|not)\b`, a `?` or a bare "yes" holds).

Wingman sends the person's own spoken words as `consent` on the confirming call. They never arrive.

The for-mcp gateway builds `support_createTicket` from `src/app/api/openapi.json/route.ts` with FastMCP
3.2.3, and its OpenAPI director (`fastmcp/utilities/openapi/director.py`) copies into the upstream request
**only the arguments named in the operation's parameter map**, which is the request body schema. The body
schema for `POST /admin/tickets` declares `tenantId`, `requester`, `subject`, `description`, `priority`,
`source`, `confirmation_token`, and not `consent` or `skipAutoReply`. So every confirming call from Wingman
reaches for-Support without `consent`, the rail holds it, and the ticket is never filed.

## The ask

In `src/app/api/openapi.json/route.ts`, on the request body schema of `POST /admin/tickets`, add:

```json
"consent": {
  "type": "string",
  "description": "The requesting person's own words approving the create (for example \"go ahead\" or \"create it\"). Judged by the send rail; a hold is answered 409 send_rail_hold."
},
"skipAutoReply": {
  "type": "boolean",
  "description": "true skips the requester email and the send rail. Default false."
}
```

Nothing else changes: the handler already reads both fields. After the spec changes, refresh the gateway's
spec (`gateway_spec_refresh`) so `tools/list` carries the new input schema.

Wingman does not send `skipAutoReply`; the requester email is part of filing a ticket. It is listed so the
declared schema matches the handler.

## What Wingman sends

Preview call (nothing created):

```json
{ "tenantId": "<uuid>", "requester": { "email": "pat@client.example", "displayName": "Pat Pilot" },
  "subject": "Cannot open the crew roster", "description": "…\n\nFiled by Sam Staff (sam@forit.io) with Wingman.",
  "priority": "medium", "source": "api" }
```

Confirming call, only after the app judged the person's words with the same vocabulary as
`sendRailConsent.ts` (a mirror, `WingmanSpokenConsent`), so a call that would be held is refused on the Mac:

```json
{ …the previewed arguments unchanged…, "confirmation_token": "<from the preview>", "consent": "go ahead and create it" }
```

The `Filed by … with Wingman.` line is there because the create is recorded under `automation@forit.io`
(`SUPPORT_API_KEY`); the agent working the ticket needs to know who asked for it.

## Verification once shipped

From a Mac running Wingman signed in as a ForIT operator, against a test tenant with a ForIT requester (a
create emails the requester): "put in a ticket for <ForIT person> at <test tenant>: …", hear the read-back,
say "go ahead", hear the ticket number, and see the ticket in the portal with the filed-by line. The Mac's
log shows `tool_called support_createTicket` twice with outcome `ok` and no `tool_error_http_409`.
