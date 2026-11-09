#!/usr/bin/env bash
# Regenerate the Bone 3 catalog.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 gen-index.py "$@"
