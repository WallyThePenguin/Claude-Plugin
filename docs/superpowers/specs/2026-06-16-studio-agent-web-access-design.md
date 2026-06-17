# Studio Agent — Web Access (`web_fetch` + `web_search`) Design

- **Date:** 2026-06-16
- **Status:** Approved design (user delegated judgment) — pending spec self-review, then plan.
- **Relates to:** `HANDOFF.md`; the capability-parity roadmap (feature #3, after subagents).
- **Scope:** ONE feature. Task tracking / memory / skills are separate, later specs.

## Goal

Give the in-Studio agent real **web access** — `web_fetch` (read any URL as text) and `web_search`
(search the web) — so it can read the Roblox documentation the system prompt already points at
(`create.roblox.com/docs/llms.txt`, the engine API index, any page as `.md`) and look up
APIs/solutions instead of guessing. The agent already has `HttpService` egress (it talks to the proxy
and the screenshot sidecar over it); these tools expose that as first-class read tools.

## Key decisions (professional judgment, delegated)

1. **Two tools in one module** (`Tools/Web.luau`): `web_fetch` and `web_search` are related reads and
   share an HTML→text helper.
2. **`web_fetch` returns text.** Roblox docs fetched as `.md`/`llms.txt` are already clean markdown.
   General web pages are HTML — strip to readable text (drop `<script>`/`<style>`, strip tags, decode
   a few entities, collapse whitespace) so they're usable; non-HTML bodies pass through raw.
3. **`web_search` = DuckDuckGo HTML scrape**, no API key. Best-effort: parse the top results; if DDG
   blocks or its markup changes, return a clean "no results" message rather than erroring. `web_fetch`
   is the robust path; `web_search` is convenience.
4. **Both are `destructive=false`** (pure reads) and are ADDED to the subagent read-only allowlist, so
   a "research" subagent can read docs in parallel.
5. **Truncate** fetched bodies to `webFetchMaxChars` (default 20000) to protect the context window;
   compaction is the backstop for anything that slips through.
6. Server-only, like the rest of HTTP — works in edit / the Server view, not a client-view playtest.

## Baseline (existing patterns to follow)

- `Anthropic.request` and `Tools/Capture.luau` both show the canonical `HttpService:RequestAsync`
  handling: a `pcall` (RequestAsync RAISES on transport / HTTP-disabled / server-only-context) plus a
  `response.Success` check (non-2xx). Reuse this exact shape.
- `HttpService:UrlEncode(s)` percent-encodes a query (used by `Capture`).
- Tools are descriptor modules concatenated by `Tools/init.luau`; each carries `destructive`.
- The subagent read-only set lives in `Tools/Subagents.luau` as `READ_ONLY`.
- Config follows the DEFAULTS + validation + getter pattern.

## Design

### Component 1 — `src/Tools/Web.luau`

Exports `descriptors` (a list with the two tools) plus internal helpers.

**`stripHtml(body) -> string`** (pure, exported for the spec): if `body` contains `<html`/`<body`/
`<!doctype html` (case-insensitive) it's treated as HTML →
1. remove `<script ...>...</script>` and `<style ...>...</style>` blocks (with their contents),
2. replace `<br>`/`</p>`/`</div>`/`</li>` and block tags with newlines,
3. strip all remaining `<...>` tags,
4. decode `&amp; &lt; &gt; &quot; &#39; &nbsp;`,
5. collapse 3+ newlines to 2 and trim trailing spaces.
Non-HTML bodies are returned unchanged.

**`web_fetch` descriptor** (`destructive = false`):
- Input: `{ url: string (required), maxChars?: integer }`.
- Validates `url` is a non-empty string starting with `http://` or `https://` (else error).
- `RequestAsync { Url = url, Method = "GET" }` inside the canonical bimodal handler.
- On 2xx: `text = stripHtml(response.Body)`, truncated to `min(maxChars or webFetchMaxChars,
  webFetchMaxChars)` chars (append `"\n…[truncated]"` when cut). Returns the text (a plain string
  tool_result), `isError = false`.
- On failure: a clear string error (`isError = true`) — HTTP-disabled hint, server-only hint,
  transport, or `"web_fetch: HTTP <status>"` for non-2xx.

**`web_search` descriptor** (`destructive = false`):
- Input: `{ query: string (required), maxResults?: integer }`.
- GET `https://html.duckduckgo.com/html/?q=<UrlEncode(query)>` with a `User-Agent` header.
- Parse result blocks: DDG's HTML wraps each result link in `class="result__a"` (the title+href) and
  the snippet in `class="result__snippet"`. Extract `href` + inner text (via `stripHtml`) for up to
  `min(maxResults or webSearchMaxResults, webSearchMaxResults)` results. DDG href is a redirect
  (`/l/?uddg=<encoded real url>`); decode the `uddg` param to the real URL when present.
- Returns `encodeResult({ ok = true, query = …, results = { {title, url, snippet}… } })` as a JSON
  string. Zero parsed results → `{ ok = true, results = {}, note = "no results parsed (DuckDuckGo may
  have blocked or changed markup); try web_fetch with a known URL" }`. On request failure → a string
  error like the other tools.

### Component 2 — `src/Tools/init.luau`

Require `Web` and append its descriptors (after `CaptureTool`, before/around `SubagentsTool`).
Registry becomes: …, `capture`, `web_fetch`, `web_search`, `dispatch_subagents`.

### Component 3 — `src/Tools/Subagents.luau`

Add `"web_fetch"` and `"web_search"` to the `READ_ONLY` list so read-only children can research.
(`dispatch_subagents` stays excluded → still depth-1.)

### Component 4 — `src/Config.luau`

| key | default | meaning |
|-----|---------|---------|
| `webFetchMaxChars` | `20000` | max chars returned by web_fetch (hard cap) |
| `webSearchMaxResults` | `5` | max results returned by web_search |

Both validate `>= 1` (and `webFetchMaxChars >= 100`), with getters.

### Component 5 — `src/SystemPrompt.luau`

- A "Web access" section in the parent `BASE`: `web_fetch(url)` reads a page as text — use it to read
  the Roblox docs (fetch `https://create.roblox.com/docs/reference/engine/llms.txt` for the API index,
  then any page as its URL + `.md` for clean markdown) and to read pages found via `web_search`;
  `web_search(query)` finds pages. Prefer fetching official docs over guessing an API.
- Update the existing "Authoritative APIs" section: it lists the doc URLs — now note the agent can
  actually `web_fetch` them.
- Mention in `buildSubagent`'s tool list that children also have `web_fetch`/`web_search` for research.

## Data flow

```
web_fetch(url)  -> RequestAsync GET url -> stripHtml(body) -> truncate -> text (string tool_result)
web_search(q)   -> RequestAsync GET ddg/html?q=... -> parse result__a/result__snippet -> JSON tool_result
```

## Error handling

- Canonical RequestAsync bimodal handling (mirror `Anthropic.request`): pcall-raise → classify
  (HTTP-disabled / server-only "game server" / transport); `response.Success == false` → HTTP status.
- Every failure returns a STRING error with `isError = true` — the tool is total (never throws), so a
  tool_use always gets a tool_result.
- `web_search` parse failure degrades to a clean "no results" note, never an exception.
- Truncation is explicit and flagged (`…[truncated]`), so the agent knows the page was cut.

## Testing

In-Studio self-test (`WebSpec`, like `CompactorSpec`/`SubagentsSpec`) for the PURE pieces (no
network):

- `stripHtml`: a sample HTML string with `<script>`, `<style>`, tags, and entities → asserts the
  script/style content is gone, tags are stripped, entities decoded, and known text survives; a
  plain-text/markdown body passes through unchanged.
- `web_search` parsing: a sample DDG result-page HTML snippet → asserts it extracts the expected
  title/url/snippet and decodes a `/l/?uddg=` redirect to the real URL; an empty/garbage page → 0
  results (no throw).
- Static: `selene` (0 errors) + `stylua --check` + `rojo build`.
- Adversarial review over the diff (RequestAsync handling, truncation, the HTML/DDG parsing, the
  subagent-allowlist addition).
- Live test (Studio, via computer-use): "fetch `https://create.roblox.com/docs/reference/engine/
  classes/ProximityPrompt.md` and summarize it" (robust path) and "web_search for roblox
  ProximityPrompt" (best-effort), plus a research subagent that fetches a doc.

## Non-goals (v1)

- No JavaScript rendering, no authenticated fetches, no crawling/link-following, no response caching.
- One fetch / one search per call (the model can call repeatedly; subagents parallelize).
- No domain allowlist — the agent already has unrestricted `HttpService` via `run_luau`, so `web_fetch`
  adds no new security boundary; keeping it open lets it read any doc/site the user needs.
