#!/usr/bin/env bash
# _audit-fix-lib.sh -- helpers for section-board-audit-fix.sh and section-board-truth-sim.sh (#564).
# Sourced by both sections; defines a fixture repo (real git), a mutable fake gh (fixtures/fake-gh-audit.py)
# and exact call counting. Not runnable standalone.
declare -F check >/dev/null 2>&1 || { echo "sourced by section files only" >&2; exit 2; }
# shellcheck disable=SC2034  # used by section-board-truth-sim.sh
AF_REPO="fixture-owner/fixture-project"

af_setup() { # [work-type] -> AQ (repo), FGH (fake gh dir); resets the call log and state
    AQ="$(mktemp -d)"
    mkdir -p "$AQ/.claude" "$AQ/.neural-network"
    cp "$FIX/valid.project.yaml" "$AQ/.neural-network/project.yaml"
    [[ "${1:-pr}" == "local" ]] && python3 "$PLUGIN/scripts/config.py" "$AQ" set work.type '"local"' >/dev/null
    # project.yaml is tracked, as in a real consumer repo, so every worktree has it (the In review
    # preflights read it from the worktree they run in).
    ( cd "$AQ" && git init -q . && git config user.email t@t && git config user.name t \
        && git add .neural-network/project.yaml && git commit -q -m "init #0" && git branch -m main )
    FGH="$(mktemp -d)"; ln -s "$FIX/fake-gh-audit.py" "$FGH/gh"
    export AF_STATE="$AQ/gh-state.json" AF_LOG="$AQ/gh.log" AF_PULLS_OPEN="$AQ/pulls-open.json" AF_PULLS_CLOSED="$AQ/pulls-closed.json"
    : >"$AF_LOG"; echo '[]' >"$AF_PULLS_OPEN"; echo '[]' >"$AF_PULLS_CLOSED"
    echo '{"items":[],"issues":[],"next":900}' >"$AF_STATE"
}
af_cfg() { python3 "$PLUGIN/scripts/config.py" "$AQ" set "$1" "$2" >/dev/null; } # key json-value
af_items() { # "N:Status" ... -> board cards
    python3 - "$AF_STATE" "$@" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
for spec in sys.argv[2:]:
    n, _, status = spec.partition(":")
    st["items"].append({"id": f"ITEM_{n}", "number": int(n), "status": status, "title": f"task {n}"})
json.dump(st, open(sys.argv[1], "w"))
PY
}
af_status() { # N -> current status on the fake board
    python3 -c 'import json,sys; print(next((i["status"] for i in json.load(open(sys.argv[1]))["items"] if i["number"]==int(sys.argv[2])), "MISSING"))' "$AF_STATE" "$1"
}
af_worktree() { ( cd "$AQ" && git worktree add -q ".claude/worktrees/$1" -b "$2" ); } # dir-name branch
af_seen() { # N... -> comments-read markers (board.sh show), required before an In progress move
    python3 - "$AQ/.claude/board-comments-seen.json" "$@" <<'PY'
import json, sys
json.dump({n: True for n in sys.argv[2:]}, open(sys.argv[1], "w"))
PY
}
af_review_evidence() { # N -> both review passes recorded
    local p
    for p in spec-compliance code-quality; do
        python3 "$PLUGIN/scripts/telemetry.py" "$AQ" record "{\"kind\":\"review-round\",\"task\":\"$1\",\"round\":1,\"verdict\":\"APPROVE\",\"ts\":\"2026-01-01T00:00:00Z\",\"pass\":\"$p\"}" >/dev/null
    done
}
af_accept() { # N -> a recorded user acceptance: lets the QA guard pass without being a review-in-progress signal
    python3 "$PLUGIN/scripts/telemetry.py" "$AQ" record "{\"kind\":\"user-acceptance\",\"task\":\"$1\",\"quote\":\"ok\",\"ts\":\"2026-01-01T00:00:00Z\"}" >/dev/null
}
af_gate_pass() { ( cd "$AQ/.claude/worktrees/$1" && bash "$PLUGIN/scripts/tree-state.sh" ) >"$AQ/.claude/gate-pass"; } # dir-name
af_run() { # board.sh args... -> "<combined output>\nrc=N" (run from the repo root, fake gh first on PATH)
    ( cd "$AQ" && PATH="$FGH:$PATH" bash "$PLUGIN/scripts/board.sh" "$@" 2>&1; echo "rc=$?" )
}
af_n() { grep -c "^$1" "$AF_LOG" | tr -d ' '; } # exact count of logged calls starting with a token
af_leaks() { if [[ -f "$AF_LOG.leak" ]]; then grep -c . "$AF_LOG.leak" | tr -d ' '; else echo 0; fi; } # gh calls that inherited the audit's trust variables
af_total() { grep -c . "$AF_LOG" | tr -d ' '; }
af_pr() { # number head-ref draft(true|false) merged(true|false) title body -> one REST pull object
    python3 -c 'import json,sys; n,h,d,m,t,b=sys.argv[1:7]; print(json.dumps({"number":int(n),"title":t,"body":b,"draft":d=="true","state":"closed" if m=="true" else "open","merged_at":"2026-01-01T00:00:00Z" if m=="true" else None,"head":{"ref":h}}))' "$@"
}
af_teardown() { rm -rf "$AQ" "$FGH"; unset AF_STATE AF_LOG AF_PULLS_OPEN AF_PULLS_CLOSED; }
