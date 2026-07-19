#!/usr/bin/env bash
# section-neural-view-sessions.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view /sessions (best-effort local Claude session discovery) =="
NVS_CLAUDE="$(mktemp -d)"
NVS_JOBS="$NVS_CLAUDE/jobs"
mkdir -p "$NVS_JOBS/job-working" "$NVS_JOBS/job-recent-done" "$NVS_JOBS/job-stale-done" "$NVS_JOBS/job-unmatched-repo"
NVS_REPO="$(mktemp -d)"
mkdir -p "$NVS_REPO/.claude"
: >"$NVS_REPO/.claude/.neural-network"
cat >"$NVS_JOBS/job-working/state.json" <<EOF
{"state":"working","cwd":"$NVS_REPO","name":"messaging","createdAt":"2026-07-07T10:00:00Z","updatedAt":"2026-07-07T10:05:00Z"}
EOF
cat >"$NVS_JOBS/job-recent-done/state.json" <<EOF
{"state":"done","cwd":"$NVS_REPO/subdir","name":"cleanup","createdAt":"2026-07-07T09:00:00Z","updatedAt":"2026-07-07T09:01:00Z"}
EOF
cat >"$NVS_JOBS/job-stale-done/state.json" <<EOF
{"state":"done","cwd":"$NVS_REPO","name":"old-task","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:05:00Z"}
EOF
touch -t 202601010000 "$NVS_JOBS/job-stale-done/state.json"
cat >"$NVS_JOBS/job-unmatched-repo/state.json" <<EOF
{"state":"working","cwd":"/tmp/somewhere-not-discovered","name":"lonely","createdAt":"2026-07-07T10:00:00Z","updatedAt":"2026-07-07T10:00:00Z"}
EOF
_nvsstate="$(mktemp -d)"
_nvsscan_empty="$(mktemp -d)"   # empty scan base -- real ~/Development repos must never leak into these tests
export NEURAL_VIEW_STATE="$_nvsstate" NEURAL_VIEW_CLAUDE_DIR="$NVS_CLAUDE" NEURAL_VIEW_SCAN="$_nvsscan_empty"
_nvsrepo="$(basename "$NVS_REPO")"
lifecycle_start "neural-view starts (sessions fixture)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$NVS_REPO"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/sessions")"
check "sessions: working job included" '"messaging"' "$body"
check "sessions: recently-updated done job included" '"cleanup"' "$body"
check_absent "sessions: stale done job excluded" '"old-task"' "$body"
check "sessions: job cwd matched to the discovered repo" "\"repo\": \"$_nvsrepo\"" "$body"
check "sessions: job outside any discovered repo still reported (repo: null)" '"repo": null' "$body"
check "sessions: unmatched job still carries its description" '"lonely"' "$body"
# CDX-014 (#184, SPEC-CODEX-COMPAT.md §7.6): "SHALL label session counts by
# host once both are surfaced" -- discover_sessions() only ever reads
# ~/.claude/jobs, so every session it finds IS a Claude Code session; it
# tags each one with a hardcoded "host":"claude" literal, the seed point a
# future Codex-side discovery function would tag its own results against.
check "sessions: every entry carries host:claude" '"host": "claude"' "$body"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_CLAUDE_DIR NEURAL_VIEW_SCAN

# no jobs dir at all -> []
_nvsempty="$(mktemp -d)"
_nvs_noclaude="$(mktemp -d)"
export NEURAL_VIEW_CLAUDE_DIR="$_nvs_noclaude" NEURAL_VIEW_SCAN="$_nvsscan_empty"
lifecycle_start "neural-view starts (no jobs dir)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_nvsempty"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/sessions")"
check "sessions: absent jobs dir yields empty array" "[]" "$body"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_CLAUDE_DIR NEURAL_VIEW_SCAN
rm -rf "$NVS_CLAUDE" "$NVS_REPO" "$_nvsstate" "$_nvsscan_empty" "$_nvsempty" "$_nvs_noclaude"

# CDX-014 (#184, SPEC-CODEX-COMPAT.md §7.6) frontend: sessionHostsFor(repo)
# groups a repo's sessions by host, and the two consumption sites (repo-label
# text, hover tooltip) must render byte-identical to today when only one
# host is present, and append a "(N host, M host)" parenthetical only when
# more than one host is surfaced. No live path seeds a real second host yet
# (no Codex-side discovery exists), so this drives sessionHostsFor() directly
# against a synthetic multi-host window.__sessions fixture -- extract() works
# here (these are named `function` declarations, not anonymous listeners) so
# the anonymous-listener-slice-eval technique isn't needed for this pair.
if command -v node >/dev/null 2>&1; then
    NVHTML="$PLUGIN/templates/neural-view.html"
    check "neural-view.html: repo-label site appends the host breakdown" 'sessN ? ` · ${sessN} LIVE${sessionHostBreakdown(sessionHostsFor(repo))}` : ""' "$(cat "$NVHTML")"
    check "neural-view.html: tooltip site appends the host breakdown" '${sess} active session(s)${sessionHostBreakdown(sessionHostsFor(repo))}</div>' "$(cat "$NVHTML")"
    _nvhosts="$(mktemp).cjs"
    cat >"$_nvhosts" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extractOneLine(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
const window = {__sessions: []};
eval(extractOneLine("sessionCountFor"));
eval(extractOneLine("sessionHostsFor"));
eval(extractOneLine("sessionHostBreakdown"));

// single host (today's overwhelmingly common case) -> byte-identical, no parenthetical
window.__sessions = [{repo:"r", host:"claude"}, {repo:"r", host:"claude"}];
let hosts = sessionHostsFor("r");
let suffix = sessionHostBreakdown(hosts);
if (suffix !== "") throw new Error("single-host breakdown must be empty (no visible change), got: " + JSON.stringify(suffix));
if (sessionCountFor("r") !== 2) throw new Error("sessionCountFor must still count 2 sessions for repo r");

// multi-host -> parenthetical breakdown, only then
window.__sessions = [{repo:"r", host:"claude"}, {repo:"r", host:"claude"}, {repo:"r", host:"codex"}];
hosts = sessionHostsFor("r");
suffix = sessionHostBreakdown(hosts);
if (suffix !== " (2 claude, 1 codex)") throw new Error("multi-host breakdown mismatch, got: " + JSON.stringify(suffix));

// a repo with sessions on only one host among a multi-host dataset still gets no parenthetical
window.__sessions = [{repo:"r", host:"claude"}, {repo:"other", host:"codex"}];
suffix = sessionHostBreakdown(sessionHostsFor("r"));
if (suffix !== "") throw new Error("repo r has only one host present -- breakdown must stay empty, got: " + JSON.stringify(suffix));

console.log("SESSIONHOSTS_OK");
NODEJS
    hosts_out="$(node "$_nvhosts" "$NVHTML" 2>&1)"
    check "sessionHostsFor()/sessionHostBreakdown(): single-host stays byte-identical, multi-host appends breakdown, unrelated repos unaffected" "SESSIONHOSTS_OK" "$hosts_out"
    rm -f "$_nvhosts"
fi

