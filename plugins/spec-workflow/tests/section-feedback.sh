#!/usr/bin/env bash
# section-feedback.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
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

# --- qualified references (sw-089) ----------------------------------------
# Feedback references must carry the emitting project so a multi-project
# archive stays unambiguous: bare #N in items[].evidence[] and
# items[].routing.ref is normalized to <project.name>#N (project.name from
# THIS repo's own .claude/project.yaml); refs already qualified by ANY
# project (<slug>#N) pass through verbatim.

QR="$(mktemp -d)"; mkdir -p "$QR/.claude"
cp "$FIX/valid.project.yaml" "$QR/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$QR" set methodology.feedback true >/dev/null
qr() { (cd "$QR" && python3 "$PLUGIN/scripts/feedback.py" "$QR" "$@"); }

QRREC="$QR/qualify.yaml"
cat >"$QRREC" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-05T00:00:00Z"
iteration:
  task: FX-050
  outcome: merged
  reviewRounds: 1
source:
  role: dev
  model: claude-sonnet-5
items:
  - category: friction
    area: board
    severity: low
    summary: "Board sync lagged during the run."
    generalized: "Board sync lagging under load is worth tracking."
    evidence: ["PR #61", "already qualified comm-platform#71 stays untouched", "#5"]
    routing: {action: backlog, ref: "#77"}
YAML
qr emit "$QRREC" >/dev/null
out="$(cat "$QR/.claude/feedbacks/feed.yaml")"
check "emit qualifies bare evidence ref with own project name" "fixture-project#61" "$out"
check "emit qualifies bare short evidence ref" "fixture-project#5" "$out"
check "emit leaves foreign-qualified evidence untouched" "comm-platform#71" "$out"
check "emit qualifies routing.ref" "fixture-project#77" "$out"
check_absent "emit does not double-qualify an already-qualified evidence ref" "fixture-project#comm-platform" "$out"

# route: normalizes the ref argument the same way; foreign-qualified refs pass through
qr route "2026-07-05T00:00:00Z" 0 upstream "#90" >/dev/null
out="$(cat "$QR/.claude/feedbacks/feed.yaml")"
check "route normalizes a bare ref argument" "fixture-project#90" "$out"

qr route "2026-07-05T00:00:00Z" 0 upstream "other-repo#12" >/dev/null
out="$(cat "$QR/.claude/feedbacks/feed.yaml")"
check "route passes a foreign-qualified ref argument through verbatim" "other-repo#12" "$out"
rm -rf "$QR"

# generalization ban: extended to also reject qualified refs (<slug>#N), not
# just bare #N -- a generalized/summary text naming ANY project's issue still
# leaks project specifics out of the feed.
GB="$(mktemp -d)"; mkdir -p "$GB/.claude"
cp "$FIX/valid.project.yaml" "$GB/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$GB" set methodology.feedback true >/dev/null
GBREC="$GB/qualified-ref-banned.yaml"
cat >"$GBREC" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-06T00:00:00Z"
iteration:
  task: FX-051
  outcome: merged
  reviewRounds: 1
source:
  role: dev
  model: claude-sonnet-5
items:
  - category: friction
    area: board
    severity: low
    summary: "Board sync lagged, see some-repo#12 for background."
    generalized: "Board sync lagged, see some-repo#12 for background."
YAML
out="$(cd "$GB" && python3 "$PLUGIN/scripts/feedback.py" "$GB" emit "$GBREC" || true)"
check "generalization ban rejects a qualified ref (slug#N), not just bare #N" "INVALID" "$out"
check "generalization ban names the qualified ref" "some-repo#12" "$out"
rm -rf "$GB"

# migration: --migrate-qualify normalizes an existing feed's bare refs in
# evidence[]/routing.ref in place, surgically (every other byte untouched),
# and is idempotent (a second run changes nothing).
MG="$(mktemp -d)"; mkdir -p "$MG/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$MG/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$MG" set methodology.feedback true >/dev/null
cat >"$MG/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: '2026-06-01T00:00:00Z'
iteration:
  task: '10'
  outcome: merged
  reviewRounds: 1
source:
  role: dev
  model: claude-sonnet-5
items:
- category: friction
  area: board
  severity: low
  summary: pre-migration item
  detail: 'seen in PR #61 and issue #60'
  evidence:
  - 'PR #61'
  - 'already qualified comm-platform#71'
  generalized: pre-migration generalized text
  routing:
    action: backlog
    ref: '#77'
YAML
out="$(cd "$MG" && python3 "$PLUGIN/scripts/feedback.py" "$MG" migrate-qualify)"
check "migrate-qualify reports success" "OK" "$out"
post="$(cat "$MG/.claude/feedbacks/feed.yaml")"
check "migrate-qualify qualifies an evidence ref" "fixture-project#61" "$post"
check "migrate-qualify leaves a foreign-qualified evidence ref untouched" "comm-platform#71" "$post"
check "migrate-qualify qualifies routing.ref" "fixture-project#77" "$post"
check "migrate-qualify leaves detail text alone (only evidence[]/routing.ref are in scope)" \
  "detail: 'seen in PR #61 and issue #60'" "$post"
check "migrate-qualify preserves unrelated quoting/formatting" "ts: '2026-06-01T00:00:00Z'" "$post"

out2="$(cd "$MG" && python3 "$PLUGIN/scripts/feedback.py" "$MG" migrate-qualify)"
check "migrate-qualify second run reports no changes (idempotent)" "no changes" "$out2"
post2="$(cat "$MG/.claude/feedbacks/feed.yaml")"
check "migrate-qualify idempotent: file byte-identical after second run" "$post" "$post2"
rm -rf "$MG"

# --- ts normalization (sw-063) ---------------------------------------------
# ts is the record's routing identity. An unquoted ISO-8601 ts in a record
# YAML is re-typed by PyYAML into a datetime object; if emit dumped that
# object as-is, the feed line would be unquoted and CLI-string `route`
# lookups could never match it. emit must normalize ts to a canonical
# quoted ISO-8601 string before the duplicate check and before dumping, and
# route must match legacy (already-in-feed) datetime-typed ts values too.

TS="$(mktemp -d)"; mkdir -p "$TS/.claude"
cp "$FIX/valid.project.yaml" "$TS/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$TS" set methodology.feedback true >/dev/null
ts_() { (cd "$TS" && python3 "$PLUGIN/scripts/feedback.py" "$TS" "$@"); }

ts_ emit "$FIX/feedback-unquoted-ts.yaml" >/dev/null
check "emit normalizes an unquoted-ISO ts to a quoted feed line" \
  "ts: '2026-07-02T09:00:00Z'" "$(cat "$TS/.claude/feedbacks/feed.yaml")"
out="$(ts_ route "2026-07-02T09:00:00Z" 0 ignore "n/a")"
check "route addresses a record whose ts was normalized at emit time" "OK: routed" "$out"
rm -rf "$TS"

# legacy feed: a record already sitting in the feed with a datetime-typed
# (unquoted) ts -- built by writing the raw line directly, not via emit --
# must still be addressable by route via the equivalent CLI string.
TL="$(mktemp -d)"; mkdir -p "$TL/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$TL/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$TL" set methodology.feedback true >/dev/null
cat >"$TL/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: 2026-07-03T00:00:00Z
iteration: {task: FX-064, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "legacy datetime ts", generalized: "legacy datetime ts"}
YAML
out="$(cd "$TL" && python3 "$PLUGIN/scripts/feedback.py" "$TL" route "2026-07-03T00:00:00Z" 0 ignore "n/a")"
check "route matches a legacy datetime-typed ts already in the feed" "OK: routed" "$out"
rm -rf "$TL"

# duplicate-ts rejection must hold across the string/datetime boundary: an
# unquoted (datetime-typed) ts and a quoted (string) ts for the same instant
# must collide, not coexist as two "different" records.
TD="$(mktemp -d)"; mkdir -p "$TD/.claude"
cp "$FIX/valid.project.yaml" "$TD/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$TD" set methodology.feedback true >/dev/null
td_() { (cd "$TD" && python3 "$PLUGIN/scripts/feedback.py" "$TD" "$@"); }
td_ emit "$FIX/feedback-unquoted-ts.yaml" >/dev/null
DUPREC="$TD/dup-quoted-ts.yaml"
cat >"$DUPREC" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-02T09:00:00Z"
iteration:
  task: FX-065
  outcome: merged
  reviewRounds: 1
source:
  role: dev
  model: claude-sonnet-5
items:
  - category: friction
    area: board
    severity: low
    summary: "same instant, quoted this time"
    generalized: "same instant, quoted this time"
YAML
out="$(td_ emit "$DUPREC" || true)"
check "duplicate-ts rejection holds across the string/datetime boundary" "already exists" "$out"
rm -rf "$TD"

# --- archive (MEM-001) ------------------------------------------------------
# `archive` moves every feed document whose items are ALL routed into
# .claude/feedbacks/archive/<YYYY-MM>.yaml (month from the document's ts),
# leaving partially/un-routed documents in the feed untouched. Moved bytes
# must be byte-identical to how they sat in the feed (no yaml.dump round-trip).

# case 1: mixed feed (fully-routed + partially-routed + unrouted) -> only the
# fully-routed doc moves; survivors stay byte-identical; archive is exact.
AR="$(mktemp -d)"; mkdir -p "$AR/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$AR/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AR" set methodology.feedback true >/dev/null
ar_() { (cd "$AR" && python3 "$PLUGIN/scripts/feedback.py" "$AR" "$@"); }
cat >"$AR/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-01T00:00:00Z"
iteration: {task: FX-100, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "fully routed", generalized: "fully routed", routing: {action: ignore, ref: "n/a"}}
---
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-02T00:00:00Z"
iteration: {task: FX-101, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "routed item", generalized: "routed item", routing: {action: ignore, ref: "n/a"}}
  - {category: friction, area: board, severity: low, summary: "unrouted item", generalized: "unrouted item"}
---
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-03T00:00:00Z"
iteration: {task: FX-102, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "wholly unrouted", generalized: "wholly unrouted"}
YAML
cp "$AR/.claude/feedbacks/feed.yaml" "$AR/feed-before.yaml"
out="$(ar_ archive)"
check "archive: reports success" "OK" "$out"
post_feed="$(cat "$AR/.claude/feedbacks/feed.yaml")"
check "archive: survivor doc (partially routed) stays in feed" "FX-101" "$post_feed"
check "archive: survivor doc (wholly unrouted) stays in feed" "FX-102" "$post_feed"
check_absent "archive: fully-routed doc leaves the feed" "FX-100" "$post_feed"
check "archive: month archive file created" "FX-100" "$(cat "$AR/.claude/feedbacks/archive/2026-07.yaml" 2>/dev/null)"
check "archive: moved doc bytes preserved (routing intact)" "action: ignore" "$(cat "$AR/.claude/feedbacks/archive/2026-07.yaml")"
rm -f "$AR/feed-before.yaml"
rm -rf "$AR"

# case 2: month bucketing -- two routed docs in different months land in two
# distinct archive files.
AM="$(mktemp -d)"; mkdir -p "$AM/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$AM/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AM" set methodology.feedback true >/dev/null
am_() { (cd "$AM" && python3 "$PLUGIN/scripts/feedback.py" "$AM" "$@"); }
cat >"$AM/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-05-15T00:00:00Z"
iteration: {task: FX-200, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "may item", generalized: "may item", routing: {action: ignore, ref: "n/a"}}
---
schemaVersion: 1
kind: loop-feedback
ts: "2026-06-20T00:00:00Z"
iteration: {task: FX-201, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "june item", generalized: "june item", routing: {action: ignore, ref: "n/a"}}
YAML
out="$(am_ archive)"
check "archive: month bucketing reports success" "OK" "$out"
check "archive: may doc in 2026-05.yaml" "may item" "$(cat "$AM/.claude/feedbacks/archive/2026-05.yaml" 2>/dev/null)"
check "archive: june doc in 2026-06.yaml" "june item" "$(cat "$AM/.claude/feedbacks/archive/2026-06.yaml" 2>/dev/null)"
check "archive: feed emptied after both docs moved" "" "$(cat "$AM/.claude/feedbacks/feed.yaml" 2>/dev/null)"
rm -rf "$AM"

# case 3: idempotent second run -- exit 0, no-op, files unchanged.
AI="$(mktemp -d)"; mkdir -p "$AI/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$AI/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AI" set methodology.feedback true >/dev/null
ai_() { (cd "$AI" && python3 "$PLUGIN/scripts/feedback.py" "$AI" "$@"); }
cat >"$AI/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-10T00:00:00Z"
iteration: {task: FX-300, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "idempotent test", generalized: "idempotent test", routing: {action: ignore, ref: "n/a"}}
YAML
ai_ archive >/dev/null
feed_after_first="$(cat "$AI/.claude/feedbacks/feed.yaml" 2>/dev/null)"
archive_after_first="$(cat "$AI/.claude/feedbacks/archive/2026-07.yaml")"
out="$(ai_ archive; echo "rc=$?")"
check "archive: idempotent second run exits 0" "rc=0" "$out"
check "archive: idempotent second run is a no-op (message)" "no changes" "$out"
feed_after_second="$(cat "$AI/.claude/feedbacks/feed.yaml" 2>/dev/null)"
archive_after_second="$(cat "$AI/.claude/feedbacks/archive/2026-07.yaml")"
check "archive: idempotent -- feed unchanged" "$feed_after_first" "$feed_after_second"
check "archive: idempotent -- archive file unchanged" "$archive_after_first" "$archive_after_second"
rm -rf "$AI"

# case 3b: no feed file / empty feed -> no-op exit 0.
AN="$(mktemp -d)"; mkdir -p "$AN/.claude"
cp "$FIX/valid.project.yaml" "$AN/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AN" set methodology.feedback true >/dev/null
out="$(cd "$AN" && python3 "$PLUGIN/scripts/feedback.py" "$AN" archive; echo "rc=$?")"
check "archive: no feed file is a no-op" "rc=0" "$out"
mkdir -p "$AN/.claude/feedbacks"
: >"$AN/.claude/feedbacks/feed.yaml"
out="$(cd "$AN" && python3 "$PLUGIN/scripts/feedback.py" "$AN" archive; echo "rc=$?")"
check "archive: empty feed file is a no-op" "rc=0" "$out"
rm -rf "$AN"

# case 4: corrupt document anywhere in the feed -> nonzero exit, byte offset
# printed, feed AND archive dir left completely untouched.
AC="$(mktemp -d)"; mkdir -p "$AC/.claude/feedbacks"
cp "$FIX/valid.project.yaml" "$AC/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AC" set methodology.feedback true >/dev/null
cat >"$AC/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-11T00:00:00Z"
iteration: {task: FX-400, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "routed ok", generalized: "routed ok", routing: {action: ignore, ref: "n/a"}}
---
this is: not: valid: yaml: [unterminated
YAML
cp "$AC/.claude/feedbacks/feed.yaml" "$AC/feed-before.yaml"
out="$(cd "$AC" && python3 "$PLUGIN/scripts/feedback.py" "$AC" archive 2>&1; echo "rc=$?")"
check "archive: corrupt doc -- nonzero exit" "rc=1" "$out"
check "archive: corrupt doc -- reports a byte offset" "byte offset" "$out"
post="$(cat "$AC/.claude/feedbacks/feed.yaml")"
before="$(cat "$AC/feed-before.yaml")"
check "archive: corrupt doc -- feed left byte-identical" "$before" "$post"
check "archive: corrupt doc -- archive dir not created" "MISSING" "$([[ -d "$AC/.claude/feedbacks/archive" ]] && echo FOUND || echo MISSING)"
rm -f "$AC/feed-before.yaml"
rm -rf "$AC"

# case 5: atomicity -- a write failure (read-only archive/ dir) must leave the
# feed completely unmodified.
AA="$(mktemp -d)"; mkdir -p "$AA/.claude/feedbacks/archive"
cp "$FIX/valid.project.yaml" "$AA/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AA" set methodology.feedback true >/dev/null
cat >"$AA/.claude/feedbacks/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-12T00:00:00Z"
iteration: {task: FX-500, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "blocked by readonly archive dir", generalized: "blocked by readonly archive dir", routing: {action: ignore, ref: "n/a"}}
YAML
cp "$AA/.claude/feedbacks/feed.yaml" "$AA/feed-before.yaml"
chmod 555 "$AA/.claude/feedbacks/archive"
out="$(cd "$AA" && python3 "$PLUGIN/scripts/feedback.py" "$AA" archive 2>&1; echo "rc=$?")"
chmod 755 "$AA/.claude/feedbacks/archive"
check "archive: atomicity -- readonly archive dir causes nonzero exit" "rc=1" "$out"
post="$(cat "$AA/.claude/feedbacks/feed.yaml")"
before="$(cat "$AA/feed-before.yaml")"
check "archive: atomicity -- feed left untouched on write failure" "$before" "$post"
rm -f "$AA/feed-before.yaml"
rm -rf "$AA"

# case 6: regression -- pending never scans archive/, and emit/route still work.
AG="$(mktemp -d)"; mkdir -p "$AG/.claude/feedbacks/archive"
cp "$FIX/valid.project.yaml" "$AG/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$AG" set methodology.feedback true >/dev/null
ag_() { (cd "$AG" && python3 "$PLUGIN/scripts/feedback.py" "$AG" "$@"); }
cat >"$AG/.claude/feedbacks/archive/2026-01.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-01-01T00:00:00Z"
iteration: {task: FX-600, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "archived item should not resurface", generalized: "archived item should not resurface", routing: {action: ignore, ref: "n/a"}}
YAML
out="$(ag_ pending)"
check "archive: pending never reads archive/ (empty feed stays pending=0)" "" "$out"
ag_ emit "$FIX/feedback-valid.yaml" >/dev/null
out="$(ag_ pending)"
check "archive: emit/pending still work with an archive dir present" "Front-load the human merge check-in" "$out"
check_absent "archive: pending does not surface archived items" "archived item should not resurface" "$out"
ag_ route "2026-07-01T10:00:00Z" 0 brain-note "x" >/dev/null
ag_ route "2026-07-01T10:00:00Z" 1 backlog "y" >/dev/null
check "archive: status unaffected by archive dir presence" "pending=0" "$(ag_ status)"
rm -rf "$AG"

# README's feedback.py scripts-list entry enumerates the CLI verbs explicitly
# (emit/pending/route/status/migrate-qualify) -- it must name `archive` too,
# or the doc silently goes stale the moment a new verb ships.
readme="$PLUGIN/README.md"
readme_verbs_line="$(grep -F 'emit/pending/route/status/migrate-qualify' "$readme")"
check "README documents feedback.py's archive verb" "emit/pending/route/status/migrate-qualify/archive" "$readme_verbs_line"
check "README describes what archive does" "archive/<YYYY-MM>.yaml" "$readme_verbs_line"
