"""Dependency-free tests for GameSync file IO. Run: python sidecar/test_game.py
Uses a throwaway git repo so the auto-commit path is tested for real."""
import os
import subprocess
import sys
import tempfile
from unittest import mock

import game


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["git", "init", "-q"], cwd=d, check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], cwd=d, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=d, check=True)
        # Seed a commit so rev-parse works.
        open(os.path.join(d, "seed"), "w").write("x")
        subprocess.run(["git", "add", "."], cwd=d, check=True)
        subprocess.run(["git", "commit", "-qm", "seed"], cwd=d, check=True)

        with mock.patch.object(game, "REPO_DIR", d), mock.patch.object(
            game, "GAME_DIR", os.path.join(d, "game")
        ):
            # Clean pull commits.
            res = game.write_game(
                {"src/ServerScriptService/RoundLoop.server.luau": "print('hi')\n"},
                {"src/ServerScriptService/RoundLoop.server.luau": {"instancePath": "game.ServerScriptService.RoundLoop"}},
                "test pull",
            )
            fails += _check("write + auto-commit", res["commit"] is not None and res["written"] == 1)
            fails += _check(
                "file on disk",
                open(os.path.join(d, "game", "src", "ServerScriptService", "RoundLoop.server.luau")).read()
                == "print('hi')\n",
            )
            fails += _check("manifest on disk", os.path.isfile(os.path.join(d, "game", "sync-manifest.json")))

            # Identical re-pull -> no commit, honest note.
            res2 = game.write_game(
                {"src/ServerScriptService/RoundLoop.server.luau": "print('hi')\n"},
                {"src/ServerScriptService/RoundLoop.server.luau": {"instancePath": "game.ServerScriptService.RoundLoop"}},
                "test pull 2",
            )
            fails += _check("no-change pull -> no commit", res2["commit"] is None)

            # Dirty game/ refuses.
            with open(os.path.join(d, "game", "src", "ServerScriptService", "RoundLoop.server.luau"), "a") as fh:
                fh.write("-- local edit\n")
            try:
                game.write_game({"a.luau": "x"}, {}, "m")
                fails += _check("dirty game/ refused", False)
            except game.GameError as exc:
                fails += _check("dirty game/ refused", "uncommitted" in str(exc))
            subprocess.run(["git", "checkout", "--", "game/"], cwd=d, check=True)

            # Path escapes refused BEFORE any write.
            for bad in ("../evil.luau", "/abs.luau", "a/../../evil", "C:/x"):
                try:
                    game.write_game({bad: "x"}, {}, "m")
                    fails += _check(f"escape refused: {bad!r}", False)
                except game.GameError:
                    fails += _check(f"escape refused: {bad!r}", True)
            fails += _check("no partial writes from bad batch", not os.path.exists(os.path.join(d, "evil.luau")))

    print(f"=== {('ALL PASS' if fails == 0 else str(fails) + ' FAILED')} ===")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
