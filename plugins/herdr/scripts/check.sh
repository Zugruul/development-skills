#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# check.sh -- am I inside Herdr, and which pane am I.
# Usage: check.sh
# Prints: HERDR OK version=V workspace=W tab=T pane=P name=N
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"

[ $# -eq 0 ] || usage "check.sh"
require_herdr
herdr_call --version
version="unknown"
[ "$HC_RC" -eq 0 ] && version="${HC_OUT#herdr }"
name="-"
if [ -n "${HERDR_PANE_ID:-}" ] && agent_get "$HERDR_PANE_ID"; then
    n="$(af name)"
    [ -n "$n" ] && name="$n"
fi
printf 'HERDR OK version=%s workspace=%s tab=%s pane=%s name=%s\n' \
    "$version" "${HERDR_WORKSPACE_ID:-?}" "${HERDR_TAB_ID:-?}" "${HERDR_PANE_ID:-?}" "$name"
