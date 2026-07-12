"""Studio Agent sidecar — localhost-only capture-file server + dev bridge.

GET  /captures?count=N&since=<epoch>[&b64=1]  -> {"images":[...],"returned":N,"shortfall":bool}
GET  /exemplars?category=<cat>[&b64=1]        -> {"exemplars":[...],"returned":N}
POST /agent      {"kind":"tool"|"luau"|"prompt", ...}     -> {"id":N}
GET  /agent/pending                                       -> the queued command (and clears it) or {}
POST /agent/result {"id":N, ...result}                    -> {"ok":true}
GET  /agent/result?id=N                                   -> the result, or {"status":"pending"}
POST /logs        {"lines":[...]}                          -> {"ok":true}
GET  /logs                                                 -> {"lines":[...]}
POST /reload                                              -> {"id":N}  (flags a hot-reload)
GET  /reload/pending                                      -> {"requested":bool,"id":N,"sources":{...}} | {"requested":true,"id":N,"error":str}
POST /reload/result {"id":N,"ok":bool,"error":?}          -> {"ok":true}
GET  /reload/result?id=N                                  -> the reload outcome, or {"status":"pending"}
POST /play {"cmd":...}                                    -> {"id":N}  (a playtest command)
GET  /play/pending                                        -> the queued play command (and clears it) or {}
POST /play/result {"id":N, ...}                           -> {"ok":true}
GET  /play/result?id=N                                    -> the play command result, or {"status":"pending"}
GET  /play/twins                                          -> {"session":N,"active":bool,"twins":[oracle-twin envelopes]} for the LATEST play session (+"dropped"/"skipped" when nonzero); sidecar-witnessed twin evidence
GET  /store/<kind>                                        -> {"items":[{"id","size","mtime"}]}
GET  /store/<kind>/<id>                                   -> the stored JSON body, or 404
POST /store/<kind>/<id>  <json body>                      -> {"ok":true}   (atomic write; git-tracked)
DELETE /store/<kind>/<id>                                 -> {"ok":true,"existed":bool}
GET  /runtime                                             -> {"version":N,"modules":{name:source}}  (runtime/ library)
GET  /references?query=<q>&count=N                        -> {"references":[{title,license,author,source,media_type,image(b64)}...]}
POST /loop {"prompt":str, "maxIterations"?:int}           -> {"id":N}  (sidecar-side agent loop; 409 if one is running)
GET  /loop/status                                         -> the current/last loop's status (+"bridgeStream":{"active":N,"total":N} SSE subscriber counters)
POST /factory {"rungId":str, "sabotage"?:bool, "supervised"?:bool, "stagingId"?:str} -> {"id":N}  (BUILD->GATE->VERIFY->STAGE; supervised admits proven=false; stagingId pins the staging entry + audit token; 409 if busy)
GET  /factory/status                                      -> the current/last factory run's status
POST /forever {"cycles"?:int, "families"?:[str]}          -> {"id":N}  (endless curriculum loop; 409 if busy)
POST /forever/stop                                        -> {"ok":true}  (graceful stop after the current cycle)
GET  /forever/status                                      -> the current/last forever run's status
GET  /docs/search?q=<q>&count=N                           -> {"results":[{path,line,snippet}...]}  (creator-docs grounding; shallow-clones on first use)
GET  /docs/apidiff                                        -> {"unknownClasses":[...],"dumpVersion":str}  (PropertyCatalog classes vs the live Studio API dump)
GET  /opencloud/asset-status?assetId=N                    -> {"assetId","state":"Approved|Reviewing|Rejected|Unknown|NotFound|Unavailable","raw",...}  (fetch-free moderation gate; 503 when Unavailable, e.g. no key file)
GET  /bridge/stream                                       -> SSE (text/event-stream): "event: command" nudges while a bridge command waits + 15s keepalives

Bind is 127.0.0.1 ONLY — the only trust boundary. No auth. Pure standard library.
"""

import base64
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import agent_loop
import capture
import exemplars
import factory as factory_mod
import forever as forever_mod
import game as gamesync
import sdk_loop
import store as filestore
from bridge import Store

PORT = int(os.environ.get("SIDECAR_PORT", "8389"))
STORE = Store()
# /bridge/stream subscriber counters (SP2e observability): active = currently-held SSE
# connections, total = lifetime connects. Surfaced additively on GET /loop/status.
_STREAM_LOCK = threading.Lock()
_STREAM_STATS = {"active": 0, "total": 0}
_BRIDGE = agent_loop.BridgeCaller(STORE)
LOOP = sdk_loop.select_loop_runner(_BRIDGE)  # STUDIO_AGENT_LOOP=sdk|legacy (default legacy)
_CURRICULUM = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "factory", "curriculum.json"
)
FACTORY = factory_mod.FactoryRunner(LOOP, _BRIDGE, _CURRICULUM, filestore.write_item)
FOREVER = forever_mod.ForeverRunner(
    FACTORY,
    LOOP,
    _CURRICULUM,
    lambda: filestore.list_items("staging"),
    # Live commentary into Studio's Output window (the user watches the loop think).
    narrate=lambda text, warn=False: _BRIDGE.call(
        {"kind": "narrate", "text": text, "warn": warn}, 15
    ),
)


# One mutex serializes the "is anyone busy? -> claim it" decision for ALL entry points that drive
# the single-slot bridge (/agent submit, /loop, /factory, /forever). ThreadingHTTPServer runs
# handlers concurrently, so the busy-check and the start() must be ATOMIC together — otherwise two
# simultaneous requests can both pass an advisory cross-check before either flips its state and the
# single bridge slot gets double-claimed.
_START_LOCK = threading.Lock()


def _agent_busy() -> bool:
    """The single-slot bridge/loop is in use by a loop, factory, or forever run — external /agent
    and orchestrator submissions must be fenced off so they can't clobber the in-flight command."""
    return (
        LOOP.status().get("state") == "running" or FACTORY.busy() or FOREVER.busy()
    )
SRC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")
RUNTIME_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "runtime")


def read_runtime() -> dict:
    """The git-versioned in-game runtime library: runtime/*.luau + VERSION. The plugin's
    RuntimeInstaller writes these as ReplicatedStorage.StudioAgentRuntime ModuleScripts."""
    with open(os.path.join(RUNTIME_DIR, "VERSION"), "r", encoding="utf-8") as fh:
        version = int(fh.read().strip())
    modules = {}
    for name in os.listdir(RUNTIME_DIR):
        if name.endswith(".luau"):
            with open(os.path.join(RUNTIME_DIR, name), "r", encoding="utf-8") as fh:
                modules[name[: -len(".luau")]] = fh.read()
    return {"version": version, "modules": modules}


def read_src_sources() -> dict:
    """Read every src/**/*.luau into {relativePosixPath: source}. Used by the hot-reload channel; the
    sidecar must be run from source (not the frozen exe) for src/ to resolve."""
    sources = {}
    for root, _dirs, files in os.walk(SRC_DIR):
        for name in files:
            if name.endswith(".luau"):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, SRC_DIR).replace(os.sep, "/")
                with open(full, "r", encoding="utf-8") as fh:
                    sources[rel] = fh.read()
    return sources


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, content_type: str, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj):
        self._send(code, "application/json", json.dumps(obj).encode())

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def do_GET(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path == "/captures":
            return self._captures(qs)
        if parsed.path == "/exemplars":
            return self._exemplars(qs)
        if parsed.path == "/agent/pending":
            return self._json(200, STORE.take_pending() or {})
        if parsed.path == "/bridge/stream":
            return self._bridge_stream()
        if parsed.path == "/agent/result":
            try:
                cid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            result = STORE.get_result(cid)
            return self._json(200, result if result is not None else {"status": "pending"})
        if parsed.path == "/logs":
            return self._json(200, {"lines": STORE.get_logs()})
        if parsed.path == "/reload/pending":
            r = STORE.take_reload()
            if r is None:
                return self._json(200, {"requested": False})
            try:
                sources = read_src_sources()
            except Exception as exc:  # noqa: BLE001
                return self._json(200, {"requested": True, "id": r["id"], "error": str(exc)})
            return self._json(200, {"requested": True, "id": r["id"], "sources": sources})
        if parsed.path == "/reload/result":
            try:
                rid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            res = STORE.get_reload_result(rid)
            return self._json(200, res if res is not None else {"status": "pending"})
        if parsed.path == "/play/pending":
            return self._json(200, STORE.play_take_pending() or {})
        if parsed.path == "/play/result":
            try:
                cid = int(qs.get("id", ["0"])[0])
            except ValueError:
                return self._json(400, {"error": "bad id"})
            res = STORE.play_get_result(cid)
            return self._json(200, res if res is not None else {"status": "pending"})
        if parsed.path == "/play/twins":
            return self._json(200, STORE.play_twins())
        if parsed.path.startswith("/store/"):
            return self._store_get(parsed.path)
        if parsed.path == "/runtime":
            try:
                return self._json(200, read_runtime())
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
        if parsed.path == "/game/read":
            try:
                return self._json(200, gamesync.read_game())
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
        if parsed.path == "/assets/mesh":
            try:
                import meshio

                textured = qs.get("textured", ["0"])[0] not in ("0", "", "false", "no")
                return self._json(
                    200, meshio.read_reference_mesh(qs.get("file", [""])[0], textured=textured)
                )
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/assets/texture":
            # Raw RGBA bytes of a texture (decoded + downscaled) for the plugin to
            # buffer.fromstring() straight into EditableImage:WritePixelsBuffer. Binary, not JSON —
            # a 1024 atlas is 4MB and base64 in JSON would inflate it 33%. X-Size carries the served
            # WxH (post-downscale) so the plugin sizes the EditableImage without a second call.
            # Sources: a .glb (its FIRST embedded image — the TRELLIS atlas) or a bare .png/.jpg
            # (the Gemini-painted atlas) — same contract either way.
            try:
                import meshio

                fname = qs.get("file", [""])[0]
                lower = fname.lower() if isinstance(fname, str) else ""
                if (
                    not isinstance(fname, str)
                    or "/" in fname
                    or "\\" in fname
                    or ".." in fname
                    or not lower.endswith((".glb", ".png", ".jpg", ".jpeg"))
                ):
                    return self._json(400, {"error": "bad filename"})
                path = os.path.join(meshio.ASSET_DIR, fname)
                if not os.path.isfile(path):
                    return self._json(404, {"error": f"no such reference asset: {fname}"})
                try:
                    max_size = int(qs.get("max", ["1024"])[0])
                except ValueError:
                    max_size = 1024
                max_size = max(16, min(2048, max_size))
                if lower.endswith(".glb"):
                    tex = meshio.decode_atlas_rgba(path, max_size=max_size)
                else:
                    tex = meshio.decode_image_rgba(path, max_size=max_size)
                body = tex["rgba"]
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Size", f"{tex['width']},{tex['height']}")
                self.end_headers()
                self.wfile.write(body)
                return
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/animate/kimodo":
            # Kimodo SMPL-X motion .npz -> R15 Pose channels (direction-matching FK).
            try:
                import retarget

                fname = qs.get("file", [""])[0]
                if not fname:
                    return self._json(400, {"error": "file parameter required (.npz in assets/reference)"})
                try:
                    fps = int(qs.get("fps", ["30"])[0])
                except ValueError:
                    fps = 30
                fps = max(5, min(60, fps))
                return self._json(200, retarget.retarget_reference_kimodo(fname, fps=fps))
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/animate/retarget":
            # Library clip -> R15 Motor6D Transform channels (retarget.py world-delta math).
            # {clip, duration_s, fps, joints: {R15Joint: {times, rot quats}}} — Luau builds the
            # KeyframeSequence Poses via CFrame.new(0,0,0, qx,qy,qz,qw).
            try:
                import retarget

                fname = qs.get("file", ["UAL2_Standard.glb"])[0]
                clip = qs.get("clip", [""])[0]
                if not clip:
                    return self._json(400, {"error": "clip parameter required"})
                try:
                    fps = int(qs.get("fps", ["30"])[0])
                except ValueError:
                    fps = 30
                fps = max(5, min(60, fps))
                return self._json(200, retarget.retarget_reference_clip(fname, clip, fps=fps))
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/assets/uvmap":
            # The UV-island template PNG (render_uv_template) — the painter's canvas guide.
            try:
                import meshio

                fname = qs.get("file", [""])[0]
                if (
                    not isinstance(fname, str)
                    or "/" in fname
                    or "\\" in fname
                    or ".." in fname
                    or not fname.lower().endswith(".glb")
                ):
                    return self._json(400, {"error": "bad filename"})
                path = os.path.join(meshio.ASSET_DIR, fname)
                if not os.path.isfile(path):
                    return self._json(404, {"error": f"no such reference asset: {fname}"})
                try:
                    size = int(qs.get("size", ["1024"])[0])
                except ValueError:
                    size = 1024
                size = max(64, min(2048, size))
                body = meshio.render_uv_template(path, size=size)
                return self._send(200, "image/png", body)
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/references":
            try:
                import references

                query = qs.get("query", [""])[0]
                count = int(qs.get("count", ["4"])[0])
                return self._json(200, references.get_references(query, count))
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/docs/search":
            try:
                import docsindex

                query = qs.get("q", [""])[0]
                count = int(qs.get("count", ["5"])[0])
                return self._json(200, {"results": docsindex.search(query, count)})
            except Exception as exc:  # noqa: BLE001
                code = 400 if isinstance(exc, ValueError) else 500
                return self._json(code, {"error": str(exc)})
        if parsed.path == "/docs/apidiff":
            try:
                import docsindex

                return self._json(200, docsindex.api_diff())
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
        if parsed.path == "/opencloud/asset-status":
            try:
                import opencloud

                try:
                    asset_id = int(qs.get("assetId", [""])[0])
                except ValueError:
                    return self._json(400, {"error": "assetId must be an integer"})
                result = opencloud.get_asset_status(asset_id)
                return self._json(503 if result["state"] == "Unavailable" else 200, result)
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
        if parsed.path == "/loop/status":
            status = dict(LOOP.status())
            with _STREAM_LOCK:
                status["bridgeStream"] = dict(_STREAM_STATS)  # additive key: SSE subscribers
            return self._json(200, status)
        if parsed.path == "/factory/status":
            return self._json(200, FACTORY.status())
        if parsed.path == "/forever/status":
            return self._json(200, FOREVER.status())
        return self._json(404, {"error": "not found"})

    def _bridge_stream(self):
        """SSE push channel (SP2e prototype): nudge the plugin the moment a bridge command is
        queued so it can stop fast-polling /agent/pending. Events are contentless pings — the
        plugin still PULLS via /agent/pending (the single consumer), so a lost event costs
        latency, never a command. The 0.05s poll is sidecar-local (free); a waiting command is
        re-nudged every 0.5s until claimed (covers a nudge the plugin missed mid-command);
        keepalive comment every 15s. Holds one ThreadingHTTPServer thread per client."""
        # Subscriber observability (SP2e follow-up: corroboration previously needed netstat).
        with _STREAM_LOCK:
            _STREAM_STATS["active"] += 1
            _STREAM_STATS["total"] += 1
            print(f"[stream] subscriber connected (active={_STREAM_STATS['active']}, "
                  f"total={_STREAM_STATS['total']})", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        last_event = 0.0
        last_keepalive = time.monotonic()
        try:
            while True:
                now = time.monotonic()
                # Peek WITHOUT taking (Store has no public peek; the slot-reference read is
                # atomic) — /agent/pending stays the queue's only consumer.
                if STORE._pending is not None and now - last_event >= 0.5:
                    self.wfile.write(b"event: command\ndata: ping\n\n")
                    self.wfile.flush()
                    last_event = now
                if now - last_keepalive >= 15.0:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_keepalive = now
                time.sleep(0.05)
        except (OSError, ValueError):
            return  # client disconnected (broken pipe / closed wfile) — normal teardown
        finally:
            with _STREAM_LOCK:
                _STREAM_STATS["active"] -= 1
                print(f"[stream] subscriber disconnected (active={_STREAM_STATS['active']})",
                      flush=True)

    def _store_parts(self, path: str):
        """Split /store/<kind>[/<id>] -> (kind, id|None)."""
        parts = [p for p in path.split("/") if p][1:]  # drop the leading 'store'
        if len(parts) == 1:
            return parts[0], None
        if len(parts) == 2:
            return parts[0], parts[1]
        return None, None

    def _store_get(self, path: str):
        kind, item_id = self._store_parts(path)
        if kind is None:
            return self._json(400, {"error": "use /store/<kind>[/<id>]"})
        try:
            if item_id is None:
                return self._json(200, {"items": filestore.list_items(kind)})
            body = filestore.read_item(kind, item_id)
        except filestore.StoreError as exc:
            return self._json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        if body is None:
            return self._json(404, {"error": "no such item"})
        return self._json(200, body)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/store/"):
            return self._json(404, {"error": "not found"})
        kind, item_id = self._store_parts(parsed.path)
        if kind is None or item_id is None:
            return self._json(400, {"error": "use DELETE /store/<kind>/<id>"})
        try:
            existed = filestore.delete_item(kind, item_id)
        except filestore.StoreError as exc:
            return self._json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        return self._json(200, {"ok": True, "existed": existed})

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self._read_json()
        if body is None:
            return self._json(400, {"error": "bad json"})

        if parsed.path == "/agent":
            kind = body.get("kind")
            if kind not in ("tool", "luau", "prompt", "describe"):
                return self._json(400, {"error": "kind must be tool|luau|prompt|describe"})
            # The command queue is a SINGLE SLOT: while a sidecar loop or factory run drives
            # the bridge, an external submission would clobber the in-flight command (silent
            # 240s stall + a false bridge-timeout fed to the model) — fence it off, atomically.
            with _START_LOCK:
                if _agent_busy():
                    return self._json(
                        409,
                        {"error": "a sidecar loop or factory run is active — /agent is fenced "
                         "while it runs (single-slot queue); watch /loop/status or /factory/status"},
                    )
                cid = STORE.submit(body)
            return self._json(200, {"id": cid})
        if parsed.path == "/agent/result":
            cid = body.get("id")
            if not isinstance(cid, int):
                return self._json(400, {"error": "result needs an integer id"})
            STORE.put_result(cid, body)
            return self._json(200, {"ok": True})
        if parsed.path == "/logs":
            STORE.set_logs(body.get("lines", []))
            return self._json(200, {"ok": True})
        if parsed.path == "/reload":
            return self._json(200, {"id": STORE.request_reload()})
        if parsed.path == "/reload/result":
            rid = body.get("id")
            if not isinstance(rid, int):
                return self._json(400, {"error": "reload result needs an integer id"})
            STORE.put_reload_result(rid, body)
            return self._json(200, {"ok": True})
        if parsed.path == "/play":
            return self._json(200, {"id": STORE.play_submit(body)})
        if parsed.path == "/play/result":
            cid = body.get("id")
            if not isinstance(cid, int):
                return self._json(400, {"error": "play result needs an integer id"})
            STORE.play_put_result(cid, body)
            return self._json(200, {"ok": True})
        if parsed.path.startswith("/store/"):
            kind, item_id = self._store_parts(parsed.path)
            if kind is None or item_id is None:
                return self._json(400, {"error": "use POST /store/<kind>/<id>"})
            try:
                filestore.write_item(kind, item_id, body)
            except filestore.StoreError as exc:
                return self._json(400, {"error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
            return self._json(200, {"ok": True})
        if parsed.path == "/loop":
            with _START_LOCK:
                if FACTORY.busy() or FOREVER.busy():
                    return self._json(
                        409, {"error": "a factory or forever run owns the loop; watch its status"}
                    )
                try:
                    run_id = LOOP.start(
                        body.get("prompt"),
                        body.get("maxIterations"),
                        body.get("model"),
                    )
                except agent_loop.LoopError as exc:
                    code = 409 if "already running" in str(exc) else 400
                    return self._json(code, {"error": str(exc)})
                except Exception as exc:  # noqa: BLE001
                    return self._json(500, {"error": str(exc)})
            return self._json(200, {"id": run_id})
        if parsed.path == "/factory":
            with _START_LOCK:
                if FOREVER.busy():
                    return self._json(
                        409,
                        {"error": "a forever run is active — it owns the factory; watch /forever/status"},
                    )
                try:
                    run_id = FACTORY.start(
                        body.get("rungId"),
                        body.get("sabotage", False),
                        supervised=bool(body.get("supervised", False)),
                        staging_id=body.get("stagingId"),
                    )
                except factory_mod.FactoryError as exc:
                    code = 409 if "already active" in str(exc) else 400
                    return self._json(code, {"error": str(exc)})
                except Exception as exc:  # noqa: BLE001
                    return self._json(500, {"error": str(exc)})
            return self._json(200, {"id": run_id})
        if parsed.path == "/forever":
            with _START_LOCK:
                try:
                    run_id = FOREVER.start(body.get("cycles"), body.get("families"))
                except forever_mod.ForeverError as exc:
                    code = 409 if "already active" in str(exc) else 400
                    return self._json(code, {"error": str(exc)})
                except Exception as exc:  # noqa: BLE001
                    return self._json(500, {"error": str(exc)})
            return self._json(200, {"id": run_id})
        if parsed.path == "/forever/stop":
            FOREVER.stop()
            return self._json(200, {"ok": True})
        if parsed.path == "/game/write":
            try:
                result = gamesync.write_game(
                    body.get("files", {}),
                    body.get("manifest", {}),
                    body.get("message", ""),
                    body.get("scope"),
                )
            except gamesync.GameError as exc:
                return self._json(400, {"error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                return self._json(500, {"error": str(exc)})
            result["ok"] = True
            return self._json(200, result)
        return self._json(404, {"error": "not found"})

    def _exemplars(self, qs):
        category = qs.get("category", [""])[0]
        want_b64 = qs.get("b64", ["0"])[0] in ("1", "true")
        try:
            items = exemplars.exemplars_for(category, want_b64=want_b64)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        return self._json(200, {"exemplars": items, "returned": len(items)})

    def _captures(self, qs):
        try:
            count = int(qs.get("count", ["1"])[0])
            since = float(qs.get("since", ["0"])[0])
        except ValueError:
            return self._json(400, {"error": "bad count/since"})
        try:
            pngs = capture.newest_captures(count, since_ts=since)
        except Exception as exc:  # noqa: BLE001
            return self._json(500, {"error": str(exc)})
        images = [base64.b64encode(p).decode("ascii") for p in pngs]
        self._json(200, {"images": images, "returned": len(images), "shortfall": len(images) < count})

    def log_message(self, *args):  # silence default stderr access logging
        pass


def main():
    print(f"Studio Agent sidecar listening on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
