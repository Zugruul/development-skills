#!/usr/bin/env bash
# section-feedback.sh -- sourced by run-tests.sh; do not run standalone.
# The feedback loop: the session toggle (session.sh --key feedback, off by default), raw notes
# outside every repository (feedback.sh add/show), the sanitiser that refuses task details
# (feedback.sh sanitize/lesson), the cleanup step that waits for feedback when it is on,
# the resume line, and the docs that state the no-leak rule.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

F_TMP="$(mktemp -d)"
F_STATE="$F_TMP/state-home"
F_REPO="$F_TMP/billing-api"
git init -q -b main "$F_REPO"
git -C "$F_REPO" -c user.name="Dana Quill" -c user.email=dana@example.org commit -q --allow-empty -m init
git -C "$F_REPO" branch feat/rate-guard
git -C "$F_REPO" remote add origin https://github.com/acme-corp/billing-api.git
# f SCRIPT ARGS...: run a plugin script with the stub herdr, a private state home, pane w1:p1
f() { local s="$1"; shift; (cd "$F_TMP" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$F_TMP" GH_STUB_DIR="$F_TMP" HERDR_ENV=1 HERDR_PANE_ID="${F_PANE:-w1:p1}" \
    XDG_STATE_HOME="$F_STATE" XDG_CONFIG_HOME="$F_TMP/config" bash "$PLUGIN/scripts/$s.sh" "$@"); }
printf '{}' >"$F_TMP/state.json"
F_FB="$F_STATE/herdr-graph/sessions/feedback/graph.yaml"

echo "== feedback: the toggle is off by default and lives in the session file =="
out="$(f feedback state 2>&1)"; rc=$?
check_rc "state without a session file works" 0 "$rc"
check "the loop is off without a session file" "FEEDBACK off" "$out"
f session set --key pane --value w1:p1 >/dev/null
check "a new session starts with the loop off" "off" "$(yq -r '.feedback' "$F_STATE/herdr-graph/sessions/graph.yaml")"
check "state reads off from the session" "FEEDBACK off" "$(f feedback state)"
out="$(f feedback add --text "the gate tab closed too early" 2>&1)"; rc=$?
check_rc "a note is refused while the loop is off" 4 "$rc"
check "the refusal says the loop is off" "FEEDBACK OFF" "$out"
check_absent "nothing is written while off" "gate tab" "$(cat "$F_FB" 2>/dev/null)"
out="$(f session set --key feedback --value maybe 2>&1)"; rc=$?
check_rc "the toggle takes only on or off" 2 "$rc"
out="$(f session set --key feedback --value on 2>&1)"; rc=$?
check_rc "the toggle turns on" 0 "$rc"
check "state reads on" "FEEDBACK on" "$(f feedback state)"
check "the pane's session is found without --session" "FEEDBACK on (graph)" "$(f feedback state)"

echo "== feedback: raw notes stay outside every repository =="
out="$(f feedback add --lane rate-guard --repo "$F_REPO" --from orchestrator --text "billing-api gate result was lost when the caller died" 2>&1)"; rc=$?
check_rc "the orchestrator adds a note for a lane" 0 "$rc"
check "add prints the note id" "ADDED note 1" "$out"
f feedback add --lane rate-guard --repo "$F_REPO" --from impl-agent --text "the brief named no base commit" >/dev/null
check "notes live in the user's state folder" "$F_FB" "$(f feedback path)"
check "notes keep who said it" "impl-agent" "$(yq -r '.notes[1].from' "$F_FB")"
check "notes keep the lane" "rate-guard" "$(yq -r '.notes[0].lane' "$F_FB")"
check_absent "no feedback file is written inside the repository" "feedback" "$(find "$F_REPO" -name '*feedback*' -not -path '*/.git/objects/*')"
out="$(f feedback add --text "token = ghp_abcdefghijklmnopqrstuvwxyz0123456789" 2>&1)"; rc=$?
check_rc "a secret is refused even in a raw note" 2 "$rc"
check_absent "the secret never reaches the file" "ghp_" "$(cat "$F_FB")"
check "show prints the notes" "the brief named no base commit" "$(f feedback show)"

echo "== feedback: the sanitiser refuses task details =="
san() { printf '%s\n' "$1" | f feedback sanitize "${@:2}" 2>&1; }
clean="A gate's result was lost when the caller died: gate.sh should record it itself.
- Briefs should always name the base commit, so a reviewer checks exactly the change.
- The orchestrator asked the same startup dialog twice; offer a standing answer on the first one.
- Use \`lane.sh note\` for every follow-up sent to a node, and see roles/implementer.md and ../../scripts/drift.sh."
out="$(printf '%s\n' "$clean" | f feedback sanitize 2>&1)"; rc=$?
check_rc "a general lesson passes" 0 "$rc"
check "a passing text is printed unchanged" "gate.sh should record it itself" "$out"
leak_case() { # name kind text [extra sanitize args]
    local name="$1" kind="$2" text="$3" o r
    shift 3
    o="$(san "$text" "$@")"; r=$?
    check_rc "refuses $name" 3 "$r"
    check "names the leak kind for $name" "LEAK $kind" "$o"
}
leak_case "a URL" url "see https://github.com/acme-corp/billing-api/pull/41 for the case"
leak_case "an email" email "ask dana@example.org about it"
leak_case "a handle" handle "the reviewer @dquill missed it"
leak_case "a token" secret "it used ghp_abcdefghijklmnopqrstuvwxyz0123456789 to push"
leak_case "a pull request number" number "PR #41 waited for review"
leak_case "an issue word with a number" number "issue 812 was the trigger"
leak_case "a ticket key" number "the PAY-1234 lane stalled"
leak_case "a commit sha" sha "the gate ran at 3f9c2ab1 and passed"
leak_case "a path" path "the agent edited src/billing/limiter.ts by mistake"
leak_case "a home path" path "the report sat in ~/notes forever"
leak_case "a branch name" path "the lane on feat/rate-guard drifted"
leak_case "a file name" file "the agent never opened limiter.ts"
leak_case "a domain" file "it called api.internal.io directly"
leak_case "a fenced code block" code '```'
leak_case "a code fragment" code "the agent wrote if (x == null) { retry() } again"
leak_case "an unknown inline code span" code "it ran \`npm run deploy\` without asking"
leak_case "quoted user wording" quote 'the user said "just ship it" and the gate was skipped'
leak_case "a curly quote" quote 'the user said “ship it” at once'
leak_case "a single-quoted phrase" quote "the user said 'ship it now' at once"
leak_case "a markdown quote" quote "> please hurry, the demo is tomorrow"
leak_case "a person's name mid-sentence" name "the reviewer asked Dana twice"
leak_case "a service name in CamelCase" name "PaymentGateway timed out in the gate"
leak_case "an IP address" ip "the gate reached 10.2.3.4 directly"
leak_case "a long number" number "it retried 31337 times"
leak_case "a denied word" deny "the fizzbuzz lane went fine" --deny fizzbuzz
leak_case "the repository's name (from --repo)" deny "billing-api was slow to build" --repo "$F_REPO"
leak_case "the remote owner (from --repo)" deny "acme-corp needs approvals" --repo "$F_REPO"
leak_case "a branch tail (from --repo)" deny "the rate-guard work drifted" --repo "$F_REPO"
leak_case "an author's name (from --repo), even at a sentence start" deny "Quill asked twice" --repo "$F_REPO"
leak_case "a lane name from the session's notes" deny "rate-guard took too long"
leak_case "a repository from the session's notes" deny "billing-api had no tests"
out="$(san "the brief named no base commit" --deny fizzbuzz)"; rc=$?
check_rc "a denied word elsewhere does not refuse a clean line" 0 "$rc"
out="$(printf 'Line one is general.\nThe agent edited src/x/y.ts.\nLine three is general too.\n' | f feedback sanitize 2>&1 >/dev/null)"
check "a refusal names the line" "line 2" "$out"
check "a refusal says what to do" "REFUSED" "$out"
out="$(printf 'Line one is general.\nThe agent edited src/x/y.ts.\nLine three is general too.\n' | f feedback sanitize --strip 2>/dev/null)"; rc=$?
check_rc "--strip keeps the clean lines" 0 "$rc"
check "--strip prints the clean lines" "Line three is general too." "$out"
check_absent "--strip drops the leaking line" "src/x" "$out"
out="$(printf 'General.\n```\nsecret code\n```\nAfter.\n' | f feedback sanitize --strip 2>/dev/null)"
check_absent "--strip drops every line of a fenced block" "secret code" "$out"
check "--strip keeps lines after the block" "After." "$out"
out="$(printf 'see src/a.ts\n' | f feedback sanitize --strip 2>&1)"; rc=$?
check_rc "--strip with nothing left refuses" 3 "$rc"
printf 'A general lesson about briefs.\n' >"$F_TMP/body.md"
out="$(f feedback sanitize --file "$F_TMP/body.md" 2>&1)"; rc=$?
check_rc "sanitize reads a file" 0 "$rc"
printf 'Fixes PR #41.\n' >"$F_TMP/bad.md"
out="$(f feedback sanitize --file "$F_TMP/body.md" --file "$F_TMP/bad.md" 2>&1)"; rc=$?
check_rc "sanitize refuses when any file leaks" 3 "$rc"

echo "== feedback: lessons are the only text an improvement lane gets =="
out="$(f feedback lesson --text "the gate in billing-api lost its result" 2>&1)"; rc=$?
check_rc "a leaking lesson is refused" 3 "$rc"
check_absent "a refused lesson is not stored" "lost its result" "$(yq -r '.lessons' "$F_FB")"
out="$(f feedback lesson --text "A gate's result was lost when the caller died; gate.sh should record it itself." 2>&1)"; rc=$?
check_rc "a general lesson is stored" 0 "$rc"
check "lesson prints its id" "ADDED lesson" "$out"
f feedback lesson --text "Briefs should always name the base commit." >/dev/null
out="$(f feedback lessons)"
check "lessons prints the open lessons" "- Briefs should always name the base commit." "$out"
check_absent "lessons never print raw notes" "impl-agent" "$out"
check_absent "lessons never print lane names" "rate-guard" "$out"
id="$(yq -r '.lessons[0].id' "$F_FB")"
f feedback used --id "$id" --ref "improvement lane 1" >/dev/null
check_absent "a used lesson is no longer open" "caller died" "$(f feedback lessons)"
check "the used lesson is kept with where it went" "improvement lane 1" "$(yq -r '.lessons[0].used' "$F_FB")"

echo "== feedback: cleanup waits for the orchestrator's feedback when the loop is on =="
F_LREPO="$F_TMP/lanes"
git init -q -b main "$F_LREPO" && git -C "$F_LREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$F_LREPO" worktree add -q -b look/pr-7 "$F_TMP/wt-rv" main
f lane new --repo "$F_LREPO" --lane rv-7 --pattern review --input pr=https://github.com/o/r/pull/7 --idea x --branch look/pr-7 --workspace w-rv >/dev/null
f lane set --repo "$F_LREPO" --lane rv-7 --key forwarded --value declined >/dev/null
f lane set --repo "$F_LREPO" --lane rv-7 --key status --value "done" >/dev/null
out="$(f feedback due --lane rv-7 2>&1)"; rc=$?
check_rc "feedback is due for a lane with no orchestrator note" 0 "$rc"
check "due names the lane and what to do" "FEEDBACK rv-7" "$out"
out="$(f cleanup check --lane rv-7 --repo "$F_LREPO" 2>&1)"
check "cleanup check asks for feedback first when the loop is on" "FEEDBACK rv-7" "$out"
f lane set --repo "$F_LREPO" --lane rv-7 --key cleanup --value confirmed >/dev/null
out="$(f cleanup run --lane rv-7 --repo "$F_LREPO" 2>&1)"; rc=$?
check_rc "cleanup run refuses while feedback is due" 6 "$rc"
check "the refusal says feedback is due" "FEEDBACK DUE" "$out"
f feedback add --lane rv-7 --from orchestrator --text "nothing to add" >/dev/null
out="$(f feedback due --lane rv-7 2>&1)"; rc=$?
check_rc "feedback is no longer due after the orchestrator's note" 1 "$rc"
check_absent "cleanup check no longer asks" "FEEDBACK rv-7" "$(f cleanup check --lane rv-7 --repo "$F_LREPO" 2>&1)"
f session set --key feedback --value off >/dev/null
out="$(f feedback due --lane other 2>&1)"; rc=$?
check_rc "nothing is due while the loop is off" 1 "$rc"

echo "== feedback: resume shows the toggle =="
check "resume shows the loop off" "FEEDBACK LOOP: off" "$(f resume --session graph 2>&1)"
f session set --key feedback --value on >/dev/null
check "resume shows the loop on with its counts" "FEEDBACK LOOP: on" "$(f resume --session graph 2>&1)"

echo "== feedback: the skill and the docs =="
fl="$(cat "$PLUGIN/skills/feedback-loop/SKILL.md" 2>/dev/null)"
check "feedback-loop: frontmatter names it" "name: feedback-loop" "$fl"
check "feedback-loop: stores the choice in the session" 'session.sh" set --key feedback' "$fl"
check "feedback-loop: off by default" "off by default" "$fl"
check "feedback-loop: asks with the question tool where there is one" "AskUserQuestion" "$fl"
check_absent "feedback-loop: portable frontmatter, no allowed-tools" "allowed-tools" "$(sed -n '2,/^---$/p' "$PLUGIN/skills/feedback-loop/SKILL.md" 2>/dev/null)"
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: asks at session start" "herdr-graph-engineering:feedback-loop" "$orch"
check "orchestrate: collects feedback before cleanup" 'feedback.sh" add' "$orch"
check "orchestrate: lessons go through the sanitiser" 'feedback.sh" lesson' "$orch"
check "orchestrate: states the no-leak rule" "never a detail of a task" "$orch"
check "orchestrate: the improvement lane edits only the plugin's instructions" "only the plugin's instructions" "$orch"
rd="$(cat "$PLUGIN/README.md")"
check "README: lists the feedback-loop skill" "| \`feedback-loop\` |" "$rd"
check "README: documents the no-leak rule" "never a detail of a task" "$rd"
check "README: states the sanitiser's limits" "What the sanitiser cannot catch" "$rd"

rm -rf "$F_TMP"
