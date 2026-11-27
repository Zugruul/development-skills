#!/usr/bin/env bash
# Read-only startup decision for the actual checkout: clean=0, dirty=1, unknown=2.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/checkout_preflight.py" "$@"
