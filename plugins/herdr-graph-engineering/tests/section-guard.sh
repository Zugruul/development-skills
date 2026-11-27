#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted text is literal text of the test files
# section-guard.sh -- sourced by run-tests.sh; do not run standalone.
# The preservation check (guard.sh): every instruction sentence of the base must still be there,
# unchanged and in place, or be listed in an allow file with a reason. The copy that judges a
# checkout never lives inside it.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

G_TMP="$(mktemp -d)"
G_REPO="$G_TMP/repo"
G_P="$G_REPO/plugins/demo"
git init -q -b main "$G_REPO"
g_git() { git -C "$G_REPO" -c user.name=t -c user.email=t@t -c core.autocrlf=false "$@"; }
# guard ARGS...: the plugin's guard.sh, which is outside the judged repository
guard() { bash "$PLUGIN/scripts/guard.sh" check --repo "$G_REPO" --base main "$@" 2>&1; }

mkdir -p "$G_P/skills/run" "$G_P/roles" "$G_P/patterns" "$G_P/references" "$G_P/tests" "$G_P/scripts" "$G_REPO/docs"
cat >"$G_P/skills/run/SKILL.md" <<'EOF'
---
name: run
description: Runs the thing. Use when asked to run.
---

# Run

Never trust done from an agent. Check the evidence first, then record it.

## Retries

- Retry only through the lane script. At the limit, ask the user.
- Never force a push.

## Notes

Keep notes short.
EOF
cat >"$G_P/roles/worker.md" <<'EOF'
## Boundaries
- Do not push.
- Do not push.
EOF
printf 'when: "Do one thing."\nnodes:\n  impl:\n    agent: worker\n' >"$G_P/patterns/one.yaml"
printf '# Brief\n\n| Rank | Why |\n|---|---|\n| 1 | the measured hole |\n\n```bash\nrun --safe\n```\n' >"$G_P/references/brief.md"
# shellcheck disable=SC2016 # literal text of a test file
printf 'check "a rule" "$out"\ncheck "another rule" "$out"\n' >"$G_P/tests/section-a.sh"
printf '#!/usr/bin/env bash\nexit 3\n' >"$G_P/scripts/guard.sh"
printf 'echo tool\n' >"$G_P/scripts/tool.sh"
printf '# Demo\n\nRun the checks before you finish.\n' >"$G_REPO/AGENTS.md"
printf 'Deploys need an approval.\n' >"$G_REPO/docs/deploy.md"
g_git add -A && g_git commit -q -m base
SK=plugins/demo/skills/run/SKILL.md
# case_start NAME: a fresh branch from the base
g_n=0
case_start() { g_n=$((g_n + 1)); g_git checkout -q -f main; g_git checkout -q -b "case-$g_n"; }
case_commit() { g_git add -A && g_git commit -q -m change; }
# edit FILE SED-EXPRESSION
edit() { sed "$2" "$G_REPO/$1" >"$G_TMP/edit" && cp "$G_TMP/edit" "$G_REPO/$1"; }
ids() { sed -n -E 's/^(REMOVED|CHANGED|MOVED) ([0-9a-f]+) .*/\2/p' <<<"$1"; }

echo "== guard: what passes =="
case_start
out="$(guard)"; rc=$?
check_rc "an unchanged branch passes" 0 "$rc"
check "a pass says so" "GUARD PASS" "$out"
case_start
cat >"$G_REPO/$SK" <<'EOF'
---
name: run
description: Runs the thing. Use when asked to run.
---

# Run

Never trust done
from an agent.
Check the evidence first,   then record it.

## Retries

* Retry only through the lane script.
  At the limit, ask the user.
* Never force a push.

## Notes

Keep notes short.
EOF
case_commit
out="$(guard)"; rc=$?
check_rc "reflowing lines and changing list markers passes" 0 "$rc"
case_start
edit "$SK" 's/^- Never force a push\.$/- Never force a push.\
- Say which guidance helped./'
printf '\n## New section\n\nA new rule.\n' >>"$G_REPO/$SK"
printf 'A new reference.\n' >"$G_P/references/new.md"
printf 'echo changed\n' >"$G_P/scripts/tool.sh"
# shellcheck disable=SC2016 # literal text of a test file
printf 'check "a third rule" "$out"\n' >>"$G_P/tests/section-a.sh"
case_commit
out="$(guard)"; rc=$?
check_rc "pure additions, new files and other scripts pass" 0 "$rc"
case_start
printf '# Brief\n\n|Rank|Why|\n|:--|--:|\n|  1  | the measured hole  |\n\n```bash\nrun --safe\n```\n' >"$G_P/references/brief.md"
case_commit
out="$(guard)"; rc=$?
check_rc "realigning a table passes" 0 "$rc"
case_start
edit "$SK" 's/^- Never force a push\.$/1. Never force a push./'
case_commit
out="$(guard)"; rc=$?
check_rc "numbering a list item passes" 0 "$rc"

echo "== guard: what it reports =="
case_start
edit "$SK" 's/ Check the evidence first, then record it\.//'
case_commit
out="$(guard)"; rc=$?
check_rc "a deleted sentence fails" 3 "$rc"
check "it is reported as removed, with its file" "REMOVED" "$out"
check "the report names the file" "$SK" "$out"
check "the report shows the old sentence" "- Check the evidence first, then record it." "$out"
check "the last line says it failed" "GUARD FAIL: 1 finding" "$(tail -n1 <<<"$out")"
check_absent "the untouched sentence beside it is not reported" "Never trust done" "$out"
case_start
edit "$SK" 's/Never force a push\./Never force a push without a reason./'
case_commit
out="$(guard)"; rc=$?
check_rc "a one-phrase edit fails" 3 "$rc"
check "it is reported as changed" "CHANGED" "$out"
check "it shows the old text" "- Never force a push." "$out"
check "it shows the new text" "+ Never force a push without a reason." "$out"
case_start
edit "$SK" '/^Keep notes short\.$/d'
case_commit
out="$(guard)"; rc=$?
check_rc "an emptied section fails" 3 "$rc"
check "its sentence is removed" "- Keep notes short." "$out"
case_start
rm "$G_P/patterns/one.yaml"
case_commit
out="$(guard)"; rc=$?
check_rc "a deleted file fails" 3 "$rc"
check "its lines are removed" 'when: "Do one thing."' "$out"
case_start
edit plugins/demo/roles/worker.md '$d'
case_commit
out="$(guard)"; rc=$?
check_rc "a duplicate sentence does not hide a removal" 3 "$rc"
check "one finding for the one lost copy" "GUARD FAIL: 1 finding" "$out"
case_start
edit "$SK" '/^Keep notes short\.$/d'
printf 'Keep notes short.\n' >"$G_P/references/notes.md"
case_commit
out="$(guard)"; rc=$?
check_rc "a sentence moved to another file fails" 3 "$rc"
check "it is reported as moved" "MOVED" "$out"
check "the report names where it went" "plugins/demo/references/notes.md" "$out"
case_start
edit "$SK" '/^- Never force a push\.$/d'
printf -- '- Never force a push.\n' >>"$G_REPO/$SK"
case_commit
out="$(guard)"; rc=$?
check_rc "a sentence moved to another section fails" 3 "$rc"
check "the move within the file is reported" "MOVED" "$out"
case_start
printf '# Brief\n\n| Rank | Why |\n|---|---|\n| 1 | the measured hole |\n\n<!--\n```bash\nrun --safe\n```\n-->\n' >"$G_P/references/brief.md"
case_commit
out="$(guard)"; rc=$?
check_rc "commenting text out fails" 3 "$rc"
check "the commented line is reported" "run --safe" "$out"
case_start
edit "$SK" 's/^Keep notes short\.$/```\
Keep notes short.\
```/'
case_commit
out="$(guard)"; rc=$?
check_rc "putting a sentence in a code block fails" 3 "$rc"
case_start
edit "$SK" 's/Use when asked to run\./Use rarely./'
case_commit
out="$(guard)"; rc=$?
check_rc "frontmatter is judged too" 3 "$rc"
check "the old description sentence is shown" "Use when asked to run." "$out"
case_start
# shellcheck disable=SC2016 # literal text of a test file
printf 'check "a rule" "$out"\n' >"$G_P/tests/section-a.sh"
case_commit
out="$(guard)"; rc=$?
check_rc "a removed line of an existing test fails" 3 "$rc"
check "the removed assertion is shown" "another rule" "$out"
case_start
printf '#!/usr/bin/env bash\nexit 0\n' >"$G_P/scripts/guard.sh"
case_commit
out="$(guard)"; rc=$?
check_rc "a lane that makes its own guard always pass still fails" 3 "$rc"
check "the guard's change is shown" "plugins/demo/scripts/guard.sh" "$out"

echo "== guard: only the exact finding is allowed, with a reason =="
case_start
edit "$SK" 's/Never force a push\./Never force a push without a reason./'
edit "$SK" '/^Keep notes short\.$/d'
case_commit
out="$(guard)"
id1="$(ids "$out" | sed -n 1p)" id2="$(ids "$out" | sed -n 2p)"
check_rc "two findings, two ids" 2 "$(ids "$out" | sort -u | wc -l | tr -d ' ')"
again="$(ids "$(guard)")"
check "the ids are the same on a second run" "$(ids "$out" | tr '\n' " ")" "$(tr '\n' " " <<<"$again")"
printf '# approved by the user\n%s the user approved it\n' "$id1" >"$G_TMP/allow"
out="$(guard --allow "$G_TMP/allow")"; rc=$?
check_rc "one allowed of two still fails" 3 "$rc"
check "the allowed finding is shown with its reason" "ALLOWED $id1 (the user approved it)" "$out"
check "one finding is left" "GUARD FAIL: 1 finding" "$out"
printf '%s a second reason\n' "$id2" >>"$G_TMP/allow"
out="$(guard --allow "$G_TMP/allow")"; rc=$?
check_rc "every finding allowed passes" 0 "$rc"
check "the pass counts what was allowed" "2 allowed" "$out"
printf '%s\n%s second\n' "$id1" "$id2" >"$G_TMP/allow-bare"
out="$(guard --allow "$G_TMP/allow-bare")"; rc=$?
check_rc "an entry without a reason allows nothing" 3 "$rc"
check "it says the reason is missing" "NO REASON $id1" "$out"
edit "$SK" 's/without a reason/when you like/'
case_commit
out="$(guard --allow "$G_TMP/allow")"; rc=$?
check_rc "a later push that changes the new text needs a new yes" 3 "$rc"
check "the old entry is reported as stale" "STALE $id1" "$out"
cp "$G_TMP/allow" "$G_REPO/allow"
out="$(guard --allow "$G_REPO/allow")"; rc=$?
check_rc "an allow file inside the checkout is refused" 2 "$rc"
check "the refusal says why" "ALLOW FILE INSIDE THE CHECKOUT" "$out"
rm "$G_REPO/allow"
out="$(guard --allow "$G_TMP/nothing-here")"; rc=$?
check_rc "a missing allow file is an error, not a pass" 2 "$rc"

echo "== guard: it judges from outside the lane's reach =="
case_start
mkdir -p "$G_P/scripts/src"
cp "$PLUGIN/scripts/guard.sh" "$G_P/scripts/guard.sh" 2>/dev/null
cp "$PLUGIN/scripts/src/common.sh" "$G_P/scripts/src/common.sh"
out="$(bash "$G_P/scripts/guard.sh" check --repo "$G_REPO" --base main 2>&1)"; rc=$?
check_rc "a copy inside the judged checkout refuses to run" 2 "$rc"
check "the refusal says to run the installed copy" "GUARD INSIDE THE CHECKOUT" "$out"
g_git checkout -q -f main; g_git clean -q -f -d
case_start
edit "$SK" '/^Keep notes short\.$/d'
out="$(guard)"; rc=$?
check_rc "only committed changes are judged" 0 "$rc"
check "an uncommitted change is mentioned" "NOTE uncommitted changes" "$out"
case_commit
g_git checkout -q main
printf 'A rule main gained later.\n' >>"$G_P/references/brief.md"
g_git commit -q -am later
g_git checkout -q "case-$g_n"
out="$(guard)"
check "the comparison starts at the merge base" "GUARD FAIL: 1 finding" "$out"
check_absent "what main gained later is not the branch's removal" "main gained later" "$out"
out="$(bash "$PLUGIN/scripts/guard.sh" check --repo "$G_REPO" --base no-such-ref 2>&1)"; rc=$?
check_rc "an unknown base is an error" 2 "$rc"
out="$(bash "$PLUGIN/scripts/guard.sh" check --repo "$G_REPO" 2>&1)"; rc=$?
check_rc "--base is required" 2 "$rc"

echo "== guard: a repository's documentation lane =="
case_start
printf '# Demo\n' >"$G_REPO/AGENTS.md"
case_commit
out="$(guard --target repo)"; rc=$?
check_rc "a repository's agent instructions are judged" 3 "$rc"
check "the lost instruction is shown" "Run the checks before you finish." "$out"
case_start
printf 'Deploys are open.\n' >"$G_REPO/docs/deploy.md"
case_commit
out="$(guard --target repo)"; rc=$?
check_rc "a repository's docs folder is judged" 3 "$rc"
out="$(guard)"; rc=$?
check_rc "the plugin target does not judge a repository's docs" 0 "$rc"
out="$(guard --target elsewhere)"; rc=$?
check_rc "the target is plugin or repo" 2 "$rc"

echo "== guard: the loop runs the check, asks the user and reviews what is kept =="
gp="$PLUGIN/patterns/improve.yaml"
check "improve: shipped and valid" "PATTERN OK" "$(XDG_CONFIG_HOME=/nonexistent bash "$PLUGIN/scripts/check-pattern.sh" "$gp" 2>&1)"
gj="$(yq -o=json '.' "$gp" 2>/dev/null)"
check "improve: a read-only reviewer after the gate" "reviewer read tests" "$(jq -r '[.nodes.review.agent, .nodes.review.access, (.nodes.review.needs | join(","))] | join(" ")' <<<"$gj")"
check "improve: changes go back to the implementer" "impl changes" "$(jq -r '[.nodes.review.retry.to, .nodes.review.retry.on] | join(" ")' <<<"$gj")"
gb="$(jq -r '.nodes.review.brief // ""' <<<"$gj")"
check "improve review: its job is keeping the expertise" "existing expertise is preserved" "$gb"
check "improve review: weaker rules" "weaker" "$gb"
check "improve review: new text that cancels old text" "contradict" "$gb"
check "improve review: specifics made vague" "vague" "$gb"
check "improve review: what an addition tells an agent" "would not work out" "$gb"
check "improve review: unread text is no reason to remove it" "did not need" "$gb"
check "improve review: gets the lessons" "{idea}" "$gb"
go="$(sed -n '/^## Feedback loop/,/^## Reports/p' "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: improvement lanes use the improve pattern" "with the \`improve\` pattern" "$go"
check_absent "orchestrate: no longer a solo improvement lane" "with the \`solo\` pattern" "$go"
check "orchestrate: the orchestrator runs its installed guard" 'bash "../../scripts/guard.sh" check --repo' "$go"
check "orchestrate: never the lane's copy" "never a copy in the lane's checkout" "$go"
check "orchestrate: again after every push" "after every push" "$go"
check "orchestrate: the user approves each removal or weakening" "**The user approves each removal or weakening.**" "$go"
check "orchestrate: shown old and new with the reason" "old → new, with the reason" "$go"
check "orchestrate: nothing is allowed without that yes" "Nothing is allowed without that yes" "$go"
check "orchestrate: the allow file lives outside the checkout" "outside every checkout" "$go"
check "orchestrate: the lane makes targeted edits" "Make the smallest targeted edit" "$go"
check "orchestrate: no rewrites" "do not rewrite, merge, shorten or move existing instruction text" "$go"
check "orchestrate: unread guidance is never deleted by itself" "never becomes a deletion by itself" "$go"
check "orchestrate: the questions ask what helped" "which guidance helped you or prevented a mistake" "$go"
check "orchestrate: lessons name their notes" "--from-note" "$go"
check "orchestrate: the user sees each lesson's support" "lessons --support" "$go"
check "orchestrate: an open pull request only proposes" 'feedback.sh" proposed' "$go"
check "orchestrate: used only after the merge" 'feedback.sh" used --ref' "$go"
check "orchestrate: a closed pull request reopens its lessons" 'feedback.sh" reopen --ref' "$go"
check_absent "orchestrate: nothing is used when the pull request opens" "Once the pull request is open: \`feedback.sh used" "$go"
check_absent "orchestrate: a repository lane is not told to shorten" "shorter or better-pointed" "$go"
gf="$(cat "$PLUGIN/skills/feedback-loop/SKILL.md")"
check "feedback-loop: unread guidance is never deleted by itself" "never becomes a deletion by itself" "$gf"
check "feedback-loop: names the preservation check" "guard.sh" "$gf"
check "feedback-loop: the user approves removals" "only the user's yes" "$gf"
gr="$(cat "$PLUGIN/README.md")"
check "README: lists the improve pattern" "| \`improve\` |" "$gr"
check "README: lists guard.sh" "guard.sh check --repo" "$gr"
check "README: keeping what the skills know" "### Keeping what the skills know" "$gr"
check "README: states the check's limits" "What the preservation check cannot see" "$gr"
check "README: used only after the merge" "only after the pull request merged" "$gr"
check "router: the improve pattern is the feedback loop's" "| \`improve\` |" "$(cat "$PLUGIN/references/router.md")"

rm -rf "$G_TMP"
