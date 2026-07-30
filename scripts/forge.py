#!/usr/bin/env python3
"""forge - offline workspace tooling for the Forest package workspace.

Everything here is PURE OFFLINE and idempotent: it reads manifests, lockfiles and
source trees off disk and never touches the network. That is deliberate - it means
CI can run `forge audit` on every push, and the agent can verify a change without
spending a `forest install` round-trip.

The network-touching operations (install, publish, login) belong to the `forest`
CLI itself. This tool never wraps them.

Subcommands
-----------
  list                      every manifest in the workspace, with its role
  order                     workspace packages in dependency order (deps first)
  audit [--json]            offline integrity checks; exit 1 on any error
  new <name>                scaffold a workspace package (see WHY below)
  version <name> <bump>     bump a package version (patch|minor|major) + changelog

WHY `new` exists: `forest init` (the package-authoring scaffold) requires a TTY -
it prompts for name and root and dies with "IO error: not a terminal" when run
non-interactively. Verified against forest 1.8.0. So an agent cannot use it. The
manifest schema is small and documented, so we write it ourselves and let
`forest install` validate it. `forest init --project` IS non-interactive-safe,
and that is what the game-side project manifests use.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Schema constants, all traceable to https://docs.forest.dev
# ---------------------------------------------------------------------------

PLATFORMS = {"roblox", "uefn"}

# "Lowercase letters, digits, and hyphens only." - concepts/manifest
PKG_NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

# Official SemVer 2.0.0 pattern.
SEMVER_RE = re.compile(
    r"^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)"
    r"(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+(?P<build>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
)

# A dependency key is a full package identifier. Native packages are scoped
# `@scope/name`; Wally mirrors are bare `author/name` (verified: `forest i
# evaera/promise` resolves and lands as `Packages/promise`).
DEP_KEY_RE = re.compile(r"^@?[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*$")

# Version ranges: ^1.2.3  ~1.2.3  =1.2.3  1.2.*  >=1.2, <1.5  1.2.3
RANGE_RE = re.compile(r"^\s*(?:[\^~=]|>=?|<=?)?\s*[0-9][0-9a-zA-Z.\*\-+]*\s*$")

# Publish limit - concepts/publishing + platforms/roblox/anatomy.
MAX_ARCHIVE_BYTES = 10 * 1024 * 1024

# Excluded from a published archive, so excluded from the size estimate too.
ARCHIVE_EXCLUDE_DIRS = {"Packages", ".git", "__pycache__", "node_modules"}
ARCHIVE_EXCLUDE_FILES = {"forest-lock.json", ".DS_Store", "Thumbs.db"}

ROOT_MARKER = Path(".claude-plugin") / "plugin.json"


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------


@dataclass
class Finding:
    level: str  # "error" | "warn"
    where: str  # repo-relative path
    message: str

    def render(self) -> str:
        tag = "ERROR" if self.level == "error" else "warn "
        return f"  [{tag}] {self.where}: {self.message}"


@dataclass
class Manifest:
    path: Path  # path to forest.json
    data: dict
    role: str  # "package" | "project"

    @property
    def dir(self) -> Path:
        return self.path.parent

    @property
    def name(self) -> str:
        return self.data.get("name") or self.dir.name

    @property
    def deps(self) -> dict:
        d = self.data.get("dependencies")
        return d if isinstance(d, dict) else {}

    @property
    def root_module(self) -> Path | None:
        """Absolute path to the entry module, resolving the documented fallbacks."""
        declared = self.data.get("root")
        if isinstance(declared, str) and declared:
            return self.dir / declared
        for candidate in ("init.luau", "init.lua"):
            p = self.dir / candidate
            if p.is_file():
                return p
        for child in sorted(self.dir.iterdir()) if self.dir.is_dir() else []:
            if not child.is_dir() or child.name in ARCHIVE_EXCLUDE_DIRS:
                continue
            for candidate in ("init.luau", "init.lua"):
                p = child / candidate
                if p.is_file():
                    return p
        return None

    @property
    def packages_dir(self) -> Path:
        """Where `forest install` puts the tree for THIS manifest.

        Verified against forest 1.8.0: next to forest.json normally, but next to
        the `root` module when `root` is declared (so `src/Packages/`).
        """
        declared = self.data.get("root")
        if isinstance(declared, str) and declared:
            return (self.dir / declared).parent / "Packages"
        return self.dir / "Packages"


@dataclass
class Workspace:
    root: Path
    manifests: list[Manifest] = field(default_factory=list)

    def rel(self, p: Path) -> str:
        try:
            return str(p.relative_to(self.root)).replace("\\", "/")
        except ValueError:
            return str(p).replace("\\", "/")

    @property
    def packages(self) -> list[Manifest]:
        return [m for m in self.manifests if m.role == "package"]


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------


def find_root(start: Path) -> Path:
    for candidate in [start, *start.parents]:
        if (candidate / ROOT_MARKER).is_file():
            return candidate
    return start


def load_workspace(root: Path) -> tuple[Workspace, list[Finding]]:
    ws = Workspace(root=root)
    findings: list[Finding] = []

    for manifest_path in sorted(root.rglob("forest.json")):
        parts = set(manifest_path.parts)
        # Never descend into installed trees or the archived game banks.
        if parts & {"Packages", "node_modules", ".git", "archive"}:
            continue
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            findings.append(Finding("error", ws.rel(manifest_path), f"unreadable: {exc}"))
            continue
        if not isinstance(data, dict):
            findings.append(Finding("error", ws.rel(manifest_path), "top level must be an object"))
            continue
        # A manifest with a `name` is a publishable package; one without is a
        # bare consuming project (what `forest init --project` writes).
        role = "package" if data.get("name") else "project"
        ws.manifests.append(Manifest(path=manifest_path, data=data, role=role))

    return ws, findings


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------


def audit_manifest(ws: Workspace, m: Manifest) -> list[Finding]:
    out: list[Finding] = []
    where = ws.rel(m.path)

    def err(msg: str) -> None:
        out.append(Finding("error", where, msg))

    def warn(msg: str) -> None:
        out.append(Finding("warn", where, msg))

    platform = m.data.get("platform")
    if platform not in PLATFORMS:
        err(f"`platform` must be one of {sorted(PLATFORMS)}, got {platform!r}")

    if m.role == "package":
        name = m.data.get("name")
        if not isinstance(name, str) or not PKG_NAME_RE.match(name):
            err(f"`name` must be lowercase letters, digits and hyphens only, got {name!r}")

        version = m.data.get("version")
        if not isinstance(version, str) or not SEMVER_RE.match(version):
            err(f"`version` must be SemVer MAJOR.MINOR.PATCH, got {version!r}")

        # `author` is filled in at publish time; blank is fine before M6.
        if not m.data.get("author"):
            warn("`author` is unset - required to publish (the scope you publish under)")

        license_id = m.data.get("license")
        if not license_id:
            err("`license` is required to publish (an SPDX id, or 'SEE LICENSE IN <file>')")
        elif isinstance(license_id, str) and license_id.startswith("SEE LICENSE IN "):
            ref = license_id[len("SEE LICENSE IN ") :].strip()
            if not (m.dir / ref).is_file():
                err(f"`license` points at {ref!r}, which does not exist")

        if not m.data.get("description"):
            warn("`description` is unset - it is what shows in registry search")

        if not (m.dir / "LICENSE").is_file():
            err("no LICENSE file - publish requires one")
        if not (m.dir / "README.md").is_file():
            warn("no README.md - required to publish a PUBLIC package")

        declared_root = m.data.get("root")
        if platform == "roblox":
            if not declared_root:
                warn("`root` is unset - forest will guess; declare it explicitly")
            elif not isinstance(declared_root, str):
                err("`root` must be a string path")
            else:
                if "\\" in declared_root:
                    err(f"`root` must use forward slashes, got {declared_root!r}")
                if not (m.dir / declared_root).is_file():
                    err(f"`root` points at {declared_root!r}, which does not exist")
                elif not declared_root.endswith((".luau", ".lua")):
                    err(f"`root` must be a Luau module, got {declared_root!r}")

        size = estimate_archive_bytes(m.dir)
        if size > MAX_ARCHIVE_BYTES:
            err(f"archive estimate {size / 1e6:.1f} MB exceeds the 10 MB publish cap")
        elif size > MAX_ARCHIVE_BYTES * 0.8:
            warn(f"archive estimate {size / 1e6:.1f} MB is near the 10 MB publish cap")

    out.extend(audit_dependencies(ws, m))
    out.extend(audit_lockfile(ws, m))
    out.extend(audit_requires(ws, m))
    return out


def audit_dependencies(ws: Workspace, m: Manifest) -> list[Finding]:
    out: list[Finding] = []
    where = ws.rel(m.path)
    for key, spec in m.deps.items():
        if not DEP_KEY_RE.match(key):
            out.append(
                Finding("error", where, f"dependency key {key!r} is not a package identifier")
            )
        if isinstance(spec, str):
            if not RANGE_RE.match(spec) and "," not in spec:
                out.append(Finding("error", where, f"dependency {key!r} has bad range {spec!r}"))
        elif isinstance(spec, dict):
            version = spec.get("version")
            if not isinstance(version, str):
                out.append(Finding("error", where, f"dependency {key!r} object needs `version`"))
            alias = spec.get("alias")
            if alias is not None:
                if not isinstance(alias, str) or not alias:
                    out.append(Finding("error", where, f"dependency {key!r} has a bad `alias`"))
                elif alias[0] in "_.":
                    out.append(
                        Finding("error", where, f"alias {alias!r} may not start with '_' or '.'")
                    )
        else:
            out.append(Finding("error", where, f"dependency {key!r} must be a string or object"))
    return out


def audit_lockfile(ws: Workspace, m: Manifest) -> list[Finding]:
    """Every declared dep must be pinned, and any installed tree must match the pin."""
    out: list[Finding] = []
    where = ws.rel(m.path)
    lock_path = m.dir / "forest-lock.json"

    if not m.deps:
        return out
    if not lock_path.is_file():
        out.append(Finding("error", where, "declares dependencies but has no forest-lock.json"))
        return out

    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        out.append(Finding("error", ws.rel(lock_path), f"unreadable: {exc}"))
        return out

    locked = lock.get("packages")
    if not isinstance(locked, dict):
        out.append(Finding("error", ws.rel(lock_path), "missing a `packages` object"))
        return out

    for key in m.deps:
        entries = locked.get(key)
        if not entries:
            out.append(Finding("error", ws.rel(lock_path), f"{key!r} is declared but not locked"))
            continue
        for entry in entries if isinstance(entries, list) else [entries]:
            if not isinstance(entry, dict) or not entry.get("integrity"):
                out.append(
                    Finding("error", ws.rel(lock_path), f"{key!r} lock entry has no integrity hash")
                )

    # If the tree is installed, cross-check each receipt against the lock. This
    # catches a hand-edited or half-installed Packages/ folder.
    pkg_dir = m.packages_dir
    if pkg_dir.is_dir():
        by_integrity = {
            entry.get("integrity")
            for entries in locked.values()
            for entry in (entries if isinstance(entries, list) else [entries])
            if isinstance(entry, dict)
        }
        for receipt_path in sorted(pkg_dir.glob("*/.forest-receipt")):
            try:
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                out.append(Finding("warn", ws.rel(receipt_path), "unreadable receipt"))
                continue
            if receipt.get("integrity") not in by_integrity:
                out.append(
                    Finding(
                        "error",
                        ws.rel(receipt_path),
                        f"installed {receipt.get('name')}@{receipt.get('version')} is not in the "
                        "lockfile - run `forest install -f`",
                    )
                )
    return out


ABSOLUTE_REQUIRE_RE = re.compile(
    r"require\s*\(\s*(?:game[:.]|game\s*:\s*GetService|"
    r"ReplicatedStorage|ServerScriptService|ServerStorage|StarterPlayer)",
    re.IGNORECASE,
)


def audit_requires(ws: Workspace, m: Manifest) -> list[Finding]:
    """A package's internal requires must be RELATIVE.

    From platforms/roblox/intro: "All requires inside the installed tree are
    relative, so the tree works wherever you mount it." A package that reaches
    for `ReplicatedStorage.Packages` breaks the moment a consumer mounts
    somewhere else - or nests it as a transitive dependency, where it lives in
    the PARENT's Packages/ folder rather than the root one.
    """
    out: list[Finding] = []
    if m.role != "package":
        return out
    root = m.root_module
    if root is None:
        return out
    src_dir = root.parent
    for lua in sorted(src_dir.rglob("*.lua*")):
        if set(lua.parts) & ARCHIVE_EXCLUDE_DIRS:
            continue
        try:
            text = lua.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue
            if ABSOLUTE_REQUIRE_RE.search(line):
                out.append(
                    Finding(
                        "error",
                        f"{ws.rel(lua)}:{lineno}",
                        "absolute require inside a package - use a relative path "
                        "(script.Parent...) so the tree is mount-independent",
                    )
                )
    return out


def estimate_archive_bytes(pkg_dir: Path) -> int:
    total = 0
    for path in pkg_dir.rglob("*"):
        if not path.is_file():
            continue
        parts = set(path.parts)
        if parts & ARCHIVE_EXCLUDE_DIRS or path.name in ARCHIVE_EXCLUDE_FILES:
            continue
        if path.name.startswith("."):
            continue
        try:
            total += path.stat().st_size
        except OSError:
            pass
    return total


def audit_graph(ws: Workspace) -> list[Finding]:
    """Cycles are legal in Forest but the docs call them a design smell."""
    out: list[Finding] = []
    local = {m.name: m for m in ws.packages}
    edges = {
        name: [local_name(dep) for dep in m.deps if local_name(dep) in local]
        for name, m in local.items()
    }

    state: dict[str, int] = {}

    def visit(node: str, stack: list[str]) -> None:
        if state.get(node) == 2:
            return
        if state.get(node) == 1:
            cycle = " -> ".join([*stack[stack.index(node) :], node])
            out.append(Finding("warn", "workspace", f"dependency cycle: {cycle}"))
            return
        state[node] = 1
        for nxt in edges.get(node, []):
            visit(nxt, [*stack, node])
        state[node] = 2

    for name in sorted(edges):
        visit(name, [])
    return out


def local_name(dep_key: str) -> str:
    return dep_key.rsplit("/", 1)[-1]


# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------


def dependency_order(ws: Workspace) -> list[str]:
    """Workspace packages, dependencies first. Stable, and cycle-tolerant."""
    local = {m.name: m for m in ws.packages}
    ordered: list[str] = []
    seen: set[str] = set()
    visiting: set[str] = set()

    def visit(name: str) -> None:
        if name in seen or name in visiting:
            return
        visiting.add(name)
        m = local[name]
        for dep in sorted(m.deps):
            short = local_name(dep)
            if short in local:
                visit(short)
        visiting.discard(name)
        seen.add(name)
        ordered.append(name)

    for name in sorted(local):
        visit(name)
    return ordered


# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------

MIT_LICENSE = """MIT License

Copyright (c) 2026 {holder}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

FORESTIGNORE = """# Files kept out of the published archive.
# `Packages/`, `forest-lock.json` and dotfiles are excluded by forest already.
tests/
*.spec.luau
*.spec.lua
"""


def cmd_new(ws: Workspace, args: argparse.Namespace) -> int:
    name = args.name
    if not PKG_NAME_RE.match(name):
        print(f"error: {name!r} must be lowercase letters, digits and hyphens only", file=sys.stderr)
        return 1

    pkg_dir = ws.root / "packages" / name
    if pkg_dir.exists():
        print(f"error: {ws.rel(pkg_dir)} already exists", file=sys.stderr)
        return 1

    (pkg_dir / "src").mkdir(parents=True)
    (pkg_dir / "tests").mkdir()

    manifest = {
        "name": name,
        "author": args.author or "",
        "version": "0.1.0",
        "description": args.description or "",
        "platform": "roblox",
        "license": "MIT",
        "root": "src/init.luau",
        "dependencies": {},
    }
    write_json(pkg_dir / "forest.json", manifest)

    title = name.replace("-", " ").title()
    pascal = to_pascal(name)

    # init.luau stays a THIN aggregator on purpose. It uses Roblox require syntax
    # (`script.X`), which Lune cannot resolve - so every line of real logic lives
    # in siblings that specs can require directly. See scripts/test.luau.
    (pkg_dir / "src" / "init.luau").write_text(
        f"--!strict\n"
        f"-- {name}: {args.description or 'TODO describe the package'}\n"
        f"--\n"
        f"-- The value returned here is the package's ENTIRE public API - nothing else in\n"
        f"-- this folder is reachable by a consumer. Keep the surface small, and keep\n"
        f"-- require-time free of side effects (a consumer may require this on both\n"
        f"-- realms; initialise through an explicit :Init()/:Start() instead).\n"
        f"--\n"
        f"-- Keep this file a thin aggregator: logic belongs in siblings so it stays\n"
        f"-- testable under Lune, which has no `script`.\n"
        f"\n"
        f"return require(script.{pascal})\n",
        encoding="utf-8",
    )
    (pkg_dir / "src" / f"{pascal}.luau").write_text(
        f"--!strict\n"
        f"-- {pascal}: the implementation behind `{name}`.\n"
        f"--\n"
        f"-- Pure Luau. No `game`, no `script`, no services - that is what keeps this\n"
        f"-- module runnable under Lune. If you need a Roblox service, take it as an\n"
        f"-- injected argument so a test can pass a fake.\n"
        f"\n"
        f"local {pascal} = {{}}\n"
        f"\n"
        f"return {pascal}\n",
        encoding="utf-8",
    )
    (pkg_dir / "README.md").write_text(
        f"# {name}\n\n{args.description or 'TODO'}\n\n"
        f"## Install\n\n```sh\nforest i @{args.author or '<scope>'}/{name}\n```\n\n"
        f"## Usage\n\n```lua\nlocal {to_pascal(name)} = require(Packages.{name})\n```\n",
        encoding="utf-8",
    )
    (pkg_dir / "LICENSE").write_text(
        MIT_LICENSE.format(holder=args.holder or args.author or "WallyThePenguin"), encoding="utf-8"
    )
    (pkg_dir / "CHANGELOG.md").write_text(
        f"# Changelog\n\nAll notable changes to `{name}`.\n\n## 0.1.0 - unreleased\n\n- Initial.\n",
        encoding="utf-8",
    )
    (pkg_dir / ".forestignore").write_text(FORESTIGNORE, encoding="utf-8")
    # Note the require target: the SIBLING module, never ../src/init (Lune cannot
    # resolve `script.X`).
    (pkg_dir / "tests" / f"{pascal}.spec.luau").write_text(
        f"--!strict\n"
        f"-- Specs for {name}. Run with: lune run scripts/test.luau {name}\n"
        f"\n"
        f'local {pascal} = require("../src/{pascal}")\n'
        f"\n"
        f"return function(t)\n"
        f'\tt.test("{title} loads", function(expect)\n'
        f'\t\texpect(type({pascal})).toBe("table")\n'
        f"\tend)\n"
        f"end\n",
        encoding="utf-8",
    )

    print(f"scaffolded {ws.rel(pkg_dir)}")
    print("  next: write src/, then `forge audit` to check it")
    return 0


def to_pascal(name: str) -> str:
    return "".join(part.capitalize() for part in name.split("-"))


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def cmd_version(ws: Workspace, args: argparse.Namespace) -> int:
    target = next((m for m in ws.packages if m.name == args.name), None)
    if target is None:
        print(f"error: no workspace package named {args.name!r}", file=sys.stderr)
        return 1
    match = SEMVER_RE.match(str(target.data.get("version", "")))
    if not match:
        print(f"error: {args.name} has no valid version to bump", file=sys.stderr)
        return 1
    major, minor, patch = (int(match.group(g)) for g in ("major", "minor", "patch"))
    if args.bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif args.bump == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    new_version = f"{major}.{minor}.{patch}"
    target.data["version"] = new_version
    write_json(target.path, target.data)

    changelog = target.dir / "CHANGELOG.md"
    if changelog.is_file():
        text = changelog.read_text(encoding="utf-8")
        marker = "\n## "
        idx = text.find(marker)
        entry = f"\n## {new_version}\n\n- TODO describe the change.\n"
        text = (text[:idx] + entry + text[idx:]) if idx != -1 else text + entry
        changelog.write_text(text, encoding="utf-8")

    print(f"{args.name}: {match.group(0)} -> {new_version}")
    print("  NOTE: `forest publish` also prompts for the bump and writes the version")
    print("  itself. Use this only to stage a version before publishing.")
    return 0


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_list(ws: Workspace, args: argparse.Namespace) -> int:
    if not ws.manifests:
        print("no forest.json manifests found")
        return 0
    width = max(len(ws.rel(m.path)) for m in ws.manifests)
    for m in sorted(ws.manifests, key=lambda x: ws.rel(x.path)):
        version = m.data.get("version", "-")
        deps = len(m.deps)
        print(f"{ws.rel(m.path):<{width}}  {m.role:<7}  {version:<10}  {deps} dep(s)")
    return 0


def cmd_order(ws: Workspace, args: argparse.Namespace) -> int:
    order = dependency_order(ws)
    if not order:
        print("no workspace packages yet")
        return 0
    for name in order:
        print(name)
    return 0


def cmd_audit(ws: Workspace, args: argparse.Namespace, preload: list[Finding]) -> int:
    findings = list(preload)
    for m in ws.manifests:
        findings.extend(audit_manifest(ws, m))
    findings.extend(audit_graph(ws))

    errors = [f for f in findings if f.level == "error"]
    warns = [f for f in findings if f.level == "warn"]

    if args.json:
        print(
            json.dumps(
                {
                    "manifests": len(ws.manifests),
                    "packages": len(ws.packages),
                    "errors": [f.__dict__ for f in errors],
                    "warnings": [f.__dict__ for f in warns],
                },
                indent=2,
            )
        )
        return 1 if errors else 0

    print(f"forge audit - {len(ws.manifests)} manifest(s), {len(ws.packages)} package(s)")
    if errors:
        print(f"\n{len(errors)} error(s):")
        for f in errors:
            print(f.render())
    if warns:
        print(f"\n{len(warns)} warning(s):")
        for f in warns:
            print(f.render())
    if not errors and not warns:
        print("clean.")
    elif not errors:
        print("\nno errors.")
    return 1 if errors else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="forge", description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=None, help="workspace root (default: detected)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="every manifest in the workspace")
    sub.add_parser("order", help="workspace packages in dependency order")

    audit = sub.add_parser("audit", help="offline integrity checks")
    audit.add_argument("--json", action="store_true", help="machine-readable output")

    new = sub.add_parser("new", help="scaffold a workspace package")
    new.add_argument("name")
    new.add_argument("--description", default="")
    new.add_argument("--author", default="", help="Forest scope; safe to leave blank until publish")
    new.add_argument("--holder", default="", help="copyright holder for LICENSE")

    version = sub.add_parser("version", help="bump a package version")
    version.add_argument("name")
    version.add_argument("bump", choices=["patch", "minor", "major"])

    args = parser.parse_args(argv)
    root = args.root.resolve() if args.root else find_root(Path.cwd().resolve())
    ws, preload = load_workspace(root)

    if args.command == "list":
        return cmd_list(ws, args)
    if args.command == "order":
        return cmd_order(ws, args)
    if args.command == "audit":
        return cmd_audit(ws, args, preload)
    if args.command == "new":
        return cmd_new(ws, args)
    if args.command == "version":
        return cmd_version(ws, args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
