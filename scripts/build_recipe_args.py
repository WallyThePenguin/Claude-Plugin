"""Emit the compact `args` JSON for one train-recipe factory run.

The train-recipe workflow runs in a sandbox with NO filesystem access, so its inputs (the
category's rubric + config) must be passed via `args`. The factory only consumes {id, tier,
statement} per criterion plus the version, so we slim the (possibly large) rubric to that.

Usage:  python scripts/build_recipe_args.py <category>
Prints one line of compact JSON suitable to paste into the Workflow tool's `args`.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUBRICS = os.path.join(ROOT, "docs", "superpowers", "rubrics")

# The agent's real build tools — so factory steps cite real tool names, not invented ones.
TOOLS = [
    "run_luau", "create_instance", "set_property", "add_keyframe", "bind_animation",
    "bind_behavior", "bind_hitbox", "make_tool", "grip_tool", "make_npc", "generate_mesh",
    "author_mesh", "save_mesh", "paint_texture", "spawn_rig", "pose_joint", "ik_reach",
    "capture", "capture_angles", "capture_animation",
]

# vfx was onboarded without a committed .config.json; supply its description + killer systems
# (particle / visual-effects authoring) so the factory has the same inputs the others get.
VFX_FALLBACK = {
    "description": "Roblox stylized visual effects / particle FX (impacts, magic, energy, "
    "environmental ambience) built with ParticleEmitter / Beam / Trail / Light",
    "killerSystems": [
        "layered emitters per effect (core + glow + sparks + smoke), not a single ParticleEmitter",
        "shaped lifetime curves via NumberSequence/ColorSequence (size, transparency, color over life)",
        "timed phases burst -> sustain -> dissipate (Rate/Enabled scripting or sub-emitters), not a constant stream",
        "additive / world-space blending + emissive material so energy reads as light",
        "coupling to a PointLight + a brief camera shake + secondary debris for impact weight",
    ],
}


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: build_recipe_args.py <category>")
    cat = sys.argv[1].strip().lower()
    with open(os.path.join(RUBRICS, cat + ".rubric.json"), encoding="utf-8") as f:
        rub = json.load(f)
    slim = {
        "module": rub.get("module", cat),
        "version": str(rub.get("version", "1.0")),
        "criteria": [
            {"id": c.get("id"), "tier": c.get("tier"), "statement": c.get("statement")}
            for c in rub.get("criteria", [])
        ],
    }
    cfg_path = os.path.join(RUBRICS, cat + ".config.json")
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            cfg = json.load(f)
        desc = cfg.get("description", "")
        killer = cfg.get("killerSystems", [])
    else:
        desc = VFX_FALLBACK["description"]
        killer = VFX_FALLBACK["killerSystems"]
    args = {
        "category": cat,
        "description": desc,
        "killerSystems": killer,
        "rubric": slim,
        "toolCatalog": TOOLS,
    }
    # ensure_ascii=True so unicode in rubric statements (e.g. arrows) survives a cp1252 stdout;
    # the escaped \uXXXX form is still valid JSON for the workflow's parser.
    print(json.dumps(args, ensure_ascii=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
