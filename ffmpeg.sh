#!/usr/bin/env bash
# Standalone nvenc build entry point; the full implementation lives in scripts/.
set -Eeuo pipefail
BUNDLE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ROOT="${ROOT:-$BUNDLE_ROOT}"
exec "$BUNDLE_ROOT/scripts/build/nvenc.sh" "$@"
