# gh-failures corpus (issue #91)

A corpus of REAL `gh` failure outputs, captured with provenance, so error-text
classifiers (board-queue.sh's `_rate_limited`, neural-view.py's
`_classify_board_failure`) are tested against what real `gh` actually emits —
not against invented strings authored beside the detector they're meant to
catch.

That circularity is exactly what bit this project twice: #77 shipped a
rate-limit detector whose fixture used honest "rate limit" wording, and
minutes after it merged, live GraphQL exhaustion actually surfaced as
`unknown owner type` — no "rate limit" text anywhere — which #90 had to
hotfix after the fact. Both the #77 and #90 reviewers independently asked for
this corpus so the next such gap gets caught by a fixture diff, not a live
incident.

## The practice

**Whenever a masked, odd, or otherwise surprising `gh` error is observed live
in ANY session — this repo or elsewhere — capture the raw bytes here
immediately, before the surprise is forgotten or rationalized away.** A
captured string with provenance is worth more than a paraphrase written from
memory an hour (or a day) later. If you can reproduce it on demand safely
(see "deliberate exhaustion" below), do that too, but capturing the live
bytes first is the non-negotiable part.

## File format

Every corpus file is plain text (or JSON) with two parts, separated by a
single blank line:

1. **Provenance header** — one or more lines starting with `#`, covering:
   what command was run, when (UTC, absolute — not "yesterday"), the account
   state (e.g. GraphQL `remaining` at capture time), and the source (a live
   terminal capture this session, vs. reconstructed from an issue/commit/log
   that quoted the original live capture, with the exact file/line/issue
   cited).
2. **Raw payload** — everything after that blank line, byte-for-byte. For
   ANSI-colored text this includes the literal ESC bytes; don't sanitize them
   out, that's the point.

Fixtures extract the payload with:

```bash
awk 'f{print} /^$/{f=1}' "$GH_FAILURES/<file>"
```

(`GH_FAILURES` is exported by each section file's setup as
`$FIX/gh-failures`.) The same convention works uniformly for `.txt` and
`.json` corpus entries.

## Meta-check

`tests/section-gh-failures-corpus.sh` (run by `run-tests.sh`) enforces two
invariants over this directory:

- every corpus file (except this README) opens with a `#` provenance header
  and has a non-empty payload after it;
- every corpus file is referenced by at least one `section-*.sh` fixture —
  no dead corpus entries.

Adding a corpus file without wiring it into a fixture (or a dedicated
regression check, for a bug already fixed upstream so no live fixture
reproduces it anymore) fails the gate.

## Deliberate exhaustion (optional, on-demand repro)

If you want to reproduce a masked/odd error on demand rather than wait for
one to happen live: use a disposable token/account with a tight GraphQL
budget and burn it with a tight loop of cheap GraphQL-backed calls (e.g.
repeated `gh project item-list`) until `gh api rate_limit`'s
`.resources.graphql.remaining` hits 0, then run the `gh project` command you
want to observe. **Never do this against the account driving real build-loop
work** — this task (#91) explicitly avoided deliberately exhausting the real
session's quota for exactly that reason (see
`rate-limit-endpoint-sample.json`'s and
`rate-limit-endpoint-near-exhausted.json`'s provenance headers: both are
genuine live captures from this account's ambient usage, not a forced drain).

## Current entries

| file | captures |
|---|---|
| `masked-unknown-owner-type.txt` | GraphQL exhaustion masked as `unknown owner type` (live incident #68/#74/#90; cross-validated live this task via a bad `--owner` value) |
| `rate-limit-honest-user-id.txt` | Honest GraphQL rate-limit wording (`API rate limit already exceeded for user ID <n>`), reconstructed from GitHub's documented format — not found verbatim in this repo's history |
| `jsondecodeerror-ansi-traceback-py313.txt` | The colorized Python 3.13 `JSONDecodeError` traceback tail from board.sh's old ungated `json.load` pipe (pre-#77), live-recaptured this task |
| `rate-limit-endpoint-sample.json` | Real `gh api rate_limit` response, live-captured (`resources.graphql.remaining=41`) |
| `rate-limit-endpoint-near-exhausted.json` | Real `gh api rate_limit` response, live-captured (`resources.graphql.remaining=1`, genuinely near-exhausted from ambient account usage) |
| `graphql-items-page-live.txt` | Real `gh api -i graphql` response (headers + body) of the slim project-items query (#544), live-captured against a user-owned project; the exact query sent is in its provenance header and golden-tested against `project_items.py query` |
| `graphql-fields-live.txt` | Real `gh api -i graphql` response of the field-name resolution query (#544 review), live-captured; query in its provenance header, golden-tested against `project_items.py fields-query` |
| `graphql-rate-limit-payload.txt` | GraphQL `RATE_LIMIT` rejection (#544): the error object is verbatim from a live payload, the envelope and headers are reconstructed (marked in its header) |

`tests/fixtures/graphql-items-page-live.crlf` (outside this corpus: it is a byte-exact binary, not a `#`-headed text file) is the
same live items capture trimmed, with the real wire quirk preserved: LF after the status line, CRLF between headers.
