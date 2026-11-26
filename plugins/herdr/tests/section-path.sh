#!/usr/bin/env bash
# section-path.sh -- sourced by run-tests.sh; do not run standalone.
# check-path.sh refuses a worktree path that falls inside a repository other than the
# target, so an enclosing repository's location rule never lands a nested clone's worktree
# inside the enclosing repository. Uses throwaway git repositories, no Herdr.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr/tests/run-tests.sh" >&2; exit 2; }
echo "== scripts: check-path =="

CP_TMP="$(cd "$(mktemp -d)" && pwd -P)"
cp_git() { git -C "$1" -c init.defaultBranch=main init -q; }
mkdir -p "$CP_TMP/mono/infra/k8s" "$CP_TMP/mono/.worktrees" "$CP_TMP/home/.herdr/worktrees" "$CP_TMP/plain"
cp_git "$CP_TMP/mono"
printf 'infra/k8s/\n.worktrees/\n' >"$CP_TMP/mono/.gitignore"
cp_git "$CP_TMP/mono/infra/k8s"
cp_path() { bash "$PLUGIN/scripts/check-path.sh" "$@" 2>&1; }

out="$(cp_path --target "$CP_TMP/mono/infra/k8s" --path "$CP_TMP/mono/.worktrees/remove-x")"; rc=$?
check_rc "a nested clone's worktree inside the enclosing repository is refused" 1 "$rc"
check "the refusal names the enclosing repository" "PATH REFUSED" "$out"
check "the refusal names the other repository's toplevel" "$CP_TMP/mono" "$out"
out="$(cp_path --target "$CP_TMP/mono/infra/k8s" --path "$CP_TMP/home/.herdr/worktrees/k8s/feat-remove-x")"; rc=$?
check_rc "Herdr's default directory outside any repository is accepted" 0 "$rc"
check "an accepted path prints PATH OK" "PATH OK" "$out"
out="$(cp_path --target "$CP_TMP/mono/infra/k8s" --path "$CP_TMP/mono/infra/k8s/.worktrees/remove-x")"; rc=$?
check_rc "a path inside the target's own working tree is accepted" 0 "$rc"
out="$(cp_path --target "$CP_TMP/mono/infra" --path "$CP_TMP/mono/.worktrees/x")"; rc=$?
check_rc "the target is the toplevel of the checkout given, so the enclosing repository's own rule still works for it" 0 "$rc"
out="$(cp_path --target "$CP_TMP/mono/infra/k8s" --path "$CP_TMP/mono/.worktrees/remove-x" --target-rule)"; rc=$?
check_rc "--target-rule accepts a path the target's own rule puts in another repository" 0 "$rc"
out="$(cp_path --target "$CP_TMP/plain" --path "$CP_TMP/home/x")"; rc=$?
check_rc "a target that is not a git repository exits 2" 2 "$rc"
out="$(cp_path --target "$CP_TMP/mono")"; rc=$?
check_rc "a missing --path is a usage error" 2 "$rc"

# A linked worktree is the same repository as its primary checkout.
git -C "$CP_TMP/mono" add .gitignore
git -C "$CP_TMP/mono" -c user.name=t -c user.email=t@t commit -qm init
git -C "$CP_TMP/mono" worktree add -q "$CP_TMP/mono/.worktrees/wt1" -b wt1
out="$(cp_path --target "$CP_TMP/mono/.worktrees/wt1" --path "$CP_TMP/mono/.worktrees/new")"; rc=$?
check_rc "a linked worktree as target keeps its repository's own .worktrees rule" 0 "$rc"
out="$(cp_path --target "$CP_TMP/mono/infra/k8s" --path "$CP_TMP/mono/.worktrees/wt1/sub/x")"; rc=$?
check_rc "a nested clone's worktree inside the enclosing repository's linked worktree is refused" 1 "$rc"
out="$(cp_path --target "$CP_TMP/mono/infra/k8s" --path "$CP_TMP/mono/.worktrees/remove-x")"; rc=$?
check_rc "the incident path is still refused once the enclosing repository has worktrees" 1 "$rc"

# The path is absolute, so it never depends on the caller's cwd.
out="$(cd "$CP_TMP/mono" && cp_path --target "$CP_TMP/mono/infra/k8s" --path ".worktrees/remove-x")"; rc=$?
check_rc "a relative --path is a usage error" 2 "$rc"
check "a relative --path says it must be absolute" "absolute" "$out"
# shellcheck disable=SC2088  # the tilde is quoted on purpose: the script expands it
out="$(cd "$CP_TMP/mono" && HOME="$CP_TMP/home" cp_path --target "$CP_TMP/mono/infra/k8s" --path '~/.herdr/worktrees/k8s/feat-x')"; rc=$?
check_rc "a quoted ~/ path is expanded against HOME, not the cwd" 0 "$rc"
check "the expanded path is reported" "path=$CP_TMP/home/.herdr/worktrees/k8s/feat-x" "$out"
rm -rf "$CP_TMP"
