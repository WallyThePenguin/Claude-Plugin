# Studio Agent — Skills Design

- **Date:** 2026-06-17
- **Status:** Approved design (calls delegated to the implementer) — pending spec self-review, then
  implementation plan.
- **Relates to:** `HANDOFF.md`; the capability-parity roadmap. This is the LAST parity feature, after
  vision, compaction, subagents, web access, task tracking, cross-session memory, and parallel writers.
- **Scope:** ONE feature — reusable, named build "recipes"/skills the in-Studio agent can invoke,
  mirroring the orchestrator's skills, scoped to Roblox.

## Goal

Give the in-Studio agent **skills**: named, reusable recipes it can invoke to do common Roblox work
well, mirroring how the orchestrator (Claude Code) uses skills. A skill is *instructions/knowledge*,
not a separate execution engine — invoking one returns a recipe the agent then **follows with its
existing tools** (`create_instance`/`set_property`/`run_luau`/`dispatch_writers`/`capture`/…). This is
the same progressive-disclosure model the orchestrator uses: a cheap always-on catalog (name +
one-line description), with the full body loaded on demand.

Skills come from three places, all unified behind one catalog + one `use_skill` tool + one store:

- **Build recipes** (built-in, Roblox-specific): "scaffold an R15 NPC", "make a shop GUI", "set up
  leaderstats", etc. — curated, version-controlled expertise.
- **Working skills** (built-in, ported + Studio-adapted from Claude's skill library): "brainstorm a
  build", "plan a build", "test-first", "debug systematically", "review my build", "GUI design
  quality", "create a skill". These teach the agent *how to approach a task* — the reasoning
  discipline of the orchestrator's process skills, with tool references rewritten to the Studio
  toolset.
- **Your skills** (self-authored): recipes the agent saves on the user's behalf (`save_skill`) that
  persist across sessions like memory, so the studio can encode "build it MY way" conventions. The
  `create-skill` working skill is the guided flow for brainstorming and authoring these.

This completes the "full peer" vision: durable *facts* (memory) + durable *procedures* (skills) +
the ability to *learn a new procedure* with the user (`create-skill`).

## Key decisions (settled in brainstorming; design calls delegated to the implementer)

1. **A skill is recipe text the agent executes — `use_skill` does not build.** `use_skill(name, args?)`
   returns the recipe body (parameters resolved) as a `tool_result`; the agent then builds with its
   normal tools. This is what makes skills compose with *every* existing tool (incl. `dispatch_writers`
   and `update_tasks`), work during a playtest, and avoid a parallel build engine. Rejected: injecting
   all bodies always (defeats progressive disclosure, won't scale) and a "use_skill builds it for you"
   tool (a second engine that wouldn't compose with writers/playtest).
2. **Discovery = an always-on catalog, injected via the leading preamble — not a search tool.**
   `SkillStore.catalogBlock()` renders `name — description` lines (grouped by family) and is folded
   into the per-Send `instructions` preamble alongside `SystemPrompt` + memory. **Critical:** the
   CLIProxyAPI subscription path strips the client `system` field, so the catalog rides the LEADING
   MESSAGE preamble (`MessageUtil.withSystemPreamble`), never `system` — same delivery as memory.
3. **Built-in skills are bundled at build time (curated port), in two families.** Build recipes are
   authored Roblox expertise; working skills are Studio-ADAPTED copies of the orchestrator's process
   skills (read from `~/.claude` during implementation; reasoning kept, tool references rewritten).
   Rejected for v1: a runtime "live import bridge" from `~/.claude` (needs a sidecar always running,
   and raw orchestrator skills reference tools the agent lacks → still need filtering/adaptation).
4. **Self-authored skills are global-only in v1** (one bucket, persisted via `plugin:SetSetting`,
   mirroring `Memory`). Skills are invoked *by name*, so two scopes would create invoke-time name
   ambiguity; a place-specific convention is already served by game-scoped *memory*. Game-scoped
   skills are a clean later extension.
5. **Built-in names are reserved.** `save_skill` rejects a name that collides with a built-in and
   *updates* an existing same-name user skill; `delete_skill` refuses to delete a built-in. The merged
   catalog (built-ins first, then user) therefore has unique names and `use_skill` is unambiguous.
6. **Three tools, all parent-only and non-destructive:** `use_skill`, `save_skill`, `delete_skill`.
   Not in the subagent/writer allowlists; a child's tool context carries no `skills` (nil-guarded →
   graceful no-op). Same isolation pattern as `update_tasks`/`remember`/`forget`. `destructive = false`
   for all three (they don't touch the DataModel; `save`/`delete` mutate the user's own skill store,
   like `remember`/`forget`). A parent that `use_skill`s a recipe can still partition it across
   `dispatch_writers` itself — that is the intended composition.
7. **Parameterization is declarative + template substitution.** A skill may declare `parameters`
   (`{ name, description, required? }`). `use_skill` validates required params are present (missing →
   an `is_error` listing them, before any build), substitutes `{{name}}` placeholders in the body, and
   appends a "Provided arguments" block so values are visible even if the body didn't template them.
8. **Skill writes are durable — NOT rolled back with the conversation.** Like memory, `save`/`delete`
   persist to `SetSetting` immediately and are not reverted on a non-clean turn exit; the catalog is
   rebuilt per Send (outside the message history), so compaction/rollback never touch it.
9. **A Skills viewer in the panel** (transparency + control): a toggle (like History/Memory) listing
   built-ins read-only (grouped: build recipes / working skills) and user skills each with a small `✕`
   to delete. Built-ins have no `✕`.

## The built-in skill set (v1)

### Build recipes (Roblox-specific)

| name | what it scaffolds | parameters |
|---|---|---|
| `leaderstats` | the standard `leaderstats` Folder + IntValue(s) created on `PlayerAdded` (Script in ServerScriptService) | `statNames?` |
| `shop-gui` | a shop `ScreenGui` (item grid via `UIGridLayout`, buy/close buttons, `UICorner`/padding) | `title?`, `itemCount?` |
| `r15-npc` | a basic R15 NPC Model (Humanoid + HumanoidRootPart + parts joined by Motor6Ds, positioned) | `name?`, `spawnPosition?` |
| `datastore-save` | a robust save/load scaffold (`GetAsync`/`SetAsync` wrapped in `pcall` + retry/backoff) | `storeName?` |
| `parallel-zones` | create N independent zone containers, then **dispatch_writers one writer per zone** (showcases skill → parallel-build composition) | `zones` |

### Working skills (Studio-adapted ports of Claude's process skills)

| name | ported from | Studio adaptation (reasoning kept; tool refs rewritten) |
|---|---|---|
| `brainstorm-a-build` | `brainstorming` | clarify intent → propose approaches → `update_tasks` plan → build (no spec-file-to-disk step) |
| `plan-a-build` | `writing-plans` / `executing-plans` | decompose a big build into independent regions/steps; mark what parallelizes (`dispatch_writers`); verify at checkpoints |
| `test-first` | `test-driven-development` | write a failing `RunService:Run()` self-test / assertion harness, then build until it passes (the project's existing Spec pattern) |
| `debug-systematically` | `systematic-debugging` | reproduce via `get_output`/`RunService:Run`, hypothesize, isolate, fix root cause, re-verify |
| `review-my-build` | `requesting`/`receiving-code-review` | fan out `dispatch_subagents` as adversarial reviewers (capture + inspect → pass/fail), then triage findings with rigor |
| `gui-design-quality` | `frontend-design` | UI hierarchy/spacing/alignment/color principles for ScreenGuis; `capture` to verify it actually looks good |
| `create-skill` | `skill-creator` / `writing-skills` | brainstorm a new custom Roblox skill WITH the user (interview: task, when-to-use/description, what varies/params, concrete steps), draft the body, show it, then `save_skill` it |
| `research-a-topic` *(provisional — confirm or drop at spec review)* | `deep-research` | fan out `dispatch_subagents` web searches, verify, synthesize — bounded by HttpService limits (no roblox.com, DDG-only search) |

`verification-before-completion` is intentionally **folded into the SystemPrompt's existing "Verify
your work — close the loop" section and `review-my-build`** rather than a standalone skill, to avoid
redundancy.

Recipe/skill **bodies** are authored during implementation (content work); this spec fixes the set,
the shapes, and the machinery.

## Non-goals (YAGNI)

- **No game-scope for user skills** in v1 (global-only; game-specific conventions live in game-scoped
  memory). Game-scope is a clean later extension.
- **No live import bridge** from `~/.claude` (curated port at build time; re-port to update).
- **No formal skill-calls-skill graph.** A recipe may *mention* another skill by name and the agent
  may `use_skill` it — emergent composition, not a call mechanism. No recursion guard needed (the agent
  decides; the catalog is bounded).
- No skill versioning, no per-skill enable/disable, no semantic search (always-on catalog with caps).
- No user-facing panel FORM to type a skill by hand. The agent authors on the user's behalf via
  `create-skill` + `save_skill` through conversation; the panel is a viewer + delete. (Matches how
  memory works: agent writes; panel views/deletes.)
- No config knobs for the caps (module constants; promotable to `Config` later).

## Architecture

### New modules

- **`src/SkillCatalog.luau`** — PURE helpers + constants (no `self`, no DataModel — directly
  unit-testable; the bulk of the logic, mirroring `Memory`'s pure layer).
  - Types: `Param = { name: string, description: string, required: boolean }`;
    `Skill = { name: string, description: string, body: string, parameters: { Param },
    category: "recipe" | "working", source: "builtin" | "user" }`.
  - **Constants:** `MAX_NAME = 48`, `MAX_DESC = 200`, `MAX_BODY = 6000`, `MAX_PARAMS = 8`,
    `MAX_PARAM_FIELD = 200`, `MAX_USER_SKILLS = 20`.
  - `normalizeName(name) -> string?` — trim, lowercase, replace runs of non-`[a-z0-9]` with `-`, strip
    leading/trailing `-`; `nil` if empty; truncate to `MAX_NAME`. ("Shop GUI" → "shop-gui".)
  - `normalizeParams(raw) -> { Param }` — defensive: drop non-tables / empty names; trim + truncate
    `name`/`description` to `MAX_PARAM_FIELD`; coerce `required` to boolean; cap to `MAX_PARAMS`.
  - `validateSkill(raw, source, category) -> (Skill?, err: string?)` — validate/normalize name,
    description (non-empty ≤ `MAX_DESC`), body (non-empty, UTF-8-safe truncate ≤ `MAX_BODY`), params;
    return a clean `Skill` or an error string.
  - `findByName(skills, name) -> Skill?` — exact match on the normalized name.
  - `renderSkill(skill, args) -> (text: string, err: string?)` — (1) required-param check (missing →
    err listing them); (2) substitute `{{paramName}}` in the body for each declared param present in
    `args` (string-coerced); (3) build `"# Skill: <name>\n<description>\n\n<body>\n\n## Provided
    arguments\n- <name>: <value|(not provided)>"`. Undeclared `{{x}}` left literal.
  - `catalogBlock(skills) -> string` — group by `category` + `source` into three headed sections
    (**Build recipes**, **Working skills (how to approach a task)**, **Your skills**); render
    `- <name> — <description>` lines under each non-empty section, with a one-line lead
    ("Invoke one with use_skill(name, args?) to load its recipe, then follow it."). `""` if no skills.
- **`src/BuiltinRecipes.luau`** — the 5 build-recipe definitions (pure data list; `category="recipe"`,
  `source="builtin"`).
- **`src/BuiltinWorkingSkills.luau`** — the working-skill definitions (pure data list;
  `category="working"`, `source="builtin"`), authored as Studio-adapted ports.
- **`src/SkillStore.luau`** — the live store + merge (instance over `plugin`; mirrors `Memory`). One
  instance in `deps.skills`.
  - `new(plugin) -> SkillStore` — holds `plugin` + the immutable built-in list (validated once from
    `BuiltinRecipes` ++ `BuiltinWorkingSkills`).
  - Key: `SETTING_PREFIX .. "skills_user"` (one global bucket). User record:
    `{ name, description, body, parameters, createdAt }`.
  - `loadUser() -> { Skill }` — read `SetSetting`; re-validate each via `validateSkill(_, "user",
    "recipe")`; dedup by name (keep first); cap to `MAX_USER_SKILLS` (keep newest). Defensive: a
    corrupt/old blob can never inject a malformed skill.
  - `all() -> { Skill }` — built-ins first, then user.
  - `save(name, description, body, parameters) -> (note: string, ok: boolean)` — validate; **reject**
    a built-in name collision; dedup against existing user (same name → replace); FIFO-drop the oldest
    if over the cap (reported); persist; return a note.
  - `delete(name) -> string` — normalize; **refuse** a built-in ("built-in skills can't be deleted");
    else remove from the user bucket, persist; note if not found.
  - `resolve(name, args) -> (text: string, ok: boolean)` — `findByName(all())`; unknown → an error
    string (`ok=false`); else `renderSkill` (missing required → `ok=false`).
  - `listBuiltins() / listUser() -> { Skill }` (for the viewer); `catalogBlock() -> string`
    (`SkillCatalog.catalogBlock(self:all())`).
- **`src/Tools/Skills.luau`** — exports `descriptors` with `use_skill`, `save_skill`, `delete_skill`
  (same Descriptor shape as `Memory`/`Tasks`). Each: nil `context.skills` → an `is_error` string
  (subagent); else delegate to the store; never throws.
- **`src/SkillCatalogSpec.luau`** — in-Studio self-test (mirrors `MemorySpec`) over the PURE
  `SkillCatalog` surface: `normalizeName` (spaces/case/invalid/empty/over-length), `normalizeParams`
  (drop-malformed/truncate/cap), `validateSkill` (good + each rejection), `renderSkill` (substitution,
  required-missing error, undeclared-placeholder left literal, provided-args block), `catalogBlock`
  (grouping + empty). `SetSetting` persistence, built-in-collision rejection, and built-in-delete
  refusal are instance concerns verified live in Studio.

### Touched modules

- **`src/Tools/init.luau`** — require `Skills`, append its descriptors (after `Writers`); update the
  registry comment.
- **`src/AgentLoop.luau`** — `runLoop`/`AgentLoop.send` gain a `skills` parameter (threaded after
  `memory`). `toolContext.skills = skills`. Fold the catalog into the existing `instructions` compose
  (after the base prompt and the memory block): `if skills ~= nil then local cat = skills:catalogBlock()
  if cat ~= "" then instructions ..= "\n\n" .. cat end end`. **No rollback handling** (durable, like
  memory).
- **`src/init.server.luau`** — require `SkillStore`; add `skills = SkillStore.new(plugin)` to `deps`.
- **`src/UI/Widget.luau`** — pass `deps.skills` to `agentLoop.send`; add a **Skills** toggle + viewer
  (reuse the `scroller()`/`showSessions`/Memory-view pattern): built-ins grouped read-only, user skills
  with a per-entry `✕` delete; refresh after a save/delete (optional loop `skills` event, else on next
  open).
- **`src/SystemPrompt.luau`** — a `# Skills` section in `BASE` + the three tool one-liners in the tools
  list. The SUBAGENT and WRITER prompts are unchanged (children have no skill tools).
- **`src/Config.luau`** — no new keys (caps are `SkillCatalog` constants).

### Data flow

```
model → use_skill { name="shop-gui", args={ title="Coins" } }
      → Tools.dispatch → Skills.run → context.skills:resolve("shop-gui", {title="Coins"})
          → findByName(all) → renderSkill (check required, substitute {{title}}, append args block)
          → recipe text  -- tool_result; the agent then BUILDS it with create_instance/etc.

model → save_skill { name, description, body, parameters }
      → context.skills:save(...) → validate → reject built-in collision → dedup/cap → SetSetting(skills_user)
      → note  -- tool_result; (optional) loop emits "skills" → Widget refreshes the viewer if open

Each Send:  runLoop folds skills:catalogBlock() into `instructions` (after SystemPrompt + memory),
            delivered via the LEADING preamble (the proxy strips `system`).

On Studio open / new place:  built-ins are constant; the user bucket is install-global (one key).
On a non-clean exit:  skills are NOT rolled back (durable; the catalog is rebuilt per send, outside history).
```

## UI

A **Skills** view toggled from the control row (alongside New chat / History / Memory), reusing the
existing scroller + show/hide pattern. Sections: **Build recipes** and **Working skills** (built-ins,
read-only — name + description), then **Your skills** (user — name + description + a small `✕` that
calls `skills:delete(name)` and refreshes). Empty user section shows "(none yet)". Like the History and
Memory views, it swaps with the transcript region (the task checklist hides while it is shown). It is
for transparency/control; the agent reads/writes skills through the tools and the always-on catalog.

## Correctness rules / edge cases

- **Total dispatch:** the three tools never throw; a nil `context.skills` (subagent) or malformed input
  returns an `is_error` string. (`Tools.dispatch` pcall-wraps as a backstop too.)
- **Empty-object encoding:** every skill tool carries a required field (`use_skill.name`,
  `save_skill.name/description/body`, `delete_skill.name`), so a tool_use input can never serialize to
  `[]` (the `JSONEncode({}) -> []` → 400 gotcha cannot fire).
- **UTF-8 truncation** on name/description/body/param fields (codepoint-boundary safe), so a stored or
  injected skill is never invalid UTF-8.
- **Defensive load:** a missing/old/corrupt user blob → entries that fail `validateSkill` are dropped;
  never injects a malformed skill into the catalog or viewer.
- **Built-in reservation:** `save_skill` rejects a built-in name collision and `delete_skill` refuses
  to delete a built-in → catalog names stay unique → `use_skill` is deterministic regardless of merge
  order.
- **Required-param safety:** `use_skill` returns an `is_error` listing missing required params BEFORE
  any build, so the agent supplies them (or asks the user) rather than building from a half-rendered
  recipe.
- **Catalog token cost is bounded:** `(5 + ~8 built-ins + ≤ MAX_USER_SKILLS=20) × (name + ≤MAX_DESC)` ≈
  a few KB worst case — comparable to memory; `lastPromptTokens` already counts preamble tokens, so the
  compactor threshold accounts for the catalog. (Bodies are NOT in the catalog — loaded only on
  `use_skill`.)
- **Children isolation:** the three tools are not in the subagent/writer allowlists, and a child's
  context carries no `skills`. A writer that "needs" a recipe gets the relevant steps inlined into its
  `task` by the parent (which `use_skill`s it first).
- **Compaction / rollback independence:** the catalog rides the preamble (outside `conversation.messages`)
  and user skills persist immediately, so no compaction or conversation-rollback path touches skills
  (same property as memory).

## System prompt addition (summary)

A `# Skills` section: an always-on catalog (under headed sections) lists named **build recipes** (how
to build common things well) and **working skills** (how to *approach* a task — brainstorming,
planning, test-first, debugging, reviewing, GUI quality, authoring a new skill). To use one, call
`use_skill(name, args?)` to load its recipe, then **follow it with your normal tools** — it returns
instructions, not a finished build, and may itself tell you to `dispatch_writers`/`update_tasks`/
`capture`. Reach for a build recipe when the task matches one; reach for a working skill to adopt a
disciplined approach. Use `save_skill` to capture a new reusable recipe (use the `create-skill` working
skill to author it well *with* the user), and `delete_skill` to drop one of your own (built-ins are
fixed). Plus the three tool one-liners in the tools list.

## Testing

- **Static:** `selene src` (0 errors; the 1 known `CreateDockWidgetPluginGui` warning), `stylua --check
  src`, `rojo build` — as every feature.
- **`SkillCatalogSpec`** (in-Studio): the pure `normalizeName`/`normalizeParams`/`validateSkill`/
  `renderSkill`/`catalogBlock` surface (the bulk of the logic, fully self-testable without a DataModel).
- **Adversarial review** (Workflow, like prior features) over the diff: focus on the AgentLoop
  `instructions` composition (no regression to send/retry/compaction/memory delivery), the
  validate/normalize/cap/dedup logic, the built-in-reservation invariants, `renderSkill` substitution +
  required-param handling, `SetSetting` persistence + defensive load, the subagent/writer isolation
  invariant, and the Widget Skills view.
- **Live-verify in Studio** (computer-use, NEW Baseplate): the catalog appears in a fresh chat; the
  agent `use_skill`s a built-in recipe (e.g. `leaderstats` or `shop-gui`) and actually builds it;
  `create-skill` brainstorms + `save_skill`s a custom recipe, a NEW chat shows it in the catalog and
  the agent reuses it; `delete_skill` drops it (and refuses a built-in); a `parallel-zones` run fans
  out `dispatch_writers`; the Skills viewer shows built-ins + user skills and `✕`-deletes a user one;
  confirm a turn that errors does NOT lose a just-saved skill.

## Rollout / ordering

1. `SkillCatalog.luau` + `SkillCatalogSpec.luau` (pure core, test-first).
2. `BuiltinRecipes.luau` + `BuiltinWorkingSkills.luau` (authored recipe/skill content; ports adapted
   from `~/.claude`).
3. `SkillStore.luau` (merge + persistence + resolve/save/delete).
4. `Tools/Skills.luau` (`use_skill`/`save_skill`/`delete_skill`) + register in `Tools/init.luau`.
5. `AgentLoop.luau` threading + `instructions` catalog fold.
6. `init.server.luau` deps.
7. `UI/Widget.luau` Skills view + wiring.
8. `SystemPrompt.luau` guidance (`# Skills` section + tool lines).
9. Build + lint, adversarial-review Workflow, fix, rebuild, hand off for live-verify.
