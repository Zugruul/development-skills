#!/usr/bin/env bash
# board-ensure-issue.sh -- "issue first": every orchestrator PR has a board issue (#565).
# Called by board.sh: board-ensure-issue.sh <owner/repo> <config> --title T [--for-branch B] [--body-file F] [--prio P]
#
# Prints the issue number to use on stdout (nothing else) and a human line on stderr.
# Lookup order, REST only (never GraphQL, never a full-board read):
#   (a) --for-branch B matches project.branchPattern -> GET repos/R/issues/<id>            (1 call)
#       exists -> <id> (a closed one is reused with a warning; a pull request id is rejected;
#       a non-404 failure trusts the id with a warning, so a flaky network never makes a duplicate)
#   (b) GET repos/R/pulls -f head=<owner>:B -f state=open (gh URL-encodes it)               (1 call)
#       a body (outside fenced code) with Closes/Fixes/Resolves #N, or <repo-name>#N -> N.
#       The found N is NOT re-checked as an issue (that would cost one more call per hit).
#   (c) otherwise create via `board.sh add --type inbound` (its existing cost and rate-limit
#       queue), then ONE REST PATCH sets a truthful body (--body-file, else a default line).
# Never stops work: if nothing can be created it says what to do next on stderr, prints nothing,
# exits 0. A queued add (rate limit) still prints the number of the issue that was created.
# Only invalid arguments exit 2 (an unreadable config just warns and carries on).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"

usage() { echo "usage: board.sh ensure-issue --title \"<title>\" [--for-branch <branch>] [--body-file F] [--prio P2]" >&2; exit 2; }
[[ $# -ge 2 ]] || usage
REPO="$1"; CONFIG="$2"; shift 2
TITLE=""; BRANCH=""; BODY_FILE=""; PRIO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --title) [[ $# -ge 2 ]] || usage; TITLE="$2"; shift 2 ;;
        --for-branch) [[ $# -ge 2 ]] || usage; BRANCH="$2"; shift 2 ;;
        --body-file) [[ $# -ge 2 ]] || usage; BODY_FILE="$2"; shift 2 ;;
        --prio) [[ $# -ge 2 ]] || usage; PRIO="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n "$TITLE" ]] || usage
if [[ "$TITLE" == *$'\n'* ]]; then echo "ERROR: --title must be a single line" >&2; exit 2; fi
OWNER="${REPO%%/*}"; REPO_NAME="${REPO##*/}"

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
ERRF="$TMPD/err"; OUTF="$TMPD/out"

# One config read (no gh call): branch pattern + the board's configured priorities.
CFG_OUT="$(python3 - "$CONFIG" "${BOARD:-}" 2>"$ERRF" <<'PY'
import sys
import config as C
cfg = C.load_config(path=sys.argv[1], warn=False)
boards = cfg.get("boards") or []
b = next((x for x in boards if x["id"] == sys.argv[2]), boards[0] if boards else {})
print(((cfg.get("project") or {}).get("branchPattern")) or "")
print(" ".join(((b.get("fields") or {}).get("priority") or {}).get("options") or {}))
PY
)" || {
    # Never stop work: without a config there is no pattern or priority list to check; carry on.
    echo "ensure-issue: WARN: could not read the board config ($(tail -n 1 "$ERRF" | head -c 200)); skipping the branch-pattern and priority checks" >&2
    CFG_OUT=""
}
PATTERN="$(sed -n 1p <<<"$CFG_OUT")"; PRIOS="$(sed -n 2p <<<"$CFG_OUT")"
if [[ -n "$PRIO" ]]; then
    if [[ -n "$PRIOS" ]]; then
        case " $PRIOS " in
            *" $PRIO "*) ;;
            *) echo "ERROR: --prio '$PRIO' is not a configured priority (valid: $PRIOS)" >&2; exit 2 ;;
        esac
    fi
elif [[ -n "$PRIOS" ]]; then
    case " $PRIOS " in
        *" P2 "*) PRIO="P2" ;;
        *)  # P2 is not configured: take the middle option and say so
            read -r -a _opts <<<"$PRIOS"
            PRIO="${_opts[$(( ${#_opts[@]} / 2 ))]}"
            echo "ensure-issue: P2 is not configured; using $PRIO" >&2 ;;
    esac
fi

_found() { echo "ensure-issue: using existing issue #$1 ($2)" >&2; echo "$1"; exit 0; }

if [[ -n "$BRANCH" ]]; then
    id="$(python3 -c '
import re, sys
pat, br = sys.argv[1], sys.argv[2]
if not pat:
    sys.exit(0)
rx = re.escape(pat).replace(re.escape("<id>"), r"(?P<id>\d+)").replace(re.escape("<slug>"), r"[A-Za-z0-9._-]+")
m = re.fullmatch(rx, br)
print(m.group("id") if m and "id" in m.groupdict() else "")
' "$PATTERN" "$BRANCH" 2>"$ERRF")"
    if [[ -n "$id" ]]; then
        if gh api "repos/$REPO/issues/$id" >"$OUTF" 2>"$ERRF"; then
            kind="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
print("pr" if "pull_request" in d else d.get("state", "open"))
' <"$OUTF" 2>"$TMPD/pyerr")" || kind="unreadable"
            case "$kind" in
                pr) echo "ensure-issue: #$id from branch $BRANCH is a pull request, not an issue; looking further" >&2 ;;
                closed) echo "ensure-issue: WARN: issue #$id is closed" >&2; _found "$id" "branch $BRANCH" ;;
                unreadable) echo "ensure-issue: WARN: could not confirm #$id (unreadable reply); trusting the branch id" >&2; _found "$id" "branch $BRANCH" ;;
                *) _found "$id" "branch $BRANCH" ;;
            esac
        elif grep -qE 'HTTP 404|Not Found' "$ERRF"; then
            :  # that id does not exist: fall through to the PR lookup
        else
            echo "ensure-issue: WARN: could not confirm #$id ($(head -c 200 "$ERRF")); trusting the branch id rather than filing a duplicate" >&2
            _found "$id" "branch $BRANCH, unconfirmed"
        fi
    fi
    if gh api -X GET "repos/$REPO/pulls" -f "head=$OWNER:$BRANCH" -f state=open >"$OUTF" 2>"$ERRF"; then
        # shellcheck disable=SC2016  # Python source (backticks are the markdown fence), not shell
        n="$(python3 -c '
import json, re, sys
repo = re.escape(sys.argv[1])
close = re.compile(r"(?i)\b(?:close[sd]?|fix(?:e[sd]?)?|resolve[sd]?)\s+#(\d+)")
qual = re.compile(r"(?<![A-Za-z0-9_.-])" + repo + r"#(\d+)")
for pr in json.load(sys.stdin):
    body = re.sub(r"(?s)(```|~~~).*?\1", "", pr.get("body") or "")
    m = close.search(body) or qual.search(body)
    if m:
        print(m.group(1)); break
' "$REPO_NAME" <"$OUTF" 2>"$TMPD/pyerr")"
        [[ -n "$n" ]] && _found "$n" "open PR for $BRANCH references it"
    else
        echo "ensure-issue: PR lookup failed ($(head -c 200 "$ERRF")); creating an issue instead" >&2
    fi
fi

NEXT="Keep working: commit the branch (push it too under work.type pr), retry board.sh ensure-issue after the rate-limit reset, then open the PR with Closes #N."
add_out="$(bash "$HERE/board.sh" add --type inbound "$TITLE" "$PRIO" 2>&1)"; add_rc=$?
# Only add's own creation lines count -- anchored, never the title echoed in an error line.
num="$(grep -m1 -E '^(filed [a-z]+ #[0-9]+ \[|QUEUED .*item-add #[0-9]+|ERROR: issue #[0-9]+ (was created|is on the board)|DEFERRED .*add-finish #[0-9]+)' <<<"$add_out" | grep -Eo '#[0-9]+' | head -1 | tr -d '#')"
if [[ -z "$num" ]]; then
    echo "ensure-issue: no issue could be created for '$TITLE' ($(head -c 200 <<<"$add_out" | tr '\n' ' ')). $NEXT" >&2
    exit 0
fi
if grep -qE "^QUEUED .*item-add #${num}([^0-9]|\$)" <<<"$add_out"; then
    echo "ensure-issue: QUEUED - issue #$num exists; board placement is queued for after the rate limit" >&2
elif [[ $add_rc -ne 0 ]]; then
    echo "ensure-issue: issue #$num created but board placement failed: $(head -c 200 <<<"$add_out" | tr '\n' ' ')" >&2
else
    echo "ensure-issue: created issue #$num for '$TITLE'" >&2
fi
BODY_SRC="$TMPD/body"
if [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]]; then
    cp "$BODY_FILE" "$BODY_SRC"
else
    [[ -n "$BODY_FILE" ]] && echo "ensure-issue: WARN: --body-file '$BODY_FILE' not found; using the default body" >&2
    # code spans: no @mention notification, no #N cross-reference
    # shellcheck disable=SC2016  # literal backticks (markdown code span)
    _cs() { printf '`%s`' "${1//\`/\'}"; }
    printf 'Filed by board.sh ensure-issue for branch %s / title %s so the work has a board card.\n' "$(_cs "${BRANCH:-(none)}")" "$(_cs "$TITLE")" >"$BODY_SRC"
fi
gh api -X PATCH "repos/$REPO/issues/$num" -F "body=@$BODY_SRC" >/dev/null 2>"$ERRF" ||
    echo "ensure-issue: WARN: could not set the body of #$num: $(head -c 200 "$ERRF")" >&2
echo "$num"
