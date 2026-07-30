---
description: Run the full Luau test suite plus linters, and report per package
argument-hint: [package-name-filter]
---

# Run the test suite

```sh
lune run scripts/test.luau $ARGUMENTS
selene packages/ game/
stylua --check packages/ game/
python scripts/forge.py audit
```

Load the `roblox-testing` skill if you're about to write or fix tests.

## Reading a failure

The runner prints the spec path, the test name, and the assertion message. Two failure
shapes mean something specific:

- **`(load failed)`** — the spec file itself couldn't be required. Almost always a spec
  requiring `../src/init` instead of a sibling module: `init.luau` uses Roblox's
  `require(script.X)`, which Lune cannot resolve. Point the spec at the sibling.
- **`(threw outside a test)`** — code at the top level of the spec, or at require time in
  the module under test, raised. If it's the module, that's a require-time side effect and
  it's a real bug: a Forest package's root may be required on both realms, so require-time
  work breaks consumers.

## Rules

- **Never** weaken an assertion to make a test pass. If a test is wrong, fix the test and
  say why it was wrong. If the code is wrong, fix the code.
- A failing suite is reported as failing, with the output. Don't summarise it as "mostly
  passing".
- Coverage gaps worth having are boundary values: `NaN` (defeats every comparison —
  `NaN > 0` and `NaN <= 0` are both false), `math.huge`, negative zero, non-integers, wrong
  types, missing arguments, and empty collections.
- Physics, replication, input and animation can't be covered here. Those need an in-Studio
  playtest (`scripts/studio-agent.ps1 play`). Don't fake them into a Lune spec — a spec that
  asserts on a fake's behaviour tests the fake.
