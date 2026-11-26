#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# kind.sh -- which agent kinds can run a role on this machine, and the arguments a kind needs.
# Usage: kind.sh --role R [--repo DIR] [--not KIND] [--without KIND]... [--access read|write]
#                [--session FILE] [--list | --kind KIND | --remember KIND]
# Installed kinds = the kinds `herdr agent start --help` supports whose executable is on PATH
# (only the role's own kinds when herdr does not list them). The recommended kind is the first
# installed kind of the role's `kind:` list that is not --not (so a reviewer differs from the
# implementer), else another installed kind that is not --not, else --not itself (same-model).
# --without leaves a kind out entirely (one that failed to start or work).
#   --list           CANDIDATE <kind> [recommended|same-kind]: <why>, recommended first, and the
#                    session's standing choice for the role: STANDING or STANDING-UNAVAILABLE.
#   --remember KIND  record KIND as the session's standing choice for the role, in --session.
#   --kind KIND      the user's choice; otherwise the standing choice, otherwise the recommended.
# Without --list or --remember it prints KIND, ARGS (for herdr agent start after --), ROLE and,
# for read access, GUARD; SAME-KIND when the kind is the --not kind.
# Read access: no kind gets a CLI read-only mode. Each kind's mode either blocks writing the
# report or draft outside the checkout, or blocks running tests (claude --disallowedTools Write,
# opencode --agent plan, codex --sandbox read-only), which the read roles require. The kind runs
# in its normal mode; the read-only rules are in the role's brief and the orchestrator's check
# that the checkout is unchanged is the guard (GUARD brief).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="kind.sh --role R [--repo DIR] [--not KIND] [--without KIND]... [--access read|write] [--session FILE] [--list | --kind KIND | --remember KIND]"
role="" repo="" not="" access="" without=" " session="" mode=pick choice=""
while [ $# -gt 0 ]; do
    case "$1" in
        --role) need_value "$1" $#; role="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --not) need_value "$1" $#; not="$2"; shift 2 ;;
        --without) need_value "$1" $#; without="$without$2 "; shift 2 ;;
        --access) need_value "$1" $#; access="$2"; shift 2 ;;
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --list) mode=list; shift ;;
        --kind) need_value "$1" $#; choice="$2"; shift 2 ;;
        --remember) need_value "$1" $#; mode=remember; choice="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$role" ] || usage "$USAGE"
[ "$mode" != remember ] || [ -n "$session" ] || die "--remember needs --session FILE" 2
require_tools jq yq
found="$(resolve roles "$role" "$repo")" || die "NO ROLE: $role" 6
rfile="${found%%	*}"
front="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$rfile" | yq -o=json '.')" || die "ROLE: $rfile has no valid frontmatter" 6
[ -n "$access" ] || access="$(printf '%s' "$front" | jq -r '.access // "write"')"
case "$access" in read | write) ;; *) die "--access must be read or write" 2 ;; esac
model="$(printf '%s' "$front" | jq -r '.model // empty')"
kinds="$(printf '%s' "$front" | jq -r '(.kind // ["claude"]) | if type == "array" then .[] else . end')"

# The kinds herdr supports, from `herdr agent start --help` ("[possible values: a, b, c]").
supported=""
if command -v herdr >/dev/null 2>&1; then
    supported="$(herdr agent start --help 2>/dev/null | sed -n 's/.*possible values: \([^]]*\)].*/\1/p' | head -1 | tr -d ' ' | tr ',' ' ')"
fi
note=""
[ -n "$supported" ] || note="NOTE herdr did not list its supported kinds; only the role's kinds ($(printf '%s' "$kinds" | tr '\n' ' ' | sed 's/ $//')) were checked"

installed() { # kind -> 0 when herdr supports it (or herdr gave no list) and it is on PATH
    case "$without" in *" $1 "*) return 1 ;; esac
    if [ -n "$supported" ]; then
        case " $supported " in *" $1 "*) ;; *) return 1 ;; esac
    fi
    command -v "$1" >/dev/null 2>&1
}

# Candidates, recommended first: role kinds that differ from --not, then other installed kinds
# that differ from --not, then --not itself. Each line: kind<TAB>tag<TAB>why.
candidates() {
    local k seen=" " rec=""
    add() { # kind tag why
        case "$seen" in *" $1 "*) return ;; esac
        seen="$seen$1 "
        local tag="$2"
        if [ -z "$rec" ] && [ "$tag" != same-kind ]; then rec="$1"; tag="recommended"; fi
        printf '%s\t%s\t%s\n' "$1" "$tag" "$3"
    }
    for k in $kinds; do
        [ "$k" != "$not" ] && installed "$k" && add "$k" "" "in the role's kind list${not:+, differs from the implementer ($not)}"
    done
    for k in $supported; do
        [ "$k" != "$not" ] && installed "$k" && add "$k" "" "installed, not in the role's kind list${not:+, differs from the implementer ($not)}"
    done
    if [ -n "$not" ] && installed "$not"; then
        if [ -z "$rec" ]; then
            add "$not" same-kind "the implementer's kind and the only one left; the review would be same-model"
        else
            add "$not" same-kind "the implementer's kind; the review would be same-model"
        fi
    fi
}

standing() { # -> the session's standing kind for the role, or nothing
    [ -n "$session" ] && [ -f "$session" ] || return 0
    awk -v r="$role" '$1 == r {k = $2} END {if (k != "") print k}' "$session"
}

list="$(candidates)"
if [ -z "$list" ]; then
    others="" left=""
    [ -z "$supported" ] || others=" nor any other kind herdr supports"
    [ "$without" = " " ] || left=" (left out:${without% })"
    die "NO KIND: none of the role's kinds ($(printf '%s' "$kinds" | tr '\n' ' ' | sed 's/ $//'))$others is installed$left" 6
fi

case "$mode" in
    list)
        printf '%s\n' "$list" | awk -F '\t' '{printf "CANDIDATE %s%s: %s\n", $1, ($2 == "" ? "" : " " $2), $3}'
        s="$(standing)"
        if [ -n "$s" ]; then
            if ! installed "$s"; then
                echo "STANDING-UNAVAILABLE $s: not installed or left out; ask again"
            elif [ "$s" = "$not" ]; then
                echo "STANDING-UNAVAILABLE $s: the implementer's kind; ask again"
            else
                echo "STANDING $s"
            fi
        fi
        [ -z "$note" ] || echo "$note"
        exit 0 ;;
    remember)
        installed "$choice" || die "NOT INSTALLED: $choice is not an installed kind herdr supports" 6
        mkdir -p "$(dirname "$session")"
        tmp="$(mktemp "$session.XXXXXX")" || die "could not write next to $session"
        { [ -f "$session" ] && awk -v r="$role" '$1 != r' "$session"; printf '%s %s\n' "$role" "$choice"; } >"$tmp" && mv "$tmp" "$session"
        printf 'STANDING %s %s\n' "$role" "$choice"
        exit 0 ;;
esac

if [ -n "$choice" ]; then
    installed "$choice" || die "NOT INSTALLED: $choice is not an installed kind herdr supports" 6
    pick="$choice"
else
    s="$(standing)"
    if [ -n "$s" ] && [ "$s" != "$not" ] && installed "$s"; then
        pick="$s"
    else
        pick="$(printf '%s\n' "$list" | head -1 | cut -f1)"
    fi
fi
[ -z "$not" ] || [ "$pick" != "$not" ] || echo "SAME-KIND: $pick is also the implementer's kind; the report must say this review was same-model"

args=""
if [ -n "$model" ]; then
    case "$pick" in
        claude) args="--model $model" ;;
        opencode | codex) args="-m $model" ;;
    esac
fi
printf 'KIND %s\nARGS %s\nROLE %s (%s)\n' "$pick" "$args" "$rfile" "${found##*	}"
[ "$access" != read ] || echo "GUARD brief: $pick runs in its normal mode; the role's read-only rules are in its brief, and the checkout must be unchanged after the node"
