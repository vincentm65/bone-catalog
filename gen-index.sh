#!/usr/bin/env bash
# Regenerate the main Bone 3 catalog. The old generator is in legacy/.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 gen-index.py "$@"
