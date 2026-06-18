# Session Handoff — 2026-06-18 (continuation)

**For a fresh context window.** Read `HANDOFF.md` (repo root) first for the overall project + module
map; this file captures everything from the 2026-06-18 session that HANDOFF.md doesn't already cover.
Memories are updated too (`studio-agent-status`, `roblox-plugin-native-screenshot-infeasible`,
`studio-agent-admin-dashboard-vision`, `studio-agent-model-connection`).

## TL;DR
Two roadmap items SHIPPED + live-verified (the **CreateDockWidgetPluginGui deprecation** and the
**client-view server RELAY**). Then a long, now-CONCLUDED investigation into **native screenshots**
(replacing the Python vision sidecar): it's **impossible from a plugin today** — every byte/path route
is walled off — but camera control works and there's a clean recommended design. Two **agent-quality
gaps** surfaced from real use and are not yet built. The **Admin Dashboard** is the next big product
direction.

---

## 1. SHIPPED this session (committed on `master`, working tree clean)

- **`CreateDockWidgetPluginGui` → `CreateDockWidgetPluginGuiAsync`** (commit `a389b53`). Resolves
  selene's last warning → **selene is now 0 errors / 0 warnings**. Same args; the Async variant yields
  (fine at plugin top level). Verified vs the create.roblox.com Plugin reference.
- **Client-view server RELAY** — the agent now works in the Play **client** view with no manual
  Server-view switch. Spec `docs/superpowers/specs/2026-06-18-studio-agent-client-relay-design.md`,
  plan `docs/superpowers/plans/2026-06-18-client-relay.md`. Commits: `92dc0ad` (Relay module +
  AgentLoop/Widget/init wiring), `e67755b` (review LOW fix — surface real relay errors), `b42dc0f`
  (HANDOFF update). Spike harness committed at `spike/relay-spike.server.luau` (`138ab71`).
  - **Foundation (live-verified via a throwaway spike):** Accurate Play Solo runs SEPARATE per-context
    plugin copies. A SERVER copy exists with working in-session HttpService + `Instance.new` builds; the
    CLIENT-copy plugin CAN call a server-made `RemoteFunction:InvokeServer` and get the return; the
    server copy stays alive across the view switch; settings bridge bidirectionally; play creates leave
    0 edit-DM artifacts.
  - **Design (`src/Relay.luau`):** loop + plugin-only state stay in the CLIENT copy; only the Anthropic
    HTTP send (`Relay.wrapAnthropic`) and DataModel/HTTP/loop-spawning tool dispatches relay to a
    server-copy `RemoteFunction` ("StudioAgentRelay"). Plugin-only tools (update_tasks/remember/forget/
    skills) run LOCAL. `init.server.luau` wires per copy from `Relay.mode()`. All nil-safe → edit /
    Server-view unchanged. Plugin-only + ephemeral ⇒ can't leak to production. Falls back to the
    Server-view dropdown if the RF isn't found.
  - **Verified:** adversarial review ship-as-is (0 HIGH/MED, 1 LOW fixed); `RelaySpec` 15/15; live in
    client view — PONG (HTTP relay), a part built in the running game (tool relay), update_tasks local,
    0 leak after Stop. **The user then USED the relay in production** (built obbys/lava via the agent in
    client-view playtest — see §3).

## 2. Native screenshot / capture investigation — CONCLUDED: not possible from a plugin

Goal: drop the Python vision sidecar (`sidecar/`, 127.0.0.1:8389) the `capture` tool depends on. The
user dislikes it (extra process + manual token) and, more importantly, it grabs the whole **Studio
window** not the rendered **viewport**, and can't follow a camera — but the user wants programmatic
**viewport** captures with **camera manipulation** for camera-rig dev / animation / playtest.

**The transport was a red herring I got wrong first:** Anthropic reads images by URL
(`image` block `source:{type:"url"}`) AND base64 — server-side — so the plugin never needs to produce
base64 pixels. The real blocker is **acquire**: getting a viewport image's *encoded bytes* (or a
fetchable URL) out of the engine. That is walled off. **Every route tested LIVE in Studio and closed:**

| Route | Result (empirical) |
|---|---|
| `CaptureService:CaptureScreenshot` | **WORKS in edit AND playtest-client** → returns `rbxtemp://N` (a local temp id) |
| `CreateEditableImageAsync(rbxtemp)` | rejected: "cannot currently create editable image from temporary texture id" — in **both** client and server |
| `EditableImage:ReadPixelsBuffer` | even if it worked → raw RGBA; Anthropic needs ENCODED png/jpeg, not pixels |
| `File:GetBinaryContents()` | `File` is NotCreatable / import-only (`StudioService:PromptImportFile*`); no capture→File path |
| `Capture.FilePathString` (the disk path) | `RobloxScriptSecurity` — a plugin can't read it |
| `CaptureService:GetCaptureFilePathAsync` | exists, but errors **"lacking capability RobloxScript"** when called from a plugin/command bar |
| publish→`thumbnails.roblox.com` CDN URL | gated (`UploadCaptureAsync` maturity prompt + quota), ~420px (too low-res), publishes the user's project PUBLICLY, relies on a staff-acknowledged moderation gap they intend to close |

So a plugin can get **neither the capture's bytes nor its disk path**. Bytes-out **requires an external
helper that does its OWN OS capture** (Roblox won't release the one it took). This matches the user's
own DevForum feature request (Yourfavoritecoach) asking Roblox to add a base64 option / new method /
expose the screenshot button — until they lift the `RobloxScript` gate (note the error says
"cannot *currently*"), this is the ceiling. (Also: an AI-pasted `plugin:TakeScreenshot()` claim was
verified FABRICATED — no such method on the Plugin class.)

**Camera control DOES work** (the genuinely useful finding): a plugin sets
`Workspace.CurrentCamera.CameraType=Scriptable` + `.CFrame`/`.FieldOfView` **directly in edit** (no
playtest, no LocalScript), or via an injected LocalScript in playtest (PostSimulation set → capture →
PreAnimation restore). The viewport re-renders to that angle.

**Recommended design (NOT yet built — awaiting the user's go from §6):** *plugin moves the camera →
a thin sidecar OS-captures just the **viewport region** (cropped, not the whole Studio window) → base64
→ Claude.* This gives viewport-accurate framing + camera sweeps for rig/animation/playtest, and turns
the sidecar from a fragile whole-window grabber into a region-reader. **Edit mode is the cleanest
context** for it (capture-trigger works, camera set is direct, HttpService works directly so the sidecar
is reachable with no relay). Full detail: memory `roblox-plugin-native-screenshot-infeasible`.

## 3. Agent-quality gaps found in real use (from the user's pasted transcript) — NOT yet built

The user drove the relay-enabled agent live (spawn-a-ball, obbys, a lava-kill course). It worked but
exposed two concrete, fixable problems — these are the highest-value next code changes:
1. **No `destroy_instance` tool.** With `run_luau` disabled in playtest, the agent could not delete
   instances — it flailed (reparenting old builds into ServerStorage as a delete workaround). Fix: a
   `destroy_instance` tool calling `Instance:Destroy()` — works server-side with no loadstring, in edit
   AND playtest. Clean fix for the exact wall it hit. (Current tools: no destroy — only
   create_instance/set_property.)
2. **Unreliable spatial placement.** Asked to place a ball "in front of the player," the agent inverted
   the `LookVector` sign three times (placed it behind, flipped, etc.). Fix: a placement helper
   ("N studs in front of this part's CFrame") + tighter system-prompt guidance so it stops hand-deriving
   facing math.

(Also noted: instances/scripts created mid-playtest don't run until the next Play — an engine rule the
agent already explains; not a bug to fix.)

## 4. Admin Dashboard — the next big product direction (memory: `studio-agent-admin-dashboard-vision`)

Talk to Claude in a LIVE game for anti-cheat / hacker detection / custom commands (a natural-language
dev commandline). SEPARATE product from the Studio plugin, but the relay validates its exact
client→server-agent pattern. Differs from the plugin: runs as in-game Scripts (not a plugin, game
security not PluginSecurity), needs a hosted Claude endpoint (not the personal SSH tunnel), admin-only
auth + prompt-injection hardening (player data is untrusted), and an anti-cheat tool surface. Its own
brainstorm→spec→plan when the user is ready.

## 5. Current state

- **Repo:** clean working tree, all on `master` (latest relevant: `b42dc0f`). selene 0/0, stylua clean,
  `rojo build` OK. Installed build has the relay (no temp spec runner).
- **Studio:** OPEN on a throwaway Baseplate (Place1, edit mode). Used for the relay live-test + the
  capture spikes. The relay/capture spike snippets were run via the command bar (nothing persisted to
  the place). Window-focus note: the desktop wallpaper widget keeps stealing focus — re-foreground
  Studio via Win32 `ShowWindow(h,3)+SetForegroundWindow(h)` before computer-use clicks (AppActivate is
  unreliable; `open_application` hits a stale version path — launch the exe directly:
  `C:\Users\manso\AppData\Local\Roblox\Versions\version-3da9d00a092c4d59\RobloxStudioBeta.exe`).
- **Infra:** hecate SSH tunnel (`proxy\tunnel.ps1`, 127.0.0.1:8318) was started this session — restart
  if down. Vision sidecar (`sidecar/run.ps1`, 127.0.0.1:8389) was NOT running during the capture spikes.

## 6. Decisions awaiting the user / next steps (pick up here)

1. **Capture:** native is impossible; the recommended path is the **camera-driven viewport-crop
   capture** (plugin sets camera → sidecar reads the viewport region). Build it (edit-mode first, the
   cleanest case)? Or keep the current sidecar and revisit if Roblox ships native support? *(The earlier
   "make the sidecar zero-friction: auto-token + bundle" idea is still on the table but was dismissed
   once.)*
2. **Agent quality:** build the `destroy_instance` tool + the placement fix (§3) — likely the highest
   value-per-effort improvements available right now.
3. **Admin Dashboard:** start its brainstorm→spec→plan when ready (§4).

Follow the project flow for any build: brainstorming → spec in `docs/superpowers/specs/` → writing-plans
→ implement → adversarial-review Workflow → live-verify in Studio (NEW Baseplate). ultracode is on.
