#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# label.sh -- the hyphen-separated, no-space form of a workspace label. Offline.
# Usage: label.sh TEXT...
# Prints LABEL <label>, or exits 6 when nothing usable is left.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/names.sh
. "$HERE/src/names.sh"

[ $# -ge 1 ] || usage "label.sh TEXT..."
label_from "$*"
out="$LABEL_TEXT"
label_problem "$out"
[ -z "$LABEL_PROBLEM" ] || die "$LABEL_PROBLEM" 6
printf 'LABEL %s\n' "$out"
