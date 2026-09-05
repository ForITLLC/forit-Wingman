# Proposal for for-Support: two read-only knowledge base routes for Wingman

Status: **proposed** (written in for-Wingman on 2026-09-05; for-Support owns the implementation).
Wingman already ships the client side (`Wingman/WingmanToolCatalog.swift`, decision `.ai/decisions.md` 003)
and hides the two tools until the gateway's `tools/list` shows them, so nothing breaks while this is open.

## Why

Ben: "Get those ready to answer Flex questions" and "the integration with support is the key part."
When a ForIT staff member asks Wingman how to do something in FL3XX, the answer has to come from the
ForIT knowledge base in for-Support, not from the model's memory. The KB exists (`kb_articles`, per
tenant plus `is_global`, `status`, `content`, `content_plain`, `ai_summary`) but today it has no route a
bearer token can call, so the for-mcp gateway cannot expose it as a `support_*` tool.

## What for-Support adds

Both routes are **read-only**, live under the admin API, and use the bearer auth the other
gateway-facing admin routes already use (`requireAdminSessionOrBearer(request)` from
`src/lib/adminAuth.ts`, which accepts the admin cookie session **or** the `SUPPORT_API_KEY` bearer the
gateway sends). Both are added to `src/app/api/openapi.json/route.ts` so the gateway auto-mounts them
from the spec (`for-mcp/manifests/support.json` reads the spec; no gateway code, then one
`gateway_spec_refresh`).

### 1. `GET /api/admin/kb/search` — new

OpenAPI `operationId: searchKbArticles` → gateway tool **`support_searchKbArticles`**.

Query parameters:

| Name | Required | Meaning |
|------|----------|---------|
| `q` | yes | Free text. Match with `LIKE '%term%'` on `title`, `summary`, `content_plain` (each whitespace-separated term, all must match, same style as `kbDraftFromTicket.ts`). |
| `tenant` | no, default `forit` | Tenant **slug**. Articles owned by that tenant **or** `is_global = 1`. Unknown slug → `404 {"error":"Tenant not found"}`. |
| `limit` | no, default 5, max 10 | Results. |

Filters always applied, not optional: `status = 'published'`. Drafts are never returned to a bearer
caller. When a tenant-owned article and a global one share a `slug`, the tenant-owned one wins.

Order: title match first, then `updated_at DESC`.

Response `200`:

```json
{
  "tenant": "forit",
  "total": 2,
  "articles": [
    {
      "article_id": "7C1E4A2B-…",
      "title": "How to activate FL3XX's TSA Secure Flight integration",
      "slug": "how-to-activate-tsa-screening",
      "summary": "Activation guide for the TSA Secure Flight integration through the DHS router.",
      "ai_summary": null,
      "category_name": "FL3XX",
      "tenant_slug": "forit",
      "is_global": false,
      "updated_at": "2026-09-01T10:00:00.000Z",
      "url": "https://support.forit.io/forit/kb/how-to-activate-tsa-screening"
    }
  ]
}
```

No `content` / `content_plain` in search results (Wingman drops them anyway; not sending them keeps
the gateway response small). `url` is the public article URL as for-Support builds it for that
tenant; if the tenant has a custom host, use that host.

### 2. `GET /api/admin/kb/{articleId}` — exists, open it to bearer callers

OpenAPI `operationId: getKbArticle` → gateway tool **`support_getKbArticle`**.

Today `src/app/api/admin/kb/[articleId]/route.ts` `GET` calls `requireAdmin()` (cookie only). Change the
`GET` handler only to `requireAdminSessionOrBearer(request)`; leave `PATCH` / `DELETE` as they are. For a
bearer caller also apply `status = 'published'` (`404` otherwise), so a draft cannot be read through the
gateway even with a guessed id.

Response stays `{ "article": { … } }` as today, plus two fields the gateway caller needs and the row
does not carry: `tenant_slug` and `url` (same value as in search). Wingman keeps `title`, `slug`,
`summary`, `ai_summary`, `category_name`, `tenant_slug`, `is_global`, `tags`, `updated_at`, `url` and one
body (`content_plain`, falling back to `content`), cut at 12,000 characters.

### OpenAPI entries (shape, for `openapi.json/route.ts`)

```ts
'/admin/kb/search': {
  get: {
    operationId: 'searchKbArticles',
    summary: 'Search published knowledge base articles for a tenant (plus global articles)',
    parameters: [
      { name: 'q', in: 'query', required: true, schema: { type: 'string' } },
      { name: 'tenant', in: 'query', schema: { type: 'string', default: 'forit' } },
      { name: 'limit', in: 'query', schema: { type: 'integer', default: 5, maximum: 10 } },
    ],
    responses: { '200': { description: 'Matching published articles' } },
  },
},
'/admin/kb/{articleId}': {
  get: {
    operationId: 'getKbArticle',
    summary: 'Read one published knowledge base article in full',
    parameters: [{ name: 'articleId', in: 'path', required: true, schema: { type: 'string' } }],
    responses: { '200': { description: 'The article' }, '404': { description: 'Not found or not published' } },
  },
},
```

The gateway derives the tool name from the manifest prefix (`support_`) plus the operationId, so the
two names above are fixed by these operationIds. If for-Support prefers different ids, tell for-Wingman
before merging: the app's catalog names them.

## Tenancy

Wingman always sends `tenant` (the model's value lower-cased, or `forit`). `forit` is ForIT's own
tenant (`F0817001-0001-0001-0001-000000000001`) and is where the FL3XX articles go first. When a Planet
Nine tenant exists in for-Support (there is none today; the six tenants are `cayres-inc`, `connect`,
`forit`, `great-north`, `wma`, `xceljet`), Planet Nine's own procedures are searched with
`tenant=planet-nine` with no app change. The per-user tenant scoping gap in
`docs/PERMISSIONS.md` 5.1 applies here exactly as to tickets: until WO#1908 lands, a signed-in ForIT
staff member can name any tenant; the routes themselves need no extra rule.

## Content: the `forit` tenant has zero FL3XX articles today

Grep of the for-Support repo and a ticket search (`support_listTickets search=fl3xx`, 2026-09-05) both
return nothing FL3XX. Without articles the tools work and the model correctly says "the knowledge base
has nothing on that yet".

Proposed seed, **Ben decision, not pre-cleared**: the `for-FL3XX` repo (session 39b72bf0d2b7432a,
`~/GitProjects/for-FL3XX`) holds `kb/fl3xx-knowledge-base/markdown/` — 443 markdown pages mirrored from
`https://www.fl3xx.com/kb/…`, each starting with an H1 and a `Source:` line — and
`kb/fl3xx-developer-portal/` (315 pages from `developer.fl3xx.com`). A one-off importer (for-Support side,
`POST /api/admin/kb` with the `CRON_SECRET` bearer, the path `kbDraftFromTicket.ts` already uses) would
create one article per help-centre page in tenant `forit`, category `FL3XX`, `tags: ["fl3xx"]`, title from
the H1, slug from the file name, `content` the markdown, `content_plain` rendered from it, `summary` the
first paragraph, and the `Source:` URL kept at the top of the body.

Two things only Ben can decide, so they are flagged rather than done:

1. **The text is FL3XX's.** Keeping an internal, staff-facing mirror that answers ForIT's own support
   staff and links back to the FL3XX source is the normal reseller / support-partner practice; publishing
   it on `support.forit.io` as ForIT articles visible to clients is not. Recommendation: import with the
   most restrictive `visibility` for-Support offers (staff-only), keep the source link, and let ForIT-written
   articles (ForIT's own FL3XX procedures for Planet Nine, gotchas, workarounds) be the ones that go public.
2. **Which pages.** The mirror includes FL3XX release notes and marketing pages ("Private cloud solutions
   at FL3XX", "Product update 5-11 September 2024"). Suggest importing only the how-to / reference pages
   (a title starting with "How to", or living under a KB category) and skipping product updates and
   press-style pages, so search results are procedures, not news.

## Verification once shipped

1. `curl -H "Authorization: Bearer $SUPPORT_API_KEY" "https://support.forit.io/api/admin/kb/search?q=tsa&tenant=forit"` returns published articles only.
2. `gateway_spec_refresh`, then `tools/list` on the gateway shows `support_searchKbArticles` and `support_getKbArticle`.
3. In Wingman (signed in as ForIT staff): "how do I turn on TSA screening in FL3XX" → the model calls search, then get, names the article, and does not describe steps the article does not contain. With an empty KB the same question gets "the knowledge base has nothing on that yet".

## What Wingman already does with these

- Describes both tools to the model only when `tools/list` exposes them; the prompt tells the model
  to say the KB is not connected otherwise.
- Requires `q`, forces `tenant`, clamps `limit` to 1…10, forwards nothing else.
- Requires `articleId` for a read, forwards nothing else.
- Keeps the citation fields from search results and cuts an article body at 12,000 characters.
- Tests: `WingmanTests/WingmanToolUseTests.swift` (argument policy, condensing, `tools/list` parsing,
  catalog narrowing).
