#!/usr/bin/env bash
# Host-neutral, read-only admission check. No flag => silent success.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/checkpoint.py" "$@"
