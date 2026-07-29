#!/usr/bin/env bash
# Regenerate catalog.json from the visible tools/ and commands/ .lua files.
# Theme files and tool runtime helpers are bundled with their owning Lua item
# rather than indexed separately.
#
# Each entry: { name, kind, description, sha256, files? }.
#  - description: prefer a `description = "..."` field, else the first `--`
#    comment line (mirrors `extract_description` in src/ext/mod.rs).
#  - sha256: over the file bytes. The bone client both verifies downloads and
#    detects updates against it (on-disk hash != this => "update available"),
#    so it MUST track the file. Run this whenever a .lua file changes — CI
#    fails the build if catalog.json is stale.
#
# Usage: ./gen-index.sh   (run from the repo root or the catalog dir)
set -euo pipefail

cd "$(dirname "$0")"

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
for kind in tools commands; do
  [[ -d "$kind" ]] || continue
  singular=${kind%s}
  for file in "$kind"/*.lua; do
    [[ -e "$file" ]] || continue
    name=$(basename "$file")
    desc=$(extract_desc "$file" | json_escape)
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ $first -eq 0 ]]; then echo "," >> "$out"; fi
    first=0
    printf '  { "name": %s, "kind": "%s", "description": %s, "sha256": "%s"' \
      "\"$name\"" "$singular" "$desc" "$sha" >> "$out"
    bundled_files=()
    if [[ "$file" == "commands/themes.lua" ]]; then
      mapfile -t bundled_files < <(find themes -maxdepth 1 -type f -name '*.lua' | sort)
    elif [[ "$file" == "tools/computer.lua" ]]; then
      bundled_files=(scripts/computer_atspi.py)
    fi
    if [[ ${#bundled_files[@]} -gt 0 ]]; then
      printf ', "files": [' >> "$out"
      bundle_first=1
      for bundled in "${bundled_files[@]}"; do
        bundled_sha=$(sha256sum "$bundled" | cut -d' ' -f1)
        if [[ $bundle_first -eq 0 ]]; then printf ', ' >> "$out"; fi
        bundle_first=0
        printf '{ "path": "%s", "sha256": "%s" }' \
          "$bundled" "$bundled_sha" >> "$out"
      done
      printf ']' >> "$out"
    fi
    printf ' }' >> "$out"
  done
done
echo "" >> "$out"
echo "]" >> "$out"

mv "$out" "catalog.json"
echo "wrote catalog.json"
