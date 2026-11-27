#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# guard.sh -- the preservation check of an improvement lane: every instruction sentence of the
# base is still in the branch, unchanged and in place, or it is listed in an allow file with a
# reason. It needs no model and guesses nothing about which sentences matter: all of them do.
#
# The orchestrator runs ITS OWN installed copy against the lane's checkout. A copy that sits inside
# the judged checkout refuses to run, and so does an allow file there: the lane cannot edit its
# judge. This is a process barrier, not a security one: an agent running as the same user can
# still write any file.
#
# Usage: guard.sh check --repo DIR --base REF [--head REF] [--target plugin|repo] [--allow FILE]
#   Compares merge-base(base, head) with head (default HEAD): committed files only.
#   --target plugin (default): the files under any skills/, roles/, patterns/ or references/
#     folder, by sentence (Markdown) or line (other files); also every line under any tests/
#     folder and of any scripts/guard.sh, so the lane cannot quietly weaken a check.
#   --target repo: a repository's documentation: AGENTS.md, CLAUDE.md, README*.md and the
#     text files under any docs/ folder.
#   A unit is a sentence, a heading, a table row, or a line of a code block, comment or
#   frontmatter. Reflowing, list markers and table alignment do not change it.
#
# One finding per lost unit, with an id that covers the file, the old text and what replaced it,
# so a later push that changes the new text needs a new entry:
#   CHANGED <id> <file>               "- old" then "+ new" (all new text of that place)
#   REMOVED <id> <file>               "- old"
#   MOVED <id> <file> -> <where>      "- old": another file, place or section
# The allow file: one "<id> <reason>" per line; # starts a comment. An entry with no reason
# allows nothing (NO REASON <id>); an entry that matches no finding prints STALE <id>.
#
# What it cannot see: a new sentence that cancels or weakens an old one, and what a script does.
# An independent preservation review (patterns/improve.yaml) is there for the first.
#
# Exit codes: 0 pass, 1 error, 2 usage or refused, 3 findings not allowed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
export LC_ALL=C

USAGE="guard.sh check --repo DIR --base REF [--head REF] [--target plugin|repo] [--allow FILE]"
repo="" base="" head="HEAD" target="plugin" allow="" cmd=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --base) need_value "$1" $#; base="$2"; shift 2 ;;
        --head) need_value "$1" $#; head="$2"; shift 2 ;;
        --target) need_value "$1" $#; target="$2"; shift 2 ;;
        --allow) need_value "$1" $#; allow="$2"; shift 2 ;;
        -*) usage "$USAGE" ;;
        *) [ -z "$cmd" ] || usage "$USAGE"; cmd="$1"; shift ;;
    esac
done
if [ "$cmd" != check ] || [ -z "$repo" ] || [ -z "$base" ]; then usage "$USAGE"; fi
case "$target" in plugin | repo) ;; *) die "--target must be plugin or repo" 2 ;; esac
require_tools git diff awk

top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository: $repo" 2
top="$(cd "$top" && pwd -P)"
case "$HERE/" in "$top"/*) die "GUARD INSIDE THE CHECKOUT: $HERE is in $top, so the branch being judged could change it. Run the installed plugin's copy." 2 ;; esac
if [ -n "$allow" ]; then
    [ -f "$allow" ] || die "no such allow file: $allow" 2
    adir="$(cd "$(dirname "$allow")" && pwd -P)"
    case "$adir/" in "$top"/*) die "ALLOW FILE INSIDE THE CHECKOUT: $allow is in $top, where the lane could write it. Keep it outside." 2 ;; esac
    [ ! -L "$allow" ] || die "ALLOW FILE INSIDE THE CHECKOUT: $allow is a link; name the file itself, outside the checkout." 2
fi
g() { git --no-replace-objects -C "$top" "$@"; }
head_sha="$(g rev-parse --verify --quiet "$head^{commit}")" || die "no such commit: $head" 2
base_sha="$(g rev-parse --verify --quiet "$base^{commit}")" || die "no such commit: $base" 2
base_sha="$(g merge-base "$base_sha" "$head_sha")" || die "$base and $head share no history" 2

TMP="$(mktemp -d)" || die "could not create a temporary folder"
trap 'rm -rf "$TMP"' EXIT

# mode_of PATH -> md | lines | (nothing: not judged)
mode_of() {
    local p="/$1" name="${1##*/}"
    if [ "$target" = plugin ]; then
        case "$p" in
            */tests/*) echo lines; return 0 ;;
            */scripts/guard.sh) echo lines; return 0 ;;
            */skills/* | */roles/* | */patterns/* | */references/*) ;;
            *) return 0 ;;
        esac
    else
        case "$name" in
            AGENTS.md | CLAUDE.md | README*.md) ;;
            *) case "$p" in
                */docs/*.md | */docs/*.mdx | */docs/*.rst | */docs/*.txt | */docs/*.adoc) ;;
                *) return 0 ;;
            esac ;;
        esac
    fi
    case "$name" in *.md | *.mdx) echo md ;; *) echo lines ;; esac
}

# units MODE: file on stdin -> one "section<TAB>unit" line each
units() {
    if [ "$1" = lines ]; then
        awk '{ gsub(/\t/, "    "); sub(/[ \r]+$/, "") } $0 != "" { printf "\t%s\n", $0 }'
    else
        awk '
        function squash(s) { gsub(/[ \t\r]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
        function emit(s) { if (s != "") printf "%s\t%s\n", section, s }
        # split a paragraph or list item into sentences
        function flush(   s, rest, done, end, nxt, piece, tag) {
            s = squash(buf); buf = ""; tag = nest; nest = ""
            rest = s; done = ""
            while (match(rest, /[.!?][])"\047`*_]* /)) {
                end = RSTART + RLENGTH - 1
                piece = done substr(rest, 1, end - 1)
                nxt = substr(rest, end + 1, 1)
                rest = substr(rest, end + 1)
                if (nxt ~ /[a-z]/ || piece ~ /(e\.g\.|i\.e\.|vs\.|cf\.)$/) { done = piece " "; continue }
                emit(tag piece); done = ""
            }
            if (done rest != "") emit(tag done rest)
        }
        NR == 1 && /^---[ \t\r]*$/ { fm = 1; section = "frontmatter"; next }
        fm && /^---[ \t\r]*$/ { flush(); fm = 0; section = ""; next }
        {
            line = $0
            t = squash(line)
        }
        fence != "" {
            if (index(t, fence) == 1 && t ~ /^(`+|~+)$/) { fence = ""; next }
            if (t != "") emit("code: " t)
            next
        }
        {
            bare = t
            gsub(/`[^`]*`/, "", bare)
        }
        comment || index(bare, "<!--") {
            flush()
            if (t != "") emit("comment: " t)
            # the last opener or closer on the line decides whether the comment goes on
            while (p = index(bare, comment ? "-->" : "<!--")) {
                bare = substr(bare, p + (comment ? 3 : 4))
                comment = !comment
            }
            next
        }
        t ~ /^(```|~~~)/ {
            flush()
            match(t, /^(`+|~+)/)
            fence = substr(t, 1, RLENGTH)
            next
        }
        t == "" { flush(); next }
        fm {
            if (line ~ /^[ \t]*[A-Za-z0-9_-]+:/) flush()
            buf = buf " " t
            next
        }
        t ~ /^#+ / { flush(); section = ""; emit(t); section = t; next }
        t ~ /^\|/ {
            flush()
            if (t ~ /^[|: -]+$/) next
            gsub(/ *\| */, "|", t)
            emit(t)
            next
        }
        t ~ /^([-*+]|[0-9]+[.)]) / {
            flush()
            if (line ~ /^(  |\t)/) nest = "nested: "
            sub(/^([-*+]|[0-9]+[.)]) /, "", t)
            buf = t
            next
        }
        { buf = buf " " t }
        END { flush() }'
    fi
}

# The records of every judged file that differs:
#   D file hunk text     a base unit diff does not find in place
#   A file hunk text     a head unit it does not find in the base
#   H file heading       a heading the head file has
#   S file from to text  a unit kept in order whose section changed
g diff --no-renames --name-only -z "$base_sha" "$head_sha" >"$TMP/changed" || die "git diff failed"
: >"$TMP/records"
judged=0
while IFS= read -r -d '' path; do
    mode="$(mode_of "$path")"
    [ -n "$mode" ] || continue
    judged=$((judged + 1))
    for side in base head; do
        rev="$base_sha"; [ "$side" = base ] || rev="$head_sha"
        if g cat-file -e "$rev:$path" 2>/dev/null; then
            g cat-file blob "$rev:$path" | units "$mode" >"$TMP/$side.units" || die "could not read $path at $rev"
        else
            : >"$TMP/$side.units"
        fi
        cut -f2- "$TMP/$side.units" >"$TMP/$side.text"
    done
    diff "$TMP/base.text" "$TMP/head.text" >"$TMP/diff"
    [ "$?" -le 1 ] || die "diff failed on $path"
    GUARD_FILE="$path" awk -F '\t' '
        BEGIN { file = ENVIRON["GUARD_FILE"] }
        FILENAME == ARGV[1] { bsec[FNR] = $1; sub(/^[^\t]*\t/, ""); btext[FNR] = $0; nb = FNR; next }
        FILENAME == ARGV[2] { hsec[FNR] = $1; sub(/^[^\t]*\t/, ""); htext[FNR] = $0; nh = FNR; next }
        /^[0-9]/ {
            hunk++
            match($0, /[acd]/)
            op = substr($0, RSTART, 1)
            split(substr($0, 1, RSTART - 1), l, ",")
            split(substr($0, RSTART + 1), r, ",")
            if (op != "a") for (i = l[1]; i <= (l[2] == "" ? l[1] : l[2]); i++) { gone[i] = 1; printf "D\t%s\t%d\t%s\n", file, hunk, btext[i] }
            if (op != "d") for (i = r[1]; i <= (r[2] == "" ? r[1] : r[2]); i++) { added[i] = 1; printf "A\t%s\t%d\t%s\n", file, hunk, htext[i] }
        }
        END {
            for (j = 1; j <= nh; j++) if (htext[j] ~ /^#+ /) has[htext[j]] = 1
            j = 0
            for (i = 1; i <= nb; i++) {
                if (i in gone) continue
                for (j++; j in added; j++) { }
                if (bsec[i] != hsec[j] && (bsec[i] == "" || bsec[i] == "frontmatter" || bsec[i] in has))
                    printf "S\t%s\t%s\t%s\t%s\n", file, bsec[i], hsec[j], btext[i]
            }
        }' "$TMP/base.units" "$TMP/head.units" "$TMP/diff" >>"$TMP/records" || die "could not compare $path"
done <"$TMP/changed"

# Classify: a lost unit found among the added ones moved; else it changed when its place has new
# text; else it was removed. Output: kind <US> file <US> old <US> new-or-destination <US> ordinal
awk -F '\t' '
    function rest(n,   s, i) { s = $0; for (i = 1; i < n; i++) sub(/^[^\t]*\t/, "", s); return s }
    function out(kind, file, old, new,   k) {
        k = kind SUBSEP file SUBSEP old SUBSEP new
        printf "%s\037%s\037%s\037%s\037%d\n", kind, file, old, new, ++seen[k]
    }
    $1 == "D" { nd++; dfile[nd] = $2; dhunk[nd] = $3; dtext[nd] = rest(4) }
    $1 == "A" { na++; afile[na] = $2; ahunk[na] = $3; atext[na] = rest(4) }
    $1 == "S" { ns++; sfile[ns] = $2; sfrom[ns] = $3; sto[ns] = $4; stext[ns] = rest(5) }
    END {
        for (i = 1; i <= na; i++) byt[atext[i]] = byt[atext[i]] " " i
        # first the same file, then any file
        for (pass = 1; pass <= 2; pass++)
            for (d = 1; d <= nd; d++) {
                if (d in moved || !(dtext[d] in byt)) continue
                n = split(byt[dtext[d]], c, " ")
                for (x = 1; x <= n; x++) {
                    a = c[x]
                    if (a in used || (pass == 1 && afile[a] != dfile[d])) continue
                    used[a] = 1; moved[d] = a; break
                }
            }
        for (a = 1; a <= na; a++) if (!(a in used)) {
            k = afile[a] SUBSEP ahunk[a]
            new[k] = (k in new) ? new[k] "\036" atext[a] : atext[a]
        }
        for (d = 1; d <= nd; d++) {
            k = dfile[d] SUBSEP dhunk[d]
            if (d in moved) {
                a = moved[d]
                out("MOVED", dfile[d], dtext[d], afile[a] == dfile[d] ? "another place in the same file" : afile[a])
            } else if (k in new) out("CHANGED", dfile[d], dtext[d], new[k])
            else out("REMOVED", dfile[d], dtext[d], "")
        }
        for (s = 1; s <= ns; s++)
            out("MOVED", sfile[s], stext[s], "under " (sto[s] == "" ? "no heading" : sto[s]) ", was under " (sfrom[s] == "" ? "no heading" : sfrom[s]))
    }' "$TMP/records" >"$TMP/findings" || die "could not classify the differences"

# The allow file: "<id> <reason>" lines.
: >"$TMP/allow"
[ -z "$allow" ] || awk '{ sub(/\r$/, "") } /^[ \t]*(#|$)/ { next } { id = $1; sub(/^[ \t]*[^ \t]+[ \t]*/, ""); printf "%s\t%s\n", id, $0 }' "$allow" >"$TMP/allow"
reason_of() { awk -F '\t' -v id="$1" '$1 == id && $2 != "" { print $2; exit }' "$TMP/allow"; }

open=0 allowed=0
: >"$TMP/ids"
while IFS=$'\037' read -r kind file old new ord; do
    id="$(printf '%s\037%s\037%s\037%s\037%s' "$kind" "$file" "$old" "$new" "$ord" | git hash-object --stdin | cut -c1-12)"
    printf '%s\n' "$id" >>"$TMP/ids"
    why="$(reason_of "$id")"
    if [ -n "$why" ]; then
        allowed=$((allowed + 1))
        printf 'ALLOWED %s (%s)\n' "$id" "$why"
    else
        open=$((open + 1))
    fi
    if [ "$kind" = MOVED ]; then
        printf 'MOVED %s %s -> %s\n  - %s\n' "$id" "$file" "$new" "$old"
    else
        printf '%s %s %s\n  - %s\n' "$kind" "$id" "$file" "$old"
        [ -z "$new" ] || printf '%s\n' "$new" | tr '\036' '\n' | sed 's/^/  + /'
    fi
done <"$TMP/findings"

while IFS=$'\t' read -r id why; do
    if ! grep -qxF -- "$id" "$TMP/ids"; then
        printf 'STALE %s (no finding has this id now)\n' "$id"
    elif [ -z "$why" ] && [ -z "$(reason_of "$id")" ]; then
        printf 'NO REASON %s (an entry is "<id> <reason>"; without a reason it allows nothing)\n' "$id"
    fi
done <"$TMP/allow"

[ "$head" != HEAD ] || [ -z "$(g status --porcelain 2>/dev/null)" ] || echo "NOTE uncommitted changes in the checkout are not judged: only commits are"
summary="base $(printf '%s' "$base_sha" | cut -c1-12) head $(printf '%s' "$head_sha" | cut -c1-12), $judged judged file(s) differ, $allowed allowed"
if [ "$open" -gt 0 ]; then
    printf 'GUARD FAIL: %s finding(s) not allowed (%s). Show each one to the user, old and new with the reason; only their yes allows it.\n' "$open" "$summary"
    exit 3
fi
printf 'GUARD PASS: %s\n' "$summary"
