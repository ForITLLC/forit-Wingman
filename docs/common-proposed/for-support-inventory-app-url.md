# Proposal for for-Support: every inventory app carries its URL, and the gateway can list them

Status: **shipped** by for-Support on 2026-09-05 (WO#1979, forit-support master `f41f6f6`, evidence
`docs/evidence/2026-09-05-wo1979-inventory-app-url.md` in that repo). Written in for-Wingman on
2026-09-05 as a proposal; nothing here was a cross-project write. Wingman's side (a launcher: "open
the XcelJet AVHR site", an Apps section in the panel) is built against the `url` field below.

## As shipped (differences from the proposal below)

- Every row of `GET /api/v1/inventory/apps` and of `support_listInventoryApps` carries `url`,
  `hostnames` (array of strings) and `no_url_reason`, and the `tenant` filter accepts a slug. All
  three are editable on the Support inventory page.
- `no_url_reason` is new: an active row that has no front door (a triage category such as "Network"
  or "Managed Windows Devices") says why instead of counting as URL missing. Wingman leaves such a
  row out; it is not an error.
- ForIT's own apps carry `tenant_slug: "forit"` and `tenant_name: "ForIT"` rather than null.
- Verified from for-Wingman at 22:15Z with the call the app makes (`status: active`): 17 rows, 15
  with a url and 2 with a reason; the gateway answers 200, so the key problem below is gone.

## Why

Ben, 2026-09-05: "do we want to make this like a launcher too? Because it'll have like all the apps,
like inventory should contain all the DNS for all sites." And, on the shape: "Makes sense to me. It
also means that for support should ask for inventory to make sure that every URL is documented as
an attribute on both client and for IT apps."

Two things stand between that and a working launcher, both in for-Support / for-mcp:

1. **An inventory app has no URL.** `GET /v1/inventory/apps` returns `id, name, category, status,
   vendor, source, updated_at` (for-Support OpenAPI spec as the gateway holds it on 2026-09-05).
   Nothing says where the app lives, so nothing can open it.
2. **The gateway cannot call it.** `tools/call support_listInventoryApps` through the for-mcp
   gateway returns HTTP 401 on 2026-09-05: the route is guarded by `Bearer INVENTORY_API_KEY` and
   the key the gateway sends is rejected upstream. Every other `support_*` tool Wingman uses works
   with the same sign-in, so this is the one route's key, not the person's access.

## What for-Support adds

### 1. Two columns on the inventory apps table

| Column | Type | Meaning |
|--------|------|---------|
| `url` | `NVARCHAR(2048)` null | The front door a person opens: the sign-in page or the app's home, `https://` only. One per app. |
| `hostnames` | `NVARCHAR(MAX)` null, JSON array of strings | Every DNS name the app answers on (`avhr.xceljet.com`, `hr.forit.io`, an old alias that redirects). For DNS and certificate checks later, not for opening. |

Both apply to **client apps and ForIT's own apps alike**: the tenant row for XcelJet lists
`avhr.xceljet.com`, and ForIT's own row for for-Support lists `support.forit.io`. There is no
separate ForIT list.

### 2. "Every URL documented" is enforced in the admin page, not by the API

- The inventory admin form shows `url` and `hostnames` on every app.
- An app whose status is `active` and whose `url` is empty is flagged **URL missing** in the
  inventory list and counted on the inventory dashboard, so the gap is visible until it is closed.
  Saving an active app without a url is allowed (the record is still worth having) but the flag
  stays until someone fills it in. That is what "make sure that every URL is documented" means here:
  a standing report, not a hard stop that leads people to type a placeholder.
- The seed of existing rows is a one-time for-Support job from what for-Support already knows
  (its own module hostnames, the tenant `hostAliases`, the DNS zone), reviewed by a person before
  it lands. Nothing is guessed by Wingman.

### 3. `GET /v1/inventory/apps` returns the new fields, plus the tenant by name

Each row gains `url`, `hostnames`, `tenant_slug` and `tenant_name` (`null` for ForIT's own apps).
Today the route filters by `tenant` (a UUID) and returns no tenant on the row, so a caller cannot
say "the XcelJet one" without a second lookup. The filter should also accept a tenant slug.

Nothing else on the route changes. The spec's `description` line for the 200 response lists the
new fields so the gateway's generated tool description carries them.

## What for-mcp fixes

- The gateway's `INVENTORY_API_KEY` for the for-Support upstream is rejected (HTTP 401 on
  2026-09-05). Align the key on both sides, or move the route to the same bearer the other
  `support_*` routes accept, so `support_listInventoryApps` works for a signed-in person the way
  `support_listInventoryUsers` does.
- Refresh the support spec (`gateway_spec_refresh`) once the new fields are in the OpenAPI document.

## How Wingman uses it (for the record; no action for for-Support)

- The model calls `support_listInventoryApps` (active apps) when asked to open a ForIT or client
  app it does not have on the Mac, picks the row by name and tenant, and hands the row's `url` to
  Wingman's local open step, which opens it in the default browser. Wingman never opens an address
  that is not `http` or `https`, and it says which address it opened.
- The panel's Apps section lists the active apps that have a `url`, grouped by tenant, each with an
  Open button. The list is fetched after sign-in and hourly, the same way the vocabulary is, and is
  never on a spoken turn's critical path.
- Wingman keeps no copy of the inventory beyond that cached list and writes nothing to it.

## Open questions for for-Support

- Whether `hostnames` belongs on the app row or on a separate DNS table for-Support already plans
  (Ben's words were "all the DNS for all sites"; a separate table with an `app_id` is fine as long
  as the route returns the app's `url`).
- Whether inactive or pending apps should ever be returned to Wingman (proposal: no; the launcher
  offers only `active`).
