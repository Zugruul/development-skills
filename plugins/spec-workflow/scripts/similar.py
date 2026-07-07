#!/usr/bin/env python3
"""similar.py — rank board issues by similarity to a query (dedup/near-duplicate detection).

Usage: similar.py <root> "<query>"
Prints ranked matches, one per line, descending by score:
    <tier>\t<score>\t#<number>\t<status>\t<title>
Exit 0 always when the issue source is readable, even with zero matches (an
empty result is a valid answer, not an error). A MISSING issues file is not
an error either — it yields empty output, exit 0. Malformed JSON in an issues
file that DOES exist is a hard failure (uncaught exception, non-zero exit) —
that indicates corrupt input, not "no data," and is not silently swallowed.

This is a pure scoring function: it takes issue data (open+closed) as input and
never calls gh/board.sh itself (board.sh is the only live board access; wiring
this script to live board.sh output is SW-002's job, not this script's).

Issue source (test/fixture plumbing only, per SW-001 scope):
  $SIMILAR_ISSUES_FILE, if set, names a JSON file shaped {"issues": [{"number",
  "title", "body", "status"}, ...]} — this is how the hermetic test suite
  supplies fixture data. Absent that override, <root>/.claude/tmp/similar-issues.json
  is read if present, else there are no issues to score against (empty output).
  <root> is otherwise unused today; it is accepted (and resolved the same way
  every other script in scripts/ takes a root) so the CLI contract has a stable
  place to grow into once SW-002 pipes live board.sh data through a cache file
  at that path instead of the env var.

Scoring (stdlib only — no numpy/sklearn/embeddings, see SPEC §3 non-goals):
  For each of title and body, take the max of:
    - difflib.SequenceMatcher ratio over normalized word sequences (catches
      near-verbatim rewordings and small insertions/deletions)
    - token Jaccard overlap (catches paraphrases: same words, different order)
  score = max(title_field_score, 0.85 * body_field_score) — title matches count
  fully, body-only matches count slightly less.

Tiers (score bands, re-tunable without a spec delta):
  high   >= 0.60
  medium >= 0.35
  low    >= 0.15
  below 0.15: dropped from output entirely (not a match worth surfacing).
"""
import difflib
import json
import os
import re
import sys

HIGH, MEDIUM, LOW = 0.60, 0.35, 0.15

STOPWORDS = {
    "a", "an", "the", "to", "in", "on", "of", "and", "or", "for", "from",
    "with", "is", "are", "this", "that", "it", "as", "by", "at", "be",
    "let", "between", "want", "i",
}


def normalize(text):
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def tokens(text):
    return {w for w in normalize(text).split() if w and w not in STOPWORDS}


def field_score(query, text):
    if not text:
        return 0.0
    # Word-level (not character-level) sequence matching: avoids inflated ratios
    # from coincidental character/space overlap between unrelated sentences.
    seq = difflib.SequenceMatcher(None, normalize(query).split(), normalize(text).split()).ratio()
    q, t = tokens(query), tokens(text)
    jaccard = len(q & t) / len(q | t) if (q or t) else 0.0
    return max(seq, jaccard)


def score_issue(query, issue):
    title_score = field_score(query, issue.get("title", ""))
    body_score = field_score(query, issue.get("body", ""))
    return max(title_score, 0.85 * body_score)


def tier_of(score):
    if score >= HIGH:
        return "high"
    if score >= MEDIUM:
        return "medium"
    return "low"


def load_issues(root):
    path = os.environ.get("SIMILAR_ISSUES_FILE") or os.path.join(root, ".claude", "tmp", "similar-issues.json")
    if not os.path.exists(path):
        return []
    with open(path) as fh:
        return json.load(fh).get("issues", [])


def sanitize(text):
    """Collapse tabs/newlines so a field can't break the tab-separated output contract."""
    return re.sub(r"[\t\r\n]+", " ", str(text)).strip()


def rank(issues, query):
    scored = [(score_issue(query, it), it) for it in issues]
    scored = [(s, it) for s, it in scored if s >= LOW]
    scored.sort(key=lambda pair: pair[0], reverse=True)
    return scored


def main(root, query):
    for score, it in rank(load_issues(root), query):
        status = sanitize(it.get("status", ""))
        title = sanitize(it.get("title", ""))
        print(f'{tier_of(score)}\t{score:.2f}\t#{it.get("number")}\t{status}\t{title}')


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
