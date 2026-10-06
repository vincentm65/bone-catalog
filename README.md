# Bone catalog

This repository is now the native Bone 3 catalog. Bone 3's built-in `/catalog`
page reads this repository's `catalog.json`, verifies every file hash, and can
install or update packages directly into `~/.bone/plugins`. Every package is a normal Bone 3
plugin and may contain a `core.lua` half, a `tui.lua` half, shared `lua/`
modules, colors, documentation, and tests. Packages are installed by copying
their directory to `~/.bone/plugins/<name>`; the runtime's `/plugin` command
then controls loading and unloading.

The catalog deliberately keeps distribution separate from execution. `catalog.json`
is generated from package manifests and records the files and hashes an
installer should verify before replacing an installed package.

The first ports preserve the old catalog's names and user-facing commands,
while using Bone 3's APIs (`bone.tool.register`, `bone.cmd.create`,
`bone.hook`, `bone.ask`, `bone.ui.panel`, and `bone.model.complete`). A package
with no core or TUI half is still valid; for example, a colors-only package
only contributes files under `colors/`.

A package can declare settings in its `manifest.json` (`"settings": [ { "key", "label", "type", "default", "min", "max", "choices", "desc" } ]`); they get a tab in `/config` and are read with `bone.settings.get("<package>.<key>")`.

Generate the index with:

```sh
python3 gen-index.py
```

Install one package into a Bone 3 config directory after generating the index:

```sh
python3 install.py web_search
```

Use `--force` to replace an existing package. Installation is staged and the
package files are hash-checked against `catalog.json` before they are copied.

Run the package syntax checks with:

```sh
python3 check.py
python3 gen-index.py --check
```

Build Bone 3 in its own checkout with `cargo build -p bone`, then load every
catalog core half through that headless binary:

```sh
BONE_BIN=/path/to/bone3 python3 runtime-check.py
```

Check task-loop isolation in both plugin halves and through concurrent Bone 3
turns (a local scripted provider, with no model calls):

```sh
luajit tests/task_loop_test.lua
BONE_BIN=/path/to/bone3 python3 tests/task_loop_runtime_test.py
BONE_BIN=/path/to/bone3 python3 tests/task_loop_tmux_test.py
```

The previous catalog, including its index, packages and tests, is archived under
[`legacy/`](legacy/). The root index and installer target Bone 3. See
[PORT_STATUS.md](PORT_STATUS.md) for remaining differences from the old plugins.
