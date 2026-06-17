# Server-Side Web Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plugin's client-side `web_fetch`/`web_search` (run via Roblox `HttpService`, hard-blocked from `roblox.com`) with Anthropic's **direct server-side** web tools (`web_search_20250305` / `web_fetch_20250910`), which execute on Anthropic's infrastructure and reach the whole web including `roblox.com`.

**Architecture:** Server tools are declared as `{type, name}` entries in the request's `tools` array; the model emits `server_tool_use`, Anthropic executes them and inserts `*_tool_result` blocks into the same assistant turn. The plugin **never dispatches** them — the agent loop already collects only `block.type == "tool_use"`, and `isValidHistory` / `pause_turn` handling are already compatible (verified in code). So this is: declare the server tools, stop declaring the client-side ones (same names), delete the client-side module, and rewrite the docs.

**Tech Stack:** Roblox Luau plugin; Rojo build; `selene` lint; `stylua` format. Spec: `docs/superpowers/specs/2026-06-17-studio-agent-server-side-web-tools-design.md`.

**Testing note (read this — it changes the step shape):** Luau that uses Roblox datatypes/APIs **cannot be executed outside Studio**, and this feature *deletes* the only pure (unit-testable) helpers (`Tools/Web.luau`'s `stripHtml`/`parseDdg`) rather than adding any. So per-task verification is the **static gate** — `selene src` (0 errors; 1 known `CreateDockWidgetPluginGui` warning), `stylua --check src` (clean), and `rojo build default.project.json -o StudioAgent.rbxm` (compiles, catching dangling `require`s) — NOT red-green unit tests. The existing in-Studio Spec modules (`SubagentsSpec`, `WritersSpec`) are **unaffected** (their local tool lists are web-free, so the server-tool append doesn't change their counts). Real behavioral verification is the adversarial-review Workflow + the in-Studio live-verify in Task 7.

**Commands (PowerShell, from repo root `C:\Users\manso\Desktop\Claude-Plugin`):**
- Format: `stylua src`
- Format check: `stylua --check src`
- Lint: `selene src`  → expect `Results: 0 errors` (and the 1 known warning about `CreateDockWidgetPluginGui`)
- Compile check: `rojo build default.project.json -o StudioAgent.rbxm`  → expect it to write `StudioAgent.rbxm` with no error
- Build + install (final): `.\build.ps1`

---

### Task 1: Config — swap the web knobs

The client-side caps (`webFetchMaxChars`, `webSearchMaxResults`) become dead once `Tools/Web.luau` is deleted. Replace them with `max_uses` caps for the server tools.

**Files:**
- Modify: `src/Config.luau` (DEFAULTS ~line 44-46; `set` validation ~line 236-245; getters ~line 336-342)

- [ ] **Step 1: Edit the DEFAULTS block**

In `src/Config.luau`, replace:

```lua
	-- Web access (web_fetch / web_search).
	webFetchMaxChars = 20000, -- hard cap on characters returned by web_fetch
	webSearchMaxResults = 5, -- max results returned by web_search
```

with:

```lua
	-- Web access (Anthropic SERVER-SIDE web_search/web_fetch). `max_uses` bounds calls per turn.
	webSearchMaxUses = 5, -- max server-side web_search calls per turn
	webFetchMaxUses = 5, -- max server-side web_fetch calls per turn
```

- [ ] **Step 2: Edit the `set` validation branches**

In `src/Config.luau`, replace:

```lua
	elseif key == "webFetchMaxChars" then
		if type(value) ~= "number" or value ~= value or value < 100 then
			return false, "webFetchMaxChars must be >= 100"
		end
		value = math.floor(value)
	elseif key == "webSearchMaxResults" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "webSearchMaxResults must be >= 1"
		end
		value = math.floor(value)
	end
```

with:

```lua
	elseif key == "webSearchMaxUses" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "webSearchMaxUses must be >= 1"
		end
		value = math.floor(value)
	elseif key == "webFetchMaxUses" then
		if type(value) ~= "number" or value ~= value or value < 1 then
			return false, "webFetchMaxUses must be >= 1"
		end
		value = math.floor(value)
	end
```

- [ ] **Step 3: Edit the getters**

In `src/Config.luau`, replace:

```lua
function Config.getWebFetchMaxChars(self: Config): number
	return self:get("webFetchMaxChars") :: number
end

function Config.getWebSearchMaxResults(self: Config): number
	return self:get("webSearchMaxResults") :: number
end
```

with:

```lua
function Config.getWebSearchMaxUses(self: Config): number
	return self:get("webSearchMaxUses") :: number
end

function Config.getWebFetchMaxUses(self: Config): number
	return self:get("webFetchMaxUses") :: number
end
```

- [ ] **Step 4: Format, lint, compile**

Run: `stylua src; stylua --check src; selene src; rojo build default.project.json -o StudioAgent.rbxm`
Expected: stylua check clean; selene `0 errors` (+ the 1 known warning); rojo writes `StudioAgent.rbxm` with no error.
(`Tools/Web.luau` still calls the old getters at this point — that's fine: it's deleted in Task 3, and selene/rojo don't resolve cross-module method calls, so this compiles. Do NOT delete Web.luau yet.)

- [ ] **Step 5: Commit**

```bash
git add src/Config.luau
git commit -m "config: swap web knobs to server-tool max_uses (webSearchMaxUses/webFetchMaxUses)"
```

---

### Task 2: Tools/init — drop the client web tools, add server-tool definitions

**Files:**
- Modify: `src/Tools/init.luau` (require ~line 21; append loop ~line 85-87; `schemas` ~line 107-117; `schemasFor` ~line 120-136; header comment ~line 12-13)

- [ ] **Step 1: Remove the client-side Web require**

In `src/Tools/init.luau`, delete this line (~line 21):

```lua
local WebTool = require(script.Web)
```

- [ ] **Step 2: Remove the Web descriptors append loop**

In `src/Tools/init.luau`, delete this block (~line 85-87):

```lua
for _, descriptor in WebTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

- [ ] **Step 3: Add the server-tool definitions**

In `src/Tools/init.luau`, immediately AFTER the `byName` map is built (after the `for _, descriptor in registry do byName[descriptor.name] = descriptor end` loop, ~line 104) and BEFORE `function Tools.schemas`, insert:

```lua
-- Server-side web tools: executed by ANTHROPIC, not dispatched locally (see AgentLoop). Declared as
-- {type,name} entries with NO input_schema and NO run handler — the model emits a `server_tool_use`
-- block and the API inserts the matching `*_tool_result` block into the same assistant turn. Use the
-- DIRECT versions: the code-execution-backed `_20260209` variants return `too_many_requests` on the
-- subscription path (the code-execution sandbox is quota-capped). `max_uses` bounds calls per turn.
local SERVER_TOOL_TYPES: { [string]: string } = {
	web_search = "web_search_20250305",
	web_fetch = "web_fetch_20250910",
}
-- Deterministic emission order (tools render at prompt position 0; a stable order keeps prompt
-- caching intact).
local SERVER_TOOLS_ORDER = { "web_search", "web_fetch" }
local DEFAULT_MAX_USES = 5

-- Build one server-tool entry, stamping `max_uses` from config when available (else a safe default,
-- so the web tools work even if a caller doesn't pass config).
local function serverToolEntry(name: string, config: any): any
	local maxUses = DEFAULT_MAX_USES
	if config ~= nil then
		if name == "web_search" then
			maxUses = config:getWebSearchMaxUses()
		elseif name == "web_fetch" then
			maxUses = config:getWebFetchMaxUses()
		end
	end
	return { type = SERVER_TOOL_TYPES[name], name = name, max_uses = maxUses }
end
```

- [ ] **Step 4: Rewrite `Tools.schemas` to take config and append the server tools**

In `src/Tools/init.luau`, replace the whole `Tools.schemas` function:

```lua
-- The Anthropic `tools` payload: one {name, description, input_schema} per registered tool.
function Tools.schemas(): { any }
	local out: { any } = {}
	for _, descriptor in registry do
		table.insert(out, {
			name = descriptor.name,
			description = descriptor.description,
			input_schema = descriptor.inputSchema,
		})
	end
	return out
end
```

with:

```lua
-- The Anthropic `tools` payload: one {name, description, input_schema} per registered custom tool,
-- followed by the server-side web tools (stamped with max_uses from `config` when provided).
function Tools.schemas(config: any?): { any }
	local out: { any } = {}
	for _, descriptor in registry do
		table.insert(out, {
			name = descriptor.name,
			description = descriptor.description,
			input_schema = descriptor.inputSchema,
		})
	end
	for _, name in SERVER_TOOLS_ORDER do
		table.insert(out, serverToolEntry(name, config))
	end
	return out
end
```

- [ ] **Step 5: Rewrite `Tools.schemasFor` to take config and append requested server tools**

In `src/Tools/init.luau`, replace the whole `Tools.schemasFor` function:

```lua
-- Like schemas(), but filtered to a named subset (used to give a subagent a read-only toolset).
function Tools.schemasFor(names: { string }): { any }
	local want: { [string]: boolean } = {}
	for _, n in names do
		want[n] = true
	end
	local out: { any } = {}
	for _, descriptor in registry do
		if want[descriptor.name] then
			table.insert(out, {
				name = descriptor.name,
				description = descriptor.description,
				input_schema = descriptor.inputSchema,
			})
		end
	end
	return out
end
```

with:

```lua
-- Like schemas(), but filtered to a named subset (used to give a subagent a read-only toolset). A
-- requested name that is a SERVER tool (web_search/web_fetch) is emitted as its server-tool entry.
function Tools.schemasFor(names: { string }, config: any?): { any }
	local want: { [string]: boolean } = {}
	for _, n in names do
		want[n] = true
	end
	local out: { any } = {}
	for _, descriptor in registry do
		if want[descriptor.name] then
			table.insert(out, {
				name = descriptor.name,
				description = descriptor.description,
				input_schema = descriptor.inputSchema,
			})
		end
	end
	for _, name in SERVER_TOOLS_ORDER do
		if want[name] then
			table.insert(out, serverToolEntry(name, config))
		end
	end
	return out
end
```

- [ ] **Step 6: Update the header comment**

In `src/Tools/init.luau`, find the comment line (~line 11-13) listing the final registry, which currently ends:

```lua
-- create_instance, capture, web_fetch, web_search, dispatch_subagents, update_tasks, remember, forget,
-- dispatch_writers.
```

Replace those two lines with:

```lua
-- create_instance, capture, dispatch_subagents, update_tasks, remember, forget, dispatch_writers.
-- web_fetch/web_search are NOT custom tools — they are Anthropic SERVER-side tools appended by
-- schemas()/schemasFor() (executed by the API, never dispatched locally; see SERVER_TOOL_TYPES below).
```

- [ ] **Step 7: Format, lint, compile**

Run: `stylua src; stylua --check src; selene src; rojo build default.project.json -o StudioAgent.rbxm`
Expected: stylua clean; selene `0 errors` (+ known warning); rojo writes the file. Callers still use `Tools.schemas()` / `Tools.schemasFor(names)` (config defaults to nil → `DEFAULT_MAX_USES`), so they remain valid.

- [ ] **Step 8: Commit**

```bash
git add src/Tools/init.luau
git commit -m "tools: drop client-side web descriptors; append direct server-side web tools in schemas/schemasFor"
```

---

### Task 3: Delete the client-side web modules

**Files:**
- Delete: `src/Tools/Web.luau`
- Delete: `src/WebSpec.luau`

- [ ] **Step 1: Confirm nothing else references them**

Run: `selene --version` is irrelevant; instead grep the source:
`Select-String -Path src\*.luau,src\**\*.luau -Pattern "WebSpec|script\.Web\b|Tools\.Web\b"`
Expected matches ONLY inside `src/WebSpec.luau` and `src/Tools/Web.luau` themselves (which we delete). `src/Tools/init.luau` should no longer match (Task 2 removed its `require(script.Web)`). If anything ELSE matches, stop and fix that reference first.

- [ ] **Step 2: Delete the files**

```bash
git rm src/Tools/Web.luau src/WebSpec.luau
```

- [ ] **Step 3: Compile to prove no dangling requires**

Run: `rojo build default.project.json -o StudioAgent.rbxm`
Expected: writes `StudioAgent.rbxm` with no error (a dangling `require(script.Web)` would fail here). Then `selene src` → `0 errors`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "tools: delete client-side Tools/Web.luau + WebSpec.luau (replaced by server-side web tools)"
```

---

### Task 4: AgentLoop — pass config to schemas + surface server_tool_use status

**Files:**
- Modify: `src/AgentLoop.luau` (tools build ~line 90; content-block walk ~line 171-180)

- [ ] **Step 1: Pass config when building the tools list**

In `src/AgentLoop.luau`, replace (~line 90):

```lua
	local tools = Tools.schemas()
```

with:

```lua
	local tools = Tools.schemas(config)
```

- [ ] **Step 2: Surface server-tool progress in the content walk**

In `src/AgentLoop.luau`, find the content-block loop (~line 171-180):

```lua
			for _, block in ipairs(data.content) do
				if type(block) == "table" then
					if block.type == "text" and type(block.text) == "string" then
						emit("assistant_text", block.text)
					elseif block.type == "tool_use" then
						table.insert(toolUses, block)
					end
				end
			end
```

Replace it with (adds ONE `elseif` branch — do not change the existing two):

```lua
			for _, block in ipairs(data.content) do
				if type(block) == "table" then
					if block.type == "text" and type(block.text) == "string" then
						emit("assistant_text", block.text)
					elseif block.type == "tool_use" then
						table.insert(toolUses, block)
					elseif block.type == "server_tool_use" then
						-- Anthropic runs this server-side (web_search/web_fetch). It is NOT a local
						-- tool_use, so it is never dispatched, and the matching *_tool_result block
						-- already rides in this same assistant turn. Surface progress only.
						local inp = if type(block.input) == "table" then block.input else {}
						local detail = tostring(inp.query or inp.url or "")
						emit(
							"status",
							tostring(block.name) .. (if detail ~= "" then " " .. detail else "")
						)
					end
				end
			end
```

- [ ] **Step 3: Format, lint, compile**

Run: `stylua src; stylua --check src; selene src; rojo build default.project.json -o StudioAgent.rbxm`
Expected: stylua clean; selene `0 errors` (+ known warning); rojo writes the file.

- [ ] **Step 4: Commit**

```bash
git add src/AgentLoop.luau
git commit -m "agentloop: declare server web tools (config) + emit status for server_tool_use blocks"
```

---

### Task 5: Wire config into the subagent + writer schema builders

So a read-only subagent's allowlisted `web_search`/`web_fetch` are emitted as server-tool entries (with `max_uses`), giving children real web access; the writer call just updates the signature (no web tools in its set).

**Files:**
- Modify: `src/Tools/Subagents.luau` (~line 62)
- Modify: `src/Tools/Writers.luau` (~line 74)

- [ ] **Step 1: Pass config in Subagents**

In `src/Tools/Subagents.luau`, replace (~line 62):

```lua
	local toolSchemas = (Tools :: any).schemasFor(READ_ONLY)
```

with:

```lua
	local toolSchemas = (Tools :: any).schemasFor(READ_ONLY, config)
```

(`config` is already in scope here — resolved at the top of `runDispatch`.)

- [ ] **Step 2: Pass config in Writers**

In `src/Tools/Writers.luau`, replace (~line 74):

```lua
	local toolSchemas = (Tools :: any).schemasFor(WRITE_TOOLS)
```

with:

```lua
	local toolSchemas = (Tools :: any).schemasFor(WRITE_TOOLS, config)
```

(`config` is already in scope here too. `WRITE_TOOLS` has no web tools, so no server tools are appended — this is just a signature update for consistency.)

- [ ] **Step 3: Format, lint, compile**

Run: `stylua src; stylua --check src; selene src; rojo build default.project.json -o StudioAgent.rbxm`
Expected: stylua clean; selene `0 errors` (+ known warning); rojo writes the file.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Subagents.luau src/Tools/Writers.luau
git commit -m "subagents/writers: thread config into schemasFor (server web tools for read-only children)"
```

---

### Task 6: SystemPrompt — rewrite the web-access guidance (parent + subagent)

**Files:**
- Modify: `src/SystemPrompt.luau` (tool-list line ~line 22; "# Web access and APIs" section ~line 52-56; `SUBAGENT_BASE` web line ~line 106)

- [ ] **Step 1: Update the parent tool-list line**

In `src/SystemPrompt.luau`, replace (~line 22):

```lua
- web_fetch(url) / web_search(query): read a web page as text / search the web to look things up (NOT roblox.com — HttpService blocks those domains; see "Web access and APIs").
```

with:

```lua
- web_fetch(url) / web_search(query): read any web page as text / search the web — these run on ANTHROPIC'S servers, so they reach the WHOLE web INCLUDING roblox.com (see "Web access and APIs").
```

- [ ] **Step 2: Rewrite the "# Web access and APIs" section**

In `src/SystemPrompt.luau`, replace the whole section (~line 52-56):

```lua
# Web access and APIs
You have web_fetch and web_search. IMPORTANT: Roblox's HttpService BLOCKS roblox.com domains, so these CANNOT reach create.roblox.com or devforum.roblox.com — don't try (you'll get "not allowed to access that Roblox resource"). They DO work for the rest of the web:
- web_fetch(url): read any non-roblox.com page as text (HTML is stripped; large pages are truncated). Useful sources: the open-source Roblox docs on GitHub (e.g. https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/... ), MDN, Stack Overflow, and general references.
- web_search("query"): find pages/solutions, then web_fetch a result's URL to read it. Best-effort — if blocked it returns a note.
For Roblox engine APIs you already know well, rely on your KNOWLEDGE first; reach for the web for things outside your training, exact current signatures, or non-Roblox references — prefer that over guessing.
```

with:

```lua
# Web access and APIs
You have web_fetch and web_search, and they run on ANTHROPIC'S SERVERS (not your Studio HttpService) — so they reach the entire web, INCLUDING roblox.com. Use them to look things up instead of guessing.
- web_fetch(url): read any page as text — including create.roblox.com docs and devforum.roblox.com threads. CAVEAT: the Roblox docs site renders its body with JavaScript, so fetching a create.roblox.com/docs/... page returns mostly page metadata. For the FULL text of a docs page, fetch the GitHub mirror instead: https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/... (or the docs index at https://create.roblox.com/docs/reference/engine/llms.txt). web_fetch works great for the dev forum, MDN, Stack Overflow, GitHub, and general pages.
- web_search("query"): search the open web (incl. Roblox sources), then web_fetch a result's URL to read it.
For Roblox engine APIs you already know well, rely on your KNOWLEDGE first; reach for the web for things outside your training, exact current signatures, or non-Roblox references — prefer that over guessing.
```

- [ ] **Step 3: Update the SUBAGENT_BASE web line**

In `src/SystemPrompt.luau`, replace (~line 106):

```lua
- web_fetch(url) / web_search(query): read a web page as text / search the web (NOT roblox.com — HttpService blocks those domains; use GitHub, MDN, forums, etc.).
```

with:

```lua
- web_fetch(url) / web_search(query): read any web page as text / search the web — these run on Anthropic's servers, so they reach the WHOLE web including roblox.com (create.roblox.com docs render via JS, so a raw fetch returns mostly metadata; for full doc bodies fetch the GitHub mirror https://raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/...).
```

- [ ] **Step 4: Format, lint, compile**

Run: `stylua src; stylua --check src; selene src; rojo build default.project.json -o StudioAgent.rbxm`
Expected: stylua clean; selene `0 errors` (+ known warning); rojo writes the file.

- [ ] **Step 5: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "systemprompt: web tools now server-side (roblox.com reachable); JS-SPA caveat + GitHub mirror"
```

---

### Task 7: Build, adversarial review, live-verify

**Files:** none new — verification + review of the full diff.

- [ ] **Step 1: Full static gate**

Run: `stylua --check src; selene src; .\build.ps1`
Expected: stylua clean; selene `Results: 0 errors` (+ the 1 known `CreateDockWidgetPluginGui` warning); `build.ps1` prints `Installed -> ...StudioAgent.rbxm`. (Close Studio first if the copy fails on a file lock.)

- [ ] **Step 2: Confirm no dead references remain**

Run: `Select-String -Path src\*.luau,src\**\*.luau -Pattern "webFetchMaxChars|webSearchMaxResults|getWebFetchMaxChars|getWebSearchMaxResults|script\.Web\b|WebSpec"`
Expected: **no matches** anywhere in `src/`.

- [ ] **Step 3: Adversarial review (Workflow)**

ultracode is on — run a `Workflow` adversarial review over the diff (the pattern used for prior features). Focus dimensions:
1. **Tools-array assembly** — server entries present with `max_uses`; no client `web_*` custom tools left; no duplicate tool names; deterministic order preserved.
2. **AgentLoop pass-through invariant** — `server_tool_use` is never collected into `toolUses`/dispatched; assistant content is echoed verbatim; `pause_turn` still resumes; the new `status` emit can't throw or alter history.
3. **`isValidHistory`** — an assistant turn carrying `server_tool_use` + `*_tool_result` is accepted (no `tool_use`→`tool_result` rule trip; alternation intact).
4. **Subagent/writer wiring** — read-only children get the server web entries; writers unaffected; `SubagentsSpec`/`WritersSpec` counts unchanged (web-free local lists).
5. **Config** — old keys fully removed (defaults, validation, getters), new keys validated; no remaining caller of the removed getters.
Extract findings from the returned schema; fix confirmed issues inline (re-run the static gate after fixes); rebuild.

- [ ] **Step 4: Live-verify in Studio (hand off to the user / drive via computer-use)**

Restart the hecate tunnel (`proxy\tunnel.ps1`) so the production path is exercised, open a **NEW Baseplate** (not a saved place — see the test-session memory), and confirm:
1. `web_search` a current-info query → the agent cites a result (panel shows a `web_search …` status line).
2. `web_fetch https://create.roblox.com/docs/reference/engine/classes/Humanoid` → returns at least the page metadata (proves roblox.com is reachable; the old block is gone).
3. `web_fetch` the GitHub mirror of the same doc (`raw.githubusercontent.com/Roblox/creator-docs/main/content/en-us/reference/engine/classes/Humanoid.yaml` or `.md`) → returns the full doc body.
4. `web_fetch` a `devforum.roblox.com` thread URL → returns content (the dev forum is reachable).
5. A `dispatch_subagents` research fan-out uses web search inside the children and the parent synthesizes.
Report results; if anything regresses, capture the panel output and iterate.

- [ ] **Step 5: Final commit / handoff**

```bash
git add -A
git commit -m "web: server-side web tools live-verified (roblox.com reachable); update HANDOFF"
```

Update `HANDOFF.md` (mark the server-side web tools feature done + the proof) and the `studio-agent-status` memory, then proceed to the **SKILLS** plan with `research-a-topic` written against this real web access.

---

## Self-Review

**Spec coverage:** Every spec section maps to a task — direct tool versions + `SERVER_TOOL_TYPES` (Task 2); replace-and-delete client-side (Tasks 2-3); pass-through / `server_tool_use` ignore + `pause_turn` (Task 4, verified, no code needed beyond the status emit); subagent wiring (Task 5); SystemPrompt rewrite incl. JS-SPA caveat (Task 6); Config `max_uses` swap (Task 1); static gate + adversarial review + live-verify incl. devforum + GitHub mirror (Task 7). The spec's optional "how to thread `max_uses`" is pinned: optional `config?` on `schemas`/`schemasFor` with a `DEFAULT_MAX_USES` fallback (Task 2), so every intermediate commit stays valid.

**Placeholder scan:** No TBDs; every code step shows the exact before/after text and every command its expected output.

**Type/name consistency:** `serverToolEntry(name, config)`, `SERVER_TOOL_TYPES`, `SERVER_TOOLS_ORDER`, `DEFAULT_MAX_USES`, `getWebSearchMaxUses`/`getWebFetchMaxUses` are defined once (Tasks 1-2) and referenced consistently (Tasks 2, 4, 5). `Tools.schemas(config?)` / `Tools.schemasFor(names, config?)` signatures match all call sites updated in Tasks 4-5; pre-update callers stay valid via the optional param.

**Test impact (caught during planning, not in the spec):** `SubagentsSpec`/`WritersSpec` use web-free local tool lists, so the server-tool append leaves their counts unchanged — no test edits needed; only `WebSpec.luau` is deleted (Task 3).
