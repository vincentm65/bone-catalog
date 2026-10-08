# Bone 2 catalog

This index serves Bone 2's `lua/plugins/<name>/init.lua` packages. Bone 3's
separate catalog is at the repository root; its entry points are incompatible.

The `usage` dashboard and editable `system_prompt` plugins require Bone 2.4.6.
The usage plugin owns both `/stats` and `/usage`; there is no native dashboard.
Its layout and input use the standard `ui.page` helper supplied by that build.

Run `./gen-index.sh` after changing a package. Optional package `manifest.json`
files set `version` and `min_bone_version`; the index hashes every package file.
