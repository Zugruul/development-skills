#!/usr/bin/env bash
# guard-board-move.sh — PreToolUse(Bash) hook: block `board.sh move <n> "In review"`
# unless gate.sh recorded a pass for the CURRENT tree state. Exit 2 = block (stderr
# goes back to the model); exit 0 = allow. Must stay fast — it runs on every Bash call.
#
# Parsing: the command string is tokenized with Python's stdlib shlex, then every
# `board.sh` argv token is located and its real argv[1] (subcommand) and argv[3]
# (target status) are read at their actual positions. Only an actual `move`
# invocation whose target status is the review-gate status can block; a status
# name appearing anywhere else — comment bodies, gh issue text, heredocs, other
# arguments — never trips the guard, and non-`move` subcommands always pass.
# Compound commands (`A && B`) are handled naturally: shlex still tokenizes the
# whole line, so the board.sh segment's argv is found regardless of what's
# before or after it.
#
# Shell-interpreter wrapping (`bash -c "board.sh move ..."`, `sh -c '...'`,
# an `env`-prefixed variant, or nested `bash -c 'bash -c "..."'`) would hide
# the real argv inside a single opaque token if we only scanned once — that
# was a silent gate bypass. So when a bash/sh/zsh/dash/ksh token is followed
# by a `-c`-ish flag (including combined clusters like `-lc`), the next token
# is treated as an inner command line and re-tokenized recursively (bounded
# depth; deeper nesting fails closed as unparseable, same as a raw unbalanced
# quote would).
#
# Fail-closed exception: if shlex can't tokenize a command/sub-command (e.g. an
# unbalanced quote) AND the raw text still contains both "board.sh" and "move",
# we can't prove it's safe, so we block with a distinct message rather than
# risk letting a real move through unparsed.
#
# #444: heredoc BODIES (issue-comment text posted via `board.sh comment <n>
# <<'EOF' ...`, a file being written that happens to quote this very guard's
# own doc comments, etc.) are DATA, never the command being run -- but shlex
# has no concept of heredoc syntax at all. Left unstripped, a heredoc body
# either (a) contains some unrelated quote character in ordinary prose (one
# apostrophe is enough) that shlex reads as a real quote-start/end and then
# raises on, hitting the fail-closed substring check below against text that
# still contains "board.sh"/"move" only because the BODY happens to mention
# them -- or (b) tokenizes "successfully" straight through the body as if it
# were more shell syntax, and a body that happens to contain the literal
# words board.sh/move/a status name in sequence can then match the real
# board.sh-move-status pattern for real (exactly what happens editing this
# file itself, whose own comments say precisely that). Every heredoc's body
# is stripped out before ANY parsing (both the tokenizer and the substring
# check below) for exactly this reason -- the guard decides from the command
# surface (the heredoc's own introducer line, e.g. `board.sh comment 42
# <<'EOF'`, is untouched and still evaluated on its own merits), never from
# what is piped/quoted/heredoc'd into it.
#
# #272/#423 (methodology.serialDelivery, defense in depth): a `board.sh move
# <n> "In progress"` is ALSO intercepted below when the config has
# serialDelivery on. #423 made this COUNT-based (slots, not a hard "nothing
# else in flight" rule): a slot is occupied from PICK until MERGE (both In
# progress AND In review count), methodology.maxInProgress is the number of
# slots, and the move is blocked only when the OTHER occupying issues
# (offline .claude/board-cache.json, issue #78 — no network call) already
# fill every slot — i.e. there is no headroom left. At maxInProgress: 1 this
# collapses to the original #272 rule (any other In progress/In review
# occupant blocks). Deliberately fail OPEN (allow, with a stderr warning)
# when the cache is missing/unreadable: a cache-consistency problem must
# never wedge the build loop the way a real network outage would if this
# were gate-checked instead. SERIAL_DELIVERY_OVERRIDE=1 bypasses the block
# outright (documented escape hatch for an intentional manual override).
set -uo pipefail

# shellcheck disable=SC2016  # this is Python source in single quotes, not a
# shell expansion.
RESULT="$(python3 -c '
import json, re, shlex, sys

REVIEW_STATUS = "in review"
PROGRESS_STATUS = "in progress"
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh"}
MAX_DEPTH = 5

def norm(s):
    return re.sub(r"\s+", " ", s.strip().lower())

# #444/round-2 review: the FIRST version of this stripper was a regex over
# RAW text with no notion of quoting, and that let a heredoc-shaped
# construct hide a REAL command. Four confirmed bypasses: (1) a fake
# introducer inside a quoted string -- echo "harmless <<EOF" followed by
# a genuine board.sh move 5 "In review" on the next line, then EOF --
# matched because the old regex is quote-blind, so the real move was
# swallowed as fake "body" and never reached the tokenizer at all;
# (2) the same shape joined with && on one line; (3) the <<- +
# tab-indented-terminator variant of the same trick; (4) echo $((1 << 3))
# -- arithmetic left-shift, not a redirection at all -- read as a fake
# introducer.
#
# WORSE: because the substring fail-closed check below runs on the
# STRIPPED text (by design -- a heredoc body must not smuggle a false
# "unparseable" block either, see the #444 header comment), a construct
# that LOOKS heredoc-shaped could eat the evidence needed for that safety
# net too, turning a should-stay-ambiguous command into a silent allow.
#
# Fix: a real, single-pass, quote-aware scanner (below), not a regex over
# raw text. It tracks single-quote/double-quote/backslash state exactly
# like a shell would, and only ever treats << / <<- as a heredoc
# introducer:
#   (a) at an UNQUOTED position (inside a quoted string, or right after
#       a backslash escape, it is just two ordinary characters, never
#       recognized); AND
#   (b) when the delimiter itself is QUOTED (<< then a quote character, optionally with -). Every real usage
#       in this codebase quotes its delimiter (it is the documented
#       pattern -- see board.sh comment <n>, a quoted delimiter, ...) specifically to
#       suppress expansion, so requiring it costs nothing real. It ALSO
#       closes the arithmetic false positive on its own, with no
#       separate ((...))-depth tracking needed: 1 << 3 is never
#       followed by a quote character, so it never qualifies as an
#       introducer in the first place -- and it PRESERVES fail-closed
#       behavior for a heredoc-SHAPED-but-unquoted construct like
#       foo <<Z / board.sh move 5 "In review / Z: since Z is not
#       quoted, nothing is stripped, the raw text still has its
#       genuinely unbalanced quote, shlex still raises, and the
#       existing substring check still fires (BLOCKED), exactly as if
#       no heredoc-shaped wrapper were present at all.
# Terminator matching follows the real bash rule, not a loose
# approximation: for plain <<DELIM the terminator line must be the
# delimiter ALONE at column 0 (no leading whitespace at all); for
# <<-DELIM any number of LEADING TABS (never spaces) are allowed before
# the delimiter. Either way the match is exact -- no trailing
# characters on that line either -- so a body line that merely
# CONTAINS the delimiter word amid other text is never mistaken for
# the real terminator. Empty bodies (terminator on the very next line)
# and multiple heredocs stacked on one introducer line (cmd <<A <<B,
# bodies consumed in order) are both handled directly by the scan, not
# as special cases.
#
# STRUCTURAL INVARIANT (round-2 review, worth stating explicitly): stripping
# only ever removes text starting AFTER the newline that ends the introducer
# line, never before it. A real command on the introducer line itself
# -- board.sh move sharing a line with a heredoc via && or ; -- can
# therefore never be swallowed as fake body, by construction, independent
# of anything else this scanner does or does not get right.
#
# KNOWN LIMITATION (round-2 review, fail-SAFE direction, not fixed here): a
# CRLF heredoc body never strips, because the exact terminator-line compare
# sees a trailing carriage return that a bare bash heredoc terminator does
# not have, so it never matches. This makes the scanner UNDER-strip (treat
# a real CRLF heredoc as unrecognized, leaving its body exposed to the
# normal shlex-based checks below) rather than over-strip -- the same
# posture as an unquoted delimiter, and the same reasoning: under-stripping
# can only ever produce an extra BLOCK, never let a real move through.
_SQ = chr(39)
_DQ = chr(34)


def strip_heredocs(command):
    out = []
    i = 0
    n = len(command)
    in_squote = False
    in_dquote = False
    escape = False
    pending = []  # [(delimiter, strip_leading_tabs), ...] queued on this line

    def find_terminator(start, delim, strip_tabs):
        j = start
        while True:
            k = j
            if strip_tabs:
                while k < n and command[k] == "\t":
                    k += 1
            eol = command.find("\n", k)
            line_end = eol if eol != -1 else n
            if command[k:line_end] == delim:
                return (eol + 1) if eol != -1 else n
            if eol == -1:
                return None  # no terminator anywhere -- do not strip
            j = eol + 1

    while i < n:
        c = command[i]

        if escape:
            out.append(c)
            i += 1
            escape = False
            continue

        if in_squote:
            out.append(c)
            if c == _SQ:
                in_squote = False
            i += 1
            continue

        if in_dquote:
            out.append(c)
            if c == chr(92):
                escape = True
            elif c == _DQ:
                in_dquote = False
            i += 1
            continue

        # unquoted (normal) mode
        if c == chr(92):
            out.append(c)
            escape = True
            i += 1
            continue
        if c == _SQ:
            out.append(c)
            in_squote = True
            i += 1
            continue
        if c == _DQ:
            out.append(c)
            in_dquote = True
            i += 1
            continue
        if c == "<" and i + 1 < n and command[i + 1] == "<":
            k = i + 2
            strip_tabs = False
            if k < n and command[k] == "-":
                strip_tabs = True
                k += 1
            while k < n and command[k] in " \t":
                k += 1
            if k < n and command[k] in (_SQ, _DQ):
                q = command[k]
                close = command.find(q, k + 1)
                if close != -1:
                    delim = command[k + 1:close]
                    end = close + 1
                    pending.append((delim, strip_tabs))
                    out.append(command[i:end])
                    i = end
                    continue
            # unquoted delimiter (or an unterminated quote) -- not a
            # recognized introducer; fall through as an ordinary "<".
            out.append(c)
            i += 1
            continue
        if c == "\n" and pending:
            out.append(c)
            i += 1
            for delim, strip_tabs in pending:
                end = find_terminator(i, delim, strip_tabs)
                if end is not None:
                    i = end
            pending = []
            continue
        out.append(c)
        i += 1

    return "".join(out)

def is_c_flag(tok):
    return (
        tok.startswith("-")
        and not tok.startswith("--")
        and len(tok) > 1
        and tok[1:].isalpha()
        and "c" in tok[1:]
    )

# #272 review round 1 MUST FIX #3: evaluate() used to return on the FIRST
# board.sh match found, so a compound command whose first segment was a
# review-move (e.g. `move 5 "In review" && move 7 "In progress"`) never even
# looked at the second segment -- an unrelated review-move earlier on the
# line silently shadowed the progress-move check for its own serial-delivery status.
# Collect EVERY match instead (review-move can repeat, progress-move can
# repeat with different issue numbers) and let the caller act on all of
# them. "unparseable" still short-circuits immediately -- if any part of the
# command cannot be proven safe, nothing else about it can be trusted either.
def evaluate(command, depth):
    if depth > MAX_DEPTH:
        return ["unparseable"]
    command = strip_heredocs(command)
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        if "board.sh" in command and "move" in command:
            return ["unparseable"]
        return []

    results = []
    i, n = 0, len(tokens)
    while i < n:
        base = tokens[i].rsplit("/", 1)[-1]
        if base in INTERPRETERS and i + 2 < n and is_c_flag(tokens[i + 1]):
            sub = evaluate(tokens[i + 2], depth + 1)
            if "unparseable" in sub:
                return ["unparseable"]
            results.extend(sub)
            i += 3
            continue
        if base == "board.sh" and i + 3 < n:
            subcmd, num, status = tokens[i + 1], tokens[i + 2], tokens[i + 3]
            if subcmd == "move" and norm(status) == REVIEW_STATUS:
                results.append("review-move:" + num)
            elif subcmd == "move" and norm(status) == PROGRESS_STATUS:
                results.append("progress-move:" + num)
        i += 1
    return results

try:
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    command = ""

matches = evaluate(command, 0)
if "unparseable" in matches:
    print("unparseable")
elif matches:
    for m in matches:
        print(m)
else:
    print("allow")
' 2>/dev/null)" || exit 0

if [[ -z "$RESULT" || "$RESULT" == "allow" ]]; then
    exit 0
fi
if [[ "$RESULT" == "unparseable" ]]; then
    echo "BLOCKED: could not safely parse this command to confirm it isn't a move to 'In review'. Simplify it (avoid nesting board.sh inside quotes/heredocs) and retry." >&2
    exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
# #463: PRIMARY repo root -- board-cache.json (serial-delivery slot check)
# and project.yaml are shared loop state; this hook fires with whatever cwd
# the PreToolUse Bash command happened to run from, worktree or main.
ROOT="$(spec_workflow_repo_root)" || exit 0

_serial_check() { # $1=issue-number-being-moved to "In progress" -> "allow"/"override"/"fail-open"/"block:..."
    PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" python3 -c '
import json, os, sys
import config as C

root, num = sys.argv[1], sys.argv[2]
cfg = C.load_config(root=root, warn=False) or {}
if not bool((cfg.get("methodology") or {}).get("serialDelivery", False)):
    print("allow")
    sys.exit(0)
if os.environ.get("SERIAL_DELIVERY_OVERRIDE") == "1":
    print("override")
    sys.exit(0)

cache_path = os.environ.get("BOARD_CACHE_FILE") or os.path.join(root, ".claude", "board-cache.json")
try:
    with open(cache_path) as f:
        cache = json.load(f)
except Exception:
    print("fail-open")
    sys.exit(0)

boards = cfg.get("boards") or []
flow = (boards[0].get("statusFlow") if boards else None) or ["Backlog", "In progress", "In review"]
blocking = set(flow[1:3])

# #423: slot-count semantics -- a slot is occupied from PICK until MERGE
# (both In progress AND In review count), and maxInProgress is the number of
# slots, not a hard "nothing else may be in flight" rule. The item being
# moved (num) is excluded from the count: it does not yet occupy a slot
# (still Backlog/whatever today, moving TO In progress), and a re-move of
# the SAME issue must never self-block (#272 review round 1 MUST FIX #4,
# generalized). Block only when the OTHER occupying items already fill every
# slot -- i.e. there is no headroom left for this one.
max_wip = int((cfg.get("methodology") or {}).get("maxInProgress", 1) or 1)

blockers = [
    (n, e.get("status", ""))
    for n, e in cache.items()
    if n != num and isinstance(e, dict) and e.get("status", "") in blocking
]
if len(blockers) >= max_wip:
    print("block:" + ";".join(f"#{n} is {s}" for n, s in blockers))
else:
    print("allow")
' "$ROOT" "$1" 2>/dev/null
}

# Every match found anywhere in the (possibly compound) command is evaluated
# on its own merits: EACH progress-move gets its own serial check (a block
# on any one of them blocks the whole command), and a review-move anywhere
# on the line still routes through gate-preflight below.
HAS_REVIEW=0
REVIEW_NUMS=()
while IFS= read -r LINE; do
    case "$LINE" in
        review-move:*)
            HAS_REVIEW=1
            REVIEW_NUMS+=("${LINE#review-move:}")
            ;;
        progress-move:*)
            NUM="${LINE#progress-move:}"
            SERIAL="$(_serial_check "$NUM")" || SERIAL="fail-open"
            case "$SERIAL" in
                allow|override) ;;
                fail-open)
                    echo "WARNING: serialDelivery is on but .claude/board-cache.json is missing/unreadable -- cannot confirm no other task is In progress/In review. Allowing the move (fail-open: an offline-cache problem must never wedge the loop)." >&2
                    ;;
                block:*)
                    echo "BLOCKED: serial delivery mode (methodology.serialDelivery) — ${SERIAL#block:} — merge it before moving #$NUM to In progress. Override with SERIAL_DELIVERY_OVERRIDE=1 if this is intentional." >&2
                    exit 2
                    ;;
            esac
            ;;
    esac
done <<<"$RESULT"

if [[ "$HAS_REVIEW" -eq 1 ]]; then
    # CDX-030: delegate to the shared, hook-independent preflight -- single
    # source of truth for "is the gate green for this tree" (docs/design/cdx-E3.md
    # Decisions). Defense in depth: this hook still intercepts before board.sh
    # even starts, but the actual marker+fingerprint check lives in one place.
    bash "$HERE/gate-preflight.sh" || exit $?
    # #461 (team-lead round-2 review item 1): same defense-in-depth
    # relationship as gate-preflight.sh above -- board-queue.sh's _do_move
    # is the actual single source of truth (it runs for every entrypoint,
    # including flush replay and Codex, which have no hook-equivalent
    # lifecycle event at all); this hook is the fast, Claude-specific layer
    # on top of it. One check per review-move number found on the line (a
    # compound command can move more than one issue to In review).
    for NUM in "${REVIEW_NUMS[@]}"; do
        bash "$HERE/design-registry-preflight.sh" --root "$ROOT" --issue "$NUM" || exit $?
    done
    exit 0
fi

exit 0
