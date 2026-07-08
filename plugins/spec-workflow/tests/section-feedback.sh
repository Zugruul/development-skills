#!/usr/bin/env bash
# section-feedback.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
echo "== feedback (loop feedback feed) =="
FT="$(mktemp -d)"; mkdir -p "$FT/.claude"
cp "$FIX/valid.project.yaml" "$FT/.claude/project.yaml"
fb() { (cd "$FT" && python3 "$PLUGIN/scripts/feedback.py" "$FT" "$@"); }

# config parsing: shorthand + expanded forms via config.py get
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback true >/dev/null
check "shorthand feedback=true readable" "true" "$(python3 "$PLUGIN/scripts/config.py" "$FT" get methodology.feedback)"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml")"
check "validator accepts shorthand feedback" "VALID: " "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": ".claude/feedbacks/feed.yaml", "roles": ["orchestrator"], "autoTriage": false}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml")"
check "validator accepts expanded feedback" "VALID: " "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "bogus": 1}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml" || true)"
check "validator rejects unknown feedback key" "unknown key" "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": ".claude/feedbacks/feed.yaml", "roles": ["orchestrator"], "autoTriage": false}' >/dev/null

# feed path containment: absolute paths and ../ escapes are rejected by the validator
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": "/tmp/escape-feed.yaml"}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml" || true)"
check "validator rejects absolute feed path" "must be repo-relative" "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": "../../escape/feed.yaml"}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml" || true)"
check "validator rejects ../ escaping feed path" "must not escape" "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": ".claude/feedbacks/feed.yaml", "roles": ["orchestrator"], "autoTriage": false}' >/dev/null

# status: disabled by default (no methodology.feedback key)
FD="$(mktemp -d)"; mkdir -p "$FD/.claude"; cp "$FIX/valid.project.yaml" "$FD/.claude/project.yaml"
out="$(cd "$FD" && python3 "$PLUGIN/scripts/feedback.py" "$FD" status)"
check "status: disabled by default" "feedback: disabled" "$out"
rm -rf "$FD"

check "status: enabled + feed path + pending=0" "feedback: enabled feed=.claude/feedbacks/feed.yaml pending=0" "$(fb status)"

# emit: valid record round-trips into the feed
out="$(fb emit "$FIX/feedback-valid.yaml")"
check "emit ok" "OK" "$out"
check "feed file created" "loop-feedback" "$(cat "$FT/.claude/feedbacks/feed.yaml" 2>/dev/null)"
check "status: pending reflects 2 unrouted items" "pending=2" "$(fb status)"

# emit: rejects a second record reusing an already-emitted ts (would make routing ambiguous)
out="$(fb emit "$FIX/feedback-valid.yaml" || true)"
check "emit rejects duplicate ts" "INVALID" "$out"
check "emit rejects duplicate ts: names the clash" "already exists" "$out"
check "status: pending unaffected by rejected duplicate" "pending=2" "$(fb status)"

# emit: rejects generalized/summary text carrying project-specific refs (#N)
out="$(fb emit "$FIX/feedback-bad-refs.yaml" || true)"
check "emit rejects #N ref" "INVALID" "$out"
check "emit rejects #N ref: names the offending ref" "#23" "$out"

# emit: rejects generalized text containing the iteration's own task id
BADTASK="$FT/bad-task.yaml"
cat >"$BADTASK" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-01T12:00:00Z"
iteration:
  task: FX-023
  outcome: merged
  reviewRounds: 1
source:
  role: dev
  model: claude-sonnet-5
items:
  - category: friction
    area: board
    severity: low
    summary: "FX-023 took longer than expected because of board flakiness."
    generalized: "FX-023 took longer than expected because of board flakiness."
YAML
out="$(fb emit "$BADTASK" || true)"
check "emit rejects task-id in generalized text" "INVALID" "$out"

# pending: lists the unrouted items from the valid record
out="$(fb pending)"
check "pending lists record ts" "2026-07-01T10:00:00Z" "$out"
check "pending lists category" "friction" "$out"
check "pending lists summary" "Front-load the human merge check-in" "$out"

# route: writes routing back, unknown action rejected, pending drops
out="$(fb route "2026-07-01T10:00:00Z" 0 bogus-action "n/a" || true)"
check "route rejects unknown action" "unknown routing action" "$out"
fb route "2026-07-01T10:00:00Z" 0 brain-note "friction-self-approval" >/dev/null
fb route "2026-07-01T10:00:00Z" 1 backlog "#41" >/dev/null
check "status: pending drops to zero after routing" "pending=0" "$(fb status)"
check "routing written into feed" "brain-note" "$(cat "$FT/.claude/feedbacks/feed.yaml")"

# route: re-routing an already-routed item is allowed but names the prior action
out="$(fb route "2026-07-01T10:00:00Z" 0 graduate "graduated-lesson")"
check "re-route surfaces the prior action" "(was: brain-note)" "$out"
rm -rf "$FT"

# route: a hand-crafted feed with a duplicate ts is refused as ambiguous rather than
# silently rewriting the first match and stranding the second
DT="$(mktemp -d)"; mkdir -p "$DT/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$DT/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$DT" set methodology.feedback true >/dev/null
cat >"$DT/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-08-01T00:00:00Z"
iteration: {task: FX-001, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "a", generalized: "a"}
---
schemaVersion: 1
kind: loop-feedback
ts: "2026-08-01T00:00:00Z"
iteration: {task: FX-002, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "b", generalized: "b"}
YAML
out="$(cd "$DT" && python3 "$PLUGIN/scripts/feedback.py" "$DT" route "2026-08-01T00:00:00Z" 0 ignore "n/a" 2>&1; echo "rc=$?")"
check "route refuses ambiguous duplicate ts" "ambiguous" "$out"
check "route refuses ambiguous duplicate ts: nonzero exit" "rc=1" "$out"
rm -rf "$DT"

# feedback.py independently refuses to write outside the repo root, even if a bad
# config slipped past validate-config.py (defense in depth)
ESC="$(mktemp -d)"; mkdir -p "$ESC/.claude"
ESCTARGET="$ESC-escape"  # unique per run (derived from $ESC), never left dangling across runs
rm -rf "$ESCTARGET"
cp "$FIX/valid.project.yaml" "$ESC/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$ESC" set methodology.feedback "{\"enabled\": true, \"feed\": \"../$(basename "$ESCTARGET")/feed.yaml\"}" >/dev/null
out="$(cd "$ESC" && python3 "$PLUGIN/scripts/feedback.py" "$ESC" emit "$FIX/feedback-valid.yaml" 2>&1; echo "rc=$?")"
check "feedback.py refuses to emit outside repo root" "ERROR" "$out"
check "feedback.py refuses to emit outside repo root: nonzero exit" "rc=1" "$out"
check "feedback.py did not write outside the root" "MISSING" "$([[ -f "$ESCTARGET/feed.yaml" ]] && echo FOUND || echo MISSING)"
rm -rf "$ESC" "$ESCTARGET"

# --- legacy-path migration guard (sw-062) --------------------------------
# .claude/feedback/ (singular) was the old, gitignored home of the feed;
# .claude/feedbacks/ (plural) is the new tracked archive. When the DEFAULT
# feed path is in effect (no explicit methodology.feedback.feed override)
# and a legacy feed exists but the new path doesn't, every subcommand that
# touches the feed must refuse and point at the migration rather than
# silently starting a fresh, empty archive that strands the old history.

# case 1: legacy exists, new path absent, DEFAULT (no override) -> every
# feed-touching subcommand fails loudly with a migration message.
LG="$(mktemp -d)"; mkdir -p "$LG/.claude/feedback"
cp "$FIX/valid.project.yaml" "$LG/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$LG" set methodology.feedback true >/dev/null
cat >"$LG/.claude/feedback/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-06-01T00:00:00Z"
iteration: {task: FX-000, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "legacy", generalized: "legacy"}
YAML
lg() { (cd "$LG" && python3 "$PLUGIN/scripts/feedback.py" "$LG" "$@" 2>&1; echo "rc=$?"); }
out="$(lg status)"
check "legacy guard: status fails" "rc=1" "$out"
check "legacy guard: status names migration" "migrat" "$out"
out="$(lg pending)"
check "legacy guard: pending fails" "rc=1" "$out"
out="$(lg emit "$FIX/feedback-valid.yaml")"
check "legacy guard: emit fails" "rc=1" "$out"
out="$(lg route "2026-06-01T00:00:00Z" 0 ignore "n/a")"
check "legacy guard: route fails" "rc=1" "$out"
check "legacy guard: never created the new feed" "MISSING" "$([[ -f "$LG/.claude/feedbacks/feed.yaml" ]] && echo FOUND || echo MISSING)"
rm -rf "$LG"

# case 2: legacy exists, but an explicit methodology.feedback.feed override
# is set -> guard does not apply, override path used as normal.
LO="$(mktemp -d)"; mkdir -p "$LO/.claude/feedback"
cp "$FIX/valid.project.yaml" "$LO/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$LO" set methodology.feedback '{"enabled": true, "feed": ".claude/custom-feed.yaml"}' >/dev/null
cat >"$LO/.claude/feedback/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-06-01T00:00:00Z"
iteration: {task: FX-000, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "legacy", generalized: "legacy"}
YAML
out="$(cd "$LO" && python3 "$PLUGIN/scripts/feedback.py" "$LO" status)"
check "override: legacy guard does not apply" "feedback: enabled feed=.claude/custom-feed.yaml pending=0" "$out"
rm -rf "$LO"

# case 3: neither legacy nor new path exists -> normal fresh feed (no guard)
LN="$(mktemp -d)"; mkdir -p "$LN/.claude"
cp "$FIX/valid.project.yaml" "$LN/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$LN" set methodology.feedback true >/dev/null
out="$(cd "$LN" && python3 "$PLUGIN/scripts/feedback.py" "$LN" status)"
check "fresh feed: no legacy, no guard, starts clean" "feedback: enabled feed=.claude/feedbacks/feed.yaml pending=0" "$out"
rm -rf "$LN"

# --- setup-project no longer gitignores the (now tracked) archive --------
setup_skill="$PLUGIN/skills/setup-project/SKILL.md"
check_absent "setup-project gitignore printf drops .claude/feedback/" ".claude/feedback/" \
  "$(grep -F 'printf' "$setup_skill")"
