#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# name.sh -- is NAME a valid agent name that no live agent uses.
# Usage: name.sh NAME
# Prints NAME OK NAME, or exits 6 with NAME INVALID / NAME TAKEN and a free alternative.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"
# shellcheck source=src/names.sh
. "$HERE/src/names.sh"

[ $# -eq 1 ] || usage "name.sh NAME"
require_herdr
name_problem "$1"
[ -z "$NAME_PROBLEM" ] || die "$NAME_PROBLEM" 6
printf 'NAME OK %s\n' "$1"
