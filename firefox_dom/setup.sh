#!/usr/bin/env bash
set -euo pipefail

# Independent identities; this script never escalates privileges and only removes files it owns.
HOST_ID='dev.bone.firefox_dom'
SOCKET_NAME='bone-firefox-dom.sock'
EXT_ID='firefox-dom@bone.local'
PACKAGE='bone-firefox-dom-0.1.0.zip'
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE="${XDG_CONFIG_HOME:-${HOME:?HOME is required}/.config}/bone-rust/firefox_dom"
ACTION=${1:-}
shift || true
if [[ "${1:-}" == '--state' ]]; then STATE=${2:?--state requires a directory}; shift 2; fi
[[ $# -eq 0 ]] || { echo 'usage: setup.sh setup|doctor|remove [--state DIR]' >&2; exit 2; }
case "$ACTION" in setup|doctor|remove) ;; *) echo 'usage: setup.sh setup|doctor|remove [--state DIR]' >&2; exit 2 ;; esac

case "$STATE" in ''|/|.|..|/tmp|/home) echo 'refusing unsafe state directory' >&2; exit 2;; esac
if [[ -L "$STATE" || ( -e "$STATE" && ! -d "$STATE" ) ]]; then echo 'refusing unsafe state directory' >&2; exit 2; fi
if [[ "$ACTION" != doctor && "$ACTION" != remove ]]; then mkdir -p -- "$STATE"; fi
[[ ! -e "$STATE" || ! -L "$STATE" ]] || { echo 'refusing unsafe state directory' >&2; exit 2; }
[[ ! -e "$STATE" || -d "$STATE" ]] || { echo 'refusing unsafe state directory' >&2; exit 2; }
[[ -d "$STATE" ]] && chmod 700 -- "$STATE"
HOST_DIR="${HOME:?HOME is required}/.mozilla/native-messaging-hosts"
HOST_FILE="$HOST_DIR/$HOST_ID.json"
MOZILLA_DIR="${HOME:?HOME is required}/.mozilla"
EXT_STATE="$STATE/extension"
SOCKET="$STATE/$SOCKET_NAME"
BRIDGE="$STATE/firefox-dom-bridge"
LAUNCHER="$STATE/firefox-dom-launcher"
PACKAGE_PATH="$STATE/$PACKAGE"
MANIFEST="$SCRIPT_DIR/extension/manifest.json"
BINARY_SOURCE="$SCRIPT_DIR/bridge/target/release/bone-firefox-dom-bridge"

if [[ "$ACTION" == doctor ]]; then
  printf 'firefox_dom identities:\n  native host: %s\n  launcher: %s\n  binary: %s\n  socket: %s\n  extension: %s\n  package: %s\n  state: %s\n' "$HOST_ID" "$LAUNCHER" "$BRIDGE" "$SOCKET" "$EXT_ID" "$PACKAGE_PATH" "$STATE"
  [[ -f "$HOST_FILE" && ! -L "$HOST_FILE" ]] && echo 'native host manifest: installed' || echo 'native host manifest: missing'
  [[ -f "$LAUNCHER" && ! -L "$LAUNCHER" && -x "$LAUNCHER" ]] && echo 'launcher: installed' || echo 'launcher: missing'
  [[ -f "$BRIDGE" && ! -L "$BRIDGE" && -x "$BRIDGE" ]] && echo 'bridge binary: installed' || echo 'bridge binary: missing'
  [[ -d "$EXT_STATE" && ! -L "$EXT_STATE" && -f "$EXT_STATE/manifest.json" ]] && echo 'extension state: present' || echo 'extension state: missing'
  [[ -f "$PACKAGE_PATH" && ! -L "$PACKAGE_PATH" ]] && echo 'extension package: present' || echo 'extension package: missing'
  [[ -S "$SOCKET" ]] && echo 'canonical socket: listening' || echo 'canonical socket: not listening'
  exit 0
fi

if [[ "$ACTION" == remove ]]; then
  [[ -L "$HOST_FILE" ]] && { echo 'refusing to remove symlinked native-host manifest' >&2; exit 1; }
  [[ -f "$HOST_FILE" ]] && rm -f -- "$HOST_FILE"
  if [[ -L "$EXT_STATE" ]]; then rm -f -- "$EXT_STATE"; elif [[ -d "$EXT_STATE" ]]; then rm -rf -- "$EXT_STATE"; fi
  for owned in "$BRIDGE" "$LAUNCHER" "$PACKAGE_PATH" "$SOCKET" "$STATE/identity" "$STATE/socket" "$STATE/extension-id" "$STATE/package"; do
    [[ -L "$owned" ]] && { echo "refusing to remove symlink: $owned" >&2; exit 1; }
    [[ -f "$owned" || -S "$owned" ]] && rm -f -- "$owned"
  done
  [[ -d "$STATE" && ! -L "$STATE" ]] && rmdir "$STATE" 2>/dev/null || true
  echo "Removed firefox_dom native host, extension state, package, launcher, binary, and socket ($HOST_ID)."
  exit 0
fi

[[ -f "$MANIFEST" ]] || { echo 'extension manifest not found' >&2; exit 1; }
[[ -d "$SCRIPT_DIR/bridge" && -f "$SCRIPT_DIR/bridge/Cargo.toml" ]] || { echo 'Rust bridge source not found' >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo 'cargo is required to build the Firefox DOM bridge' >&2; exit 1; }
cargo build --release --locked --manifest-path "$SCRIPT_DIR/bridge/Cargo.toml"
[[ -f "$BINARY_SOURCE" ]] || { echo 'built bridge binary not found' >&2; exit 1; }

if [[ -L "$MOZILLA_DIR" || ( -e "$MOZILLA_DIR" && ! -d "$MOZILLA_DIR" ) ]]; then echo 'refusing unsafe Firefox profile directory' >&2; exit 1; fi
if [[ -L "$HOST_DIR" || ( -e "$HOST_DIR" && ! -d "$HOST_DIR" ) ]]; then echo 'refusing unsafe native-host directory' >&2; exit 1; fi
mkdir -p -- "$HOST_DIR"
[[ -d "$HOST_DIR" && ! -L "$HOST_DIR" ]] || { echo 'refusing unsafe native-host directory' >&2; exit 1; }
if [[ -L "$HOST_FILE" || ( -e "$HOST_FILE" && ! -f "$HOST_FILE" ) ]]; then echo 'refusing unsafe native-host manifest target' >&2; exit 1; fi
chmod 700 -- "$HOST_DIR"
cp -- "$BINARY_SOURCE" "$BRIDGE"; chmod 700 -- "$BRIDGE"
launcher_tmp=''
manifest_tmp=''
package_tmp=''
quote_for_bash() { printf '%q' "$1"; }
q_socket=$(quote_for_bash "$SOCKET"); q_bridge=$(quote_for_bash "$BRIDGE")
launcher_tmp=$(mktemp "$STATE/.firefox-dom-launcher.tmp.XXXXXX")
trap 'rm -f -- "$launcher_tmp" "$manifest_tmp" "$package_tmp"' EXIT
chmod 700 -- "$launcher_tmp"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "export BONE_FIREFOX_DOM_SOCKET=$q_socket" "exec $q_bridge \"\$@\"" > "$launcher_tmp"
mv -- "$launcher_tmp" "$LAUNCHER"; launcher_tmp=''
manifest_tmp=$(mktemp "$HOST_DIR/.${HOST_ID}.json.tmp.XXXXXX"); chmod 600 -- "$manifest_tmp"
python3 - "$HOST_ID" "$LAUNCHER" "$EXT_ID" "$manifest_tmp" <<'PY'
import json, sys
host_id, launcher, extension_id, output = sys.argv[1:]
with open(output, 'w', encoding='utf-8') as f:
    json.dump({'name': host_id, 'description': 'Bone Firefox DOM bridge', 'path': launcher, 'type': 'stdio', 'allowed_extensions': [extension_id]}, f)
    f.write('\n')
PY
mv -- "$manifest_tmp" "$HOST_FILE"; manifest_tmp=''
if [[ -L "$EXT_STATE" || ( -e "$EXT_STATE" && ! -d "$EXT_STATE" ) ]]; then echo 'refusing unsafe extension state' >&2; exit 1; fi
rm -rf -- "$EXT_STATE"; mkdir -p -- "$EXT_STATE"; cp -R -- "$SCRIPT_DIR/extension/." "$EXT_STATE/"; chmod -R u=rwX,go= -- "$EXT_STATE"
package_tmp=$(mktemp "$STATE/.${PACKAGE}.tmp.XXXXXX"); chmod 600 -- "$package_tmp"
python3 - "$EXT_STATE" "$package_tmp" <<'PY'
import os, sys, zipfile
root, output = sys.argv[1:]
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
    for base, _, files in os.walk(root):
        for name in files:
            path = os.path.join(base, name)
            z.write(path, os.path.relpath(path, root))
PY
mv -- "$package_tmp" "$PACKAGE_PATH"; package_tmp=''; chmod 600 -- "$PACKAGE_PATH"
printf '%s\n' "$HOST_ID" > "$STATE/identity"; printf '%s\n' "$SOCKET_NAME" > "$STATE/socket"; printf '%s\n' "$EXT_ID" > "$STATE/extension-id"; printf '%s\n' "$PACKAGE" > "$STATE/package"; chmod 600 "$STATE"/identity "$STATE"/socket "$STATE"/extension-id "$STATE"/package
echo "Installed firefox_dom in $STATE. In Firefox, use about:addons > gear > Install Add-on From File to select $PACKAGE_PATH, or about:debugging > This Firefox > Load Temporary Add-on and select $EXT_STATE/manifest.json. Firefox profiles are not modified."

