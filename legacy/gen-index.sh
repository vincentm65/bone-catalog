#!/usr/bin/env bash
# Regenerate catalog.json from the plugin packages under plugins/.
#
# Every catalog item is a plugin package: plugins/<name>/init.lua is the
# entry point (the "primary" file, indexed by bare package name); every other
# file in the package is a bundled file published under its scoped path
# (plugins/<name>/...), which doubles as the fetch URL and the install path
# beneath ~/.bone-rust/lua/. Repo layout must match the index paths exactly.
#
# Each entry: { name, kind, description, version, min_bone_version, sha256, files? }.
#  - description: prefer a `description = "..."` field, else the first `--`
#    comment line (mirrors `extract_description` in src/ext/mod.rs).
#  - sha256: over the file bytes. The bone client both verifies downloads and
#    detects updates against it (on-disk hash != this => "update available"),
#    so it MUST track the file. Run this whenever a package file changes — CI
#    fails the build if catalog.json is stale.
#
# Usage: ./gen-index.sh   (run from the repo root or the catalog dir)
set -euo pipefail

cd "$(dirname "$0")"

# Published metadata shared by every item. min_bone_version must stay <= the
# oldest Bone build that understands plugin packages.
VERSION="1.0.0"
MIN_BONE_VERSION="2.4.5"

out="catalog.json.tmp"

# Extract a one-line description from a Lua file.
extract_desc() {
  local file="$1"
  # Prefer an explicit catalog description when a file contains nested schema
  # descriptions before its registered tool/command description.
  local d
  d=$(grep -oE 'catalog_description[[:space:]]*=[[:space:]]*"[^"]*"' "$file" | head -1 \
        | sed -E 's/.*catalog_description[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
  if [[ -n "$d" ]]; then printf '%s' "$d"; return; fi
  # Prefer `description = "..."`.
  d=$(grep -oE 'description[[:space:]]*=[[:space:]]*"[^"]*"' "$file" | head -1 \
        | sed -E 's/.*description[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
  if [[ -n "$d" ]]; then printf '%s' "$d"; return; fi
  # Else the first non-empty `--` comment line.
  grep -m1 -E '^\s*--' "$file" | sed -E 's/^\s*-+\s*//'
}

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'; }

echo "[" > "$out"
first=1
for init in plugins/*/init.lua; do
  [[ -e "$init" ]] || continue
  pkg=$(dirname "$init")
  name=$(basename "$pkg")
  desc=$(extract_desc "$init" | json_escape)
  sha=$(sha256sum "$init" | cut -d' ' -f1)
  if [[ $first -eq 0 ]]; then echo "," >> "$out"; fi
  first=0
  printf '  { "name": %s, "kind": "plugin", "description": %s, "version": "%s", "min_bone_version": "%s", "sha256": "%s"' \
    "\"$name\"" "$desc" "$VERSION" "$MIN_BONE_VERSION" "$sha" >> "$out"
  # Bundled files: everything in the package besides init.lua, sorted,
  # published under its scoped path (plugins/<name>/...).
  bundled_files=()
  while IFS= read -r bundled; do
    [[ -n "$bundled" ]] && bundled_files+=("$bundled")
  done < <(cd "$pkg" && find . -type f ! -name 'init.lua' | sed 's|^\./||' | sort)
  if [[ ${#bundled_files[@]} -gt 0 ]]; then
    printf ', "files": [' >> "$out"
    bundle_first=1
    for bundled in "${bundled_files[@]}"; do
      bundled_sha=$(sha256sum "$pkg/$bundled" | cut -d' ' -f1)
      if [[ $bundle_first -eq 0 ]]; then printf ', ' >> "$out"; fi
      bundle_first=0
      printf '{ "path": "%s", "sha256": "%s" }' \
        "$pkg/$bundled" "$bundled_sha" >> "$out"
    done
    printf ']' >> "$out"
  fi
  printf ' }' >> "$out"
done
echo "" >> "$out"
echo "]" >> "$out"

mv "$out" "catalog.json"
echo "wrote catalog.json"
