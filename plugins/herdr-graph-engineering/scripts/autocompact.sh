#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# autocompact.sh -- make the orchestrator's chat compact automatically at 40% of its context.
# Usage: autocompact.sh [print] [--pct N] [--window TOKENS] [--dir DIR] [--write]
#        autocompact.sh check [--pct N]
#   print (default)  how to turn it on for Claude Code, Codex and OpenCode; changes nothing
#   --write          Claude Code only: set env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE in
#                    DIR/.claude/settings.local.json (DIR: --dir, else the current folder), a
#                    backup first; never the home folder (that would be the global settings)
#   check            in the running chat: is Claude Code set to compact at N% or earlier
#   --pct N          the share of the context, 1 to 100, default 40
#   --window TOKENS  Codex's context window, to turn the share into its token limit (default 400000)
# Exit codes: 0 ok (check: on), 1 off, unknown or not written, 2 usage.
# A plugin cannot set this itself: Claude Code reads the variable from its environment or a
# settings file's env, and plugins ship neither. Scope it to the orchestrator: launch only that
# chat with the variable, or write the local settings of the folder only the orchestrator starts in.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="autocompact.sh [print] [--pct N] [--window TOKENS] [--dir DIR] [--write] | check [--pct N]"
VAR=CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
cmd="" pct=40 window=400000 dir="" write=0
while [ $# -gt 0 ]; do
    case "$1" in
        print | check) [ -z "$cmd" ] || usage "$USAGE"; cmd="$1"; shift ;;
        --pct) need_value "$1" $#; pct="$2"; shift 2 ;;
        --window) need_value "$1" $#; window="$2"; shift 2 ;;
        --dir) need_value "$1" $#; dir="$2"; shift 2 ;;
        --write) write=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
cmd="${cmd:-print}"
case "$pct" in '' | *[!0-9]*) die "--pct must be a whole number from 1 to 100" 2 ;; esac
[ "$pct" -ge 1 ] && [ "$pct" -le 100 ] || die "--pct must be a whole number from 1 to 100" 2
case "$window" in '' | *[!0-9]*) die "--window must be a number of tokens" 2 ;; esac
[ "$cmd" = print ] || [ "$write" -eq 0 ] || usage "$USAGE"

if [ "$cmd" = check ]; then
    if [ -z "${CLAUDECODE:-}" ]; then
        echo "AUTOCOMPACT UNKNOWN: not a Claude Code chat. Codex and OpenCode: see bash $HERE/autocompact.sh print"
        exit 1
    fi
    for v in DISABLE_AUTO_COMPACT DISABLE_COMPACT; do
        if [ -n "${!v:-}" ] && [ "${!v}" != 0 ] && [ "${!v}" != false ]; then
            echo "AUTOCOMPACT OFF: $v is set, so this chat never compacts by itself"
            exit 1
        fi
    done
    cur="${!VAR:-}"
    case "$cur" in '' | *[!0-9.]*) cur="" ;; esac
    if [ -n "$cur" ] && awk -v c="$cur" -v p="$pct" 'BEGIN { exit !(c > 0 && c <= p) }'; then
        echo "AUTOCOMPACT ON $cur%: this chat compacts by itself at $cur% of its auto-compact window"
        exit 0
    fi
    echo "AUTOCOMPACT OFF: ${cur:+$VAR is $cur, not $pct or lower; }this chat does not compact at $pct%. Start it with $VAR=$pct (bash $HERE/autocompact.sh print shows how)"
    exit 1
fi

[ -n "$dir" ] || dir="$(pwd)"
[ -d "$dir" ] || die "no such folder: $dir" 2
dir="$(cd "$dir" && pwd)"
settings="$dir/.claude/settings.local.json"

if [ "$write" -eq 1 ]; then
    require_tools jq
    home="$(cd "$HOME" 2>/dev/null && pwd -P)"
    [ "$(cd "$dir" && pwd -P)" != "$home" ] || die "refusing $settings: in the home folder this is the global Claude Code settings; pick the folder the orchestrator starts in (--dir), nothing was changed"
    cur='{}'
    if [ -s "$settings" ]; then
        cur="$(jq -c . "$settings" 2>/dev/null)" && [ "$(jq -r type <<<"$cur")" = object ] ||
            die "cannot read $settings as a JSON object; fix it first, nothing was changed"
    fi
    if [ "$(jq -r --arg v "$VAR" '.env[$v] // ""' <<<"$cur")" = "$pct" ]; then
        echo "ALREADY SET $VAR=$pct in $settings"
        exit 0
    fi
    mkdir -p "$dir/.claude" || die "cannot create $dir/.claude"
    bak=""
    if [ -e "$settings" ]; then
        bak="$settings.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$settings" "$bak" || die "cannot back up $settings, nothing was changed"
    fi
    tmp="$(mktemp "$settings.XXXXXX")" || die "cannot write in $dir/.claude"
    if ! { jq --arg v "$VAR" --arg p "$pct" '.env = ((.env // {}) + {($v): $p})' <<<"$cur" >"$tmp" && mv "$tmp" "$settings"; }; then
        rm -f "$tmp"
        die "cannot write $settings"
    fi
    echo "SETTINGS WRITTEN $VAR=$pct in $settings${bak:+ (backup: $bak)}"
    echo "It applies to Claude Code chats started in $dir from the next start on (restart the orchestrator there); lane agents start in their own worktrees and keep the default."
    git -C "$dir" check-ignore -q "$settings" 2>/dev/null ||
        echo "Note: $settings is not ignored by git here; keep it out of commits."
    exit 0
fi

limit=$((window * pct / 100))
keep=$((100 - pct))
cat <<EOF
Compact the orchestrator's chat by itself at $pct% of its context. Only the orchestrator: lane agents keep the default.

Claude Code (documented: $VAR, "the percentage (1-100) of the auto-compact window at which auto-compaction triggers"; it can only lower the threshold)
  Start the orchestrator with it:
    $VAR=$pct claude
  or put it in the local settings of the folder only the orchestrator starts in, $settings:
    { "env": { "$VAR": "$pct" } }
  To write that file (a backup first; never the global ~/.claude settings):
    bash $HERE/autocompact.sh print --pct $pct --dir $dir --write
  Then check in the chat: bash $HERE/autocompact.sh check --pct $pct
  The plugin's PreCompact and SessionStart(compact) hooks run on an automatic compaction too: the resume block comes back by itself.

Codex (config.toml takes a token count, not a share: $pct% of a $window-token window)
    codex -c model_auto_compact_token_limit=$limit
  Use --window with your model's context window. After it compacts, run resume.sh (no hook here).

OpenCode (opencode.json: "buffer" is the share of the context window kept free before automatic compaction)
    { "compaction": { "auto": true, "buffer": "$keep%" } }
  Put it in the opencode.json of the folder the orchestrator starts in. After it compacts, run resume.sh (no hook here).
EOF
