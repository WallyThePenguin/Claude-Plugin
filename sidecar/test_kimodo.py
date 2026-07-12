"""Dependency-free tests for the kimodo driver (pure cmd-building + input validation; no GPU/subprocess).
Run: python sidecar/test_kimodo.py"""
import sys

import kimodo


def _check(name, cond):
    print(("  PASS  " if cond else "  FAIL  ") + name)
    return 0 if cond else 1


def main():
    fails = 0
    cmd = kimodo._build_cmd("swing a sword", "/abs/stem", "Kimodo-SOMA-RP-v1", 3.0, 42, None, True)
    fails += _check("prompt is positional", "swing a sword" in cmd)
    fails += _check("SOMA model passed", "--model" in cmd and "Kimodo-SOMA-RP-v1" in cmd)
    fails += _check("output stem passed", "--output" in cmd and "/abs/stem" in cmd)
    fails += _check("--no-postprocess present (skip the CMake postprocess)", "--no-postprocess" in cmd)
    fails += _check("seed present", "--seed" in cmd and "42" in cmd)
    fails += _check("cfg omitted when None", "--cfg_weight" not in cmd)

    cmd2 = kimodo._build_cmd("p", "/s", None, 3.0, None, 6.5, False)
    fails += _check("default model when None", "--model" in cmd2 and kimodo.DEFAULT_MODEL in cmd2)
    fails += _check("cfg_weight included when set", "--cfg_weight" in cmd2 and "6.5" in cmd2)
    fails += _check("--no-postprocess omitted when False", "--no-postprocess" not in cmd2)
    fails += _check("seed omitted when None", "--seed" not in cmd2)

    fails += _check("the required flag trio is complete",
                    set(kimodo.KIMODO_ENV) == {"HF_HUB_DISABLE_XET", "HF_HUB_DISABLE_SYMLINKS", "TEXT_ENCODER_DEVICE"}
                    and kimodo.KIMODO_ENV["TEXT_ENCODER_DEVICE"] == "cpu")

    # input validation short-circuits BEFORE any subprocess
    r = kimodo.generate("p", "../evil")
    fails += _check("path-traversal out_stem rejected", r.get("ok") is False and "out_stem" in r.get("error", ""))
    r2 = kimodo.generate("p", "sub/dir")
    fails += _check("slashed out_stem rejected", r2.get("ok") is False)

    print("test_kimodo: " + ("ALL GREEN" if fails == 0 else f"{fails} FAILURES"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
