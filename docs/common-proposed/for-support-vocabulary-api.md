# Proposal for for-Support: the vocabulary Wingman pulls (one read-only route, one admin page)

Status: **proposed** (written in for-Wingman on 2026-09-05). Wingman ships its side first: it calls
`support_listVocabulary` as soon as the gateway's `tools/list` shows it and keeps its built-in FL3XX
term until then (`Wingman/WingmanVocabulary.swift`, decision `.ai/decisions.md` 013). Nothing here is
a cross-project write; for-Support ships it when the for-Support session picks it up.

## Why

Ben, 2026-09-05: "I still hate that you have a dictionary where you can delete terms from versus
something that's pulled in from ForIT support, because that's super valuable in my mind."

Wingman 0.1.5x kept a vocabulary per Mac, added and removed in its panel. A term ForIT support learns
(FL3XX said as "Flex", VMO, a client's own product names) should be entered once, in ForIT Support,
and reach every Wingman. The list is small (tens of rows), read far more often than written, and
belongs with the knowledge base it describes.

## What for-Support adds

### 1. Table `wingman_vocabulary` (migration `140-wingman-vocabulary.sql`, same schema as `kb_articles`)

| Column | Type | Meaning |
|--------|------|---------|
| `term_id` | `UNIQUEIDENTIFIER` PK, default `NEWID()` | Stable id; Wingman keeps it as the term's identity across fetches. |
| `canonical_spelling` | `NVARCHAR(100)` not null | The written form the model, the knowledge base and the tools use, e.g. `FL3XX`. |
| `spoken_forms` | `NVARCHAR(400)` not null | JSON array of what people say, e.g. `["Flex"]`. The first one is how Wingman pronounces the term. |
| `meaning` | `NVARCHAR(400)` not null, default `''` | One line for the model, e.g. "the flight operations and scheduling platform ForIT supports". |
| `tenant_id` | `UNIQUEIDENTIFIER` null | `NULL` = every tenant. A client-specific term carries its tenant; the route returns it to every staff caller either way (the field groups the admin page and reserves a per-client filter). |
| `is_active` | `BIT` not null, default 1 | A retired term stays for history and is not returned. |
| `created_at`, `updated_at` | `DATETIME2` | |
| `updated_by` | `NVARCHAR(200)` | The admin who last changed it. |

Unique filtered index on `canonical_spelling` where `is_active = 1`. Idempotent, re-runnable, in the
style of `139-wo1949-ai-assistant-flags.sql`.

**Seed** (in the migration): `FL3XX` / `["Flex"]` / "the flight operations and scheduling platform
ForIT supports; its how-to articles are in the ForIT knowledge base". That is Wingman's built-in
term, so the first fetch changes nothing a person can hear. Ship the seed with the route: Wingman
treats an **empty** list as "not published yet" and keeps its built-in term, so a route with no rows
never makes FL3XX disappear.

### 2. `GET /api/admin/vocabulary` — new, read-only

OpenAPI `operationId: listVocabulary` → gateway tool **`support_listVocabulary`**. No parameters.

Auth: `requireAdminSessionOrBearer(request)` from `src/lib/adminAuth.ts`, exactly as
`/api/admin/kb/search` (admin cookie session **or** the gateway's bearer). Active terms only, ordered
by `canonical_spelling`.

Response `200`:

```json
{
  "terms": [
    {
      "term_id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
      "canonical_spelling": "FL3XX",
      "spoken_forms": ["Flex"],
      "meaning": "the flight operations and scheduling platform ForIT supports; its how-to articles are in the ForIT knowledge base",
      "tenant_slug": null,
      "updated_at": "2026-09-05T20:00:00.000Z"
    }
  ],
  "total": 1,
  "updated_at": "2026-09-05T20:00:00.000Z"
}
```

Wingman reads `term_id`, `canonical_spelling`, `spoken_forms` (an array, or one comma-separated
string) and `meaning`, and ignores the rest, so fields can be added freely. A row with a blank
`canonical_spelling` is dropped on the Mac.

OpenAPI block for `src/app/api/openapi.json/route.ts` (the gateway mounts it from the spec after one
`gateway_spec_refresh`, no gateway code):

```ts
    // for-Wingman vocabulary (for-Wingman docs/common-proposed/for-support-vocabulary-api.md).
    // Read-only; the gateway mounts it as support_listVocabulary. Writes are cookie-session
    // admin routes and are deliberately NOT declared here.
    '/admin/vocabulary': {
      get: {
        operationId: 'listVocabulary',
        summary: 'List the vocabulary Wingman applies (how a term is written, said and what it means)',
        description: 'Active wingman_vocabulary rows ordered by canonical_spelling: { terms[{ term_id, canonical_spelling, spoken_forms[], meaning, tenant_slug, updated_at }], total, updated_at }. Wingman fetches this after sign-in and hourly; nothing is edited from the gateway.',
        parameters: [],
        responses: {
          '200': { description: 'The vocabulary' },
        },
      },
    },
```

### 3. Admin page `/admin/vocabulary` (cookie session only)

Add, edit and retire terms; a "Vocabulary" entry in `AdminSubnav.tsx` beside Knowledge Base. The
write routes (`POST /api/admin/vocabulary`, `PATCH` and `DELETE /api/admin/vocabulary/{termId}`)
use `requireAdmin()` and are **not** declared in `openapi.json`, so the gateway never mounts them:
Wingman and the model can only read. Retiring sets `is_active = 0`.

## How Wingman uses it (shipped in for-Wingman)

- After sign-in, and on push-to-talk key-down once the stored list is an hour old, the app checks
  the gateway's `tools/list` for `support_listVocabulary`, calls it with the person's own gateway
  token, and replaces the stored list (`~/Library/Application Support/io.forit.wingman/vocabulary.json`).
  The tool is never described to the model and no spoken turn waits for the fetch.
- The list drives the four uses in `WingmanVocabulary.swift`: Apple Speech keyterms, the transcript
  rewrite to the canonical spelling, the prompt section, and the pronunciation rewrite before
  text-to-speech.
- The panel's Vocabulary section is read-only and says where the list came from: "From ForIT
  Support, updated 3 min. ago" or "Built in until ForIT Support publishes its vocabulary".
- Mac log: `vocabulary_refreshed terms=N` (notice) on success, `vocabulary_refresh_failed reason=…`
  (error) otherwise; a failure keeps the current list and is retried after five minutes.

## Verification once shipped

1. Gateway: `tools/list` for a ForIT staff account includes `support_listVocabulary`; calling it
   returns the seed row.
2. Ben's Mac, after a sign-in or the next key-down:
   `log show --predicate 'subsystem == "io.forit.wingman"' --last 1h | grep vocabulary_` shows
   `vocabulary_refreshed terms=1`, and the panel's Vocabulary section reads "From ForIT Support".
3. Add a term on `/admin/vocabulary` (say `VMO`, said "vee em oh"); within the hour, or after a
   sign-out and sign-in, the panel lists it and a spoken "vee em oh" reaches the model as `VMO`.
