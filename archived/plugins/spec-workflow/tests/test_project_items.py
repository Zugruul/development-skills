"""project_items.py: slim GraphQL board read (#544) -- query text, page
normalisation to gh's `project item-list` JSON shape, honest rate-limit errors.

Fixtures under fixtures/gh-failures/ are REAL (or provenance-marked) gh output:
graphql-items-page-live.txt is a live `gh api -i graphql` capture of the query
this module emits; graphql-rate-limit-payload.txt carries the verbatim RATE_LIMIT
error object. Synthetic strings below only exercise behaviour (how a nonzero exit
or an odd envelope is handled), never what real gh wording looks like.
"""
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
GHF = Path(__file__).resolve().parent / "fixtures" / "gh-failures"
TOOL = SCRIPTS / "project_items.py"


def payload(name):
    """Everything after the first blank line (the provenance header)."""
    text = (GHF / name).read_text()
    return text.split("\n\n", 1)[1]


def run(*args, stdin=""):
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], input=stdin,
                          capture_output=True, text=True)


def run_bytes(*args, stdin=b""):
    """Binary stdin: CRLF must reach the tool untranslated, as from a real `gh api -i`."""
    r = subprocess.run([sys.executable, "-I", str(TOOL), *args], input=stdin, capture_output=True)
    return r.returncode, r.stdout.decode(), r.stderr.decode()


def captured_query(name):
    """The query text recorded in a fixture's provenance header (# query-begin ... # query-end)."""
    lines, on = [], False
    for line in (GHF / name).read_text().splitlines():
        if line.startswith("# query-end"):
            break
        if on:
            lines.append(line[1:].strip())
        if line.startswith("# query-begin"):
            on = True
    return "\n".join(lines)


def tokens(q):
    import re
    return re.findall(r"[{}():,$!]|[^\s{}():,$!]+", q)


def without(q, snippet):
    return q.replace(snippet, "")


# Shape documented in next.py from a live `gh project item-list --format json`:
GH_CONTENT_KEYS = {"body", "number", "repository", "title", "type", "url"}
GH_ITEM_KEYS = {"content", "estimate", "id", "labels", "priority", "repository", "status", "title"}


NAMES = "status=Status,priority=Priority,estimate=Estimate"


class QueryGolden(unittest.TestCase):
    """The shipped query is byte-for-byte (modulo whitespace) the one measured live."""

    def test_items_query_matches_the_live_captured_query(self):
        live = without(captured_query("gh-failures/graphql-items-page-live.txt".split("/")[1]),
                       "rateLimit { cost remaining resetAt }")
        shipped = run("query", "--names", NAMES).stdout
        self.assertEqual(tokens(shipped), tokens(live))

    def test_fields_query_matches_the_live_captured_query(self):
        live = without(captured_query("graphql-fields-live.txt"), "rateLimit { cost remaining resetAt }")
        live = live.replace("first: 50", "first: 100")  # only deliberate edit: room for 50 custom + built-in fields
        shipped = run("fields-query").stdout
        self.assertEqual(tokens(shipped), tokens(live))


class ViewerGolden(unittest.TestCase):
    """The "@me" variants are the same queries with the owner root swapped for `viewer`."""

    @staticmethod
    def as_viewer(q):
        t = tokens(q)
        text = " ".join(t)
        text = text.replace("$ owner : String ! ,", "")
        text = text.replace("repositoryOwner ( login : $ owner ) { ... on ProjectV2Owner {", "viewer {")
        # drop the closing brace of the ProjectV2Owner fragment (the one right before the final brace)
        out = text.split()
        last = len(out) - 1 - out[::-1].index("}")
        del out[last - 1]
        return out

    def test_viewer_fields_query_is_the_live_query_with_the_root_swapped(self):
        live = without(captured_query("graphql-fields-live.txt"), "rateLimit { cost remaining resetAt }").replace("first: 50", "first: 100")
        self.assertEqual(tokens(run("fields-query", "--viewer").stdout), self.as_viewer(live))

    def test_viewer_items_query_is_the_live_query_with_the_root_swapped(self):
        live = without(captured_query("graphql-items-page-live.txt"), "rateLimit { cost remaining resetAt }")
        self.assertEqual(tokens(run("query", "--viewer", "--names", NAMES).stdout), self.as_viewer(live))


class FieldNames(unittest.TestCase):
    """Project field names are case-insensitive in config and gh; the query must use the real ones."""

    def fields(self, names):
        body = {"data": {"repositoryOwner": {"projectV2": {"fields": {"nodes": [{"name": n} for n in names]}}}}}
        return "HTTP/2.0 200 OK\n\n" + json.dumps(body)

    def test_resolves_the_live_fixture_names(self):
        r = run("resolve", "--rc", "0", stdin=payload("graphql-fields-live.txt"))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, NAMES), r.stderr)

    def test_lowercase_board_fields_are_resolved_to_their_real_names(self):
        r = run("resolve", "--rc", "0", stdin=self.fields(["title", "status", "PRIORITY", "Estimate"]))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "status=status,priority=PRIORITY,estimate=Estimate"))

    def test_query_uses_resolved_names_but_lowercase_alias_keys(self):
        q = run("query", "--names", "status=status,priority=PRIORITY,estimate=Estimate").stdout
        self.assertIn('status: fieldValueByName(name: "status")', q)
        self.assertIn('priority: fieldValueByName(name: "PRIORITY")', q)

    def test_missing_status_is_a_distinct_failure_but_still_reports_the_rest(self):
        r = run("resolve", "--rc", "0", stdin=self.fields(["Priority", "Estimate"]))
        self.assertEqual(r.returncode, 4)
        self.assertEqual(r.stdout.strip(), "priority=Priority,estimate=Estimate")
        self.assertIn("no Status field", r.stderr)

    def test_status_ambiguous_by_case_is_flagged_and_exact_case_wins(self):
        r = run("resolve", "--rc", "0", stdin=self.fields(["status", "Status", "Priority"]))
        self.assertEqual(r.returncode, 5)
        self.assertEqual(r.stdout.strip(), "status=Status,priority=Priority")
        self.assertIn("ambiguous", r.stderr)

    def test_status_ambiguous_without_an_exact_match_is_unresolved(self):
        r = run("resolve", "--rc", "0", stdin=self.fields(["status", "STATUS"]))
        self.assertEqual(r.returncode, 5)
        self.assertNotIn("status=", r.stdout)

    def test_priority_duplicates_prefer_the_exact_name_quietly(self):
        r = run("resolve", "--rc", "0", stdin=self.fields(["Status", "priority", "Priority"]))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "status=Status,priority=Priority"))

    def test_missing_priority_or_estimate_is_not_fatal(self):
        r = run("resolve", "--rc", "0", stdin=self.fields(["Status"]))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "status=Status"))

    def test_resolve_reports_api_errors_like_page(self):
        r = run("resolve", "--rc", "1", stdin=payload("graphql-rate-limit-payload.txt"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("API rate limit already exceeded", r.stderr)


class WireFormat(unittest.TestCase):
    """Real gh output: status line ends LF, headers CRLF (graphql-items-page-live.crlf)."""

    RAW = (Path(__file__).resolve().parent / "fixtures" / "graphql-items-page-live.crlf").read_bytes()

    def test_fixture_really_is_crlf(self):
        self.assertIn(b"\r\n\r\n", self.RAW)

    def test_crlf_capture_parses(self):
        rc, out, err = run_bytes("page", "--rc", "0", stdin=self.RAW)
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(json.loads(out)["items"]), 3)

    def test_multiple_http_blocks_use_the_last_response(self):
        raw = b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 Connection established\r\nX-Ratelimit-Remaining: 1\r\n\r\n" + self.RAW
        rc, out, err = run_bytes("page", "--rc", "0", stdin=raw)
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["totalCount"], 428)

    def test_crlf_rate_limit_reset_header_is_read(self):
        raw = (b"HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: 1793854221\r\n\r\n"
               b'{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 1."}]}')
        rc, out, err = run_bytes("page", "--rc", "1", stdin=raw)
        self.assertEqual(rc, 1)
        self.assertIn("resets 2026-11-05T04:50:21Z", err)


class QueryText(unittest.TestCase):
    def test_slim_query_has_no_nested_field_connection(self):
        q = run("query").stdout
        self.assertIn("fieldValueByName", q)
        self.assertNotIn("fieldValues(", q)
        self.assertIn("pageInfo", q)
        self.assertIn("repositoryOwner", q)
        self.assertIn("ProjectV2Owner", q)
        self.assertNotIn("dryRun", q)

    def test_dry_run_variant_asks_for_cost_only(self):
        q = run("query", "--dry-run").stdout
        self.assertIn("rateLimit(dryRun: true)", q)

    def test_viewer_variant_for_at_me_owner(self):
        q = run("query", "--viewer").stdout
        self.assertIn("viewer", q)
        self.assertNotIn("repositoryOwner", q)


class PageShape(unittest.TestCase):
    def setUp(self):
        r = run("page", "--rc", "0", stdin=payload("graphql-items-page-live.txt"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.page = json.loads(r.stdout)

    def test_pagination_envelope(self):
        self.assertEqual(self.page["totalCount"], 428)
        self.assertTrue(self.page["hasNextPage"])
        self.assertTrue(self.page["endCursor"])
        self.assertEqual(len(self.page["items"]), 3)

    def test_item_matches_gh_item_list_shape(self):
        item = self.page["items"][0]
        self.assertEqual(set(item), GH_ITEM_KEYS - ({"estimate"} if "estimate" not in item else set()))
        self.assertLessEqual(set(item), GH_ITEM_KEYS)
        self.assertEqual(set(item["content"]), GH_CONTENT_KEYS)
        self.assertEqual(item["content"]["type"], "Issue")
        self.assertEqual(item["content"]["number"], 17)
        self.assertEqual(item["title"], item["content"]["title"])
        self.assertEqual(item["status"], "Backlog")
        self.assertEqual(item["priority"], "P2")
        self.assertEqual(item["estimate"], 2)
        self.assertIsInstance(item["estimate"], int)
        self.assertEqual(item["labels"], ["type:feature", "epic:E1"])
        self.assertEqual(item["content"]["repository"], "Zugruul/development-skills")
        self.assertEqual(item["repository"], "https://github.com/Zugruul/development-skills")
        self.assertEqual(item["content"]["url"], "https://github.com/Zugruul/development-skills/issues/17")

    def test_missing_field_values_are_omitted_like_gh(self):
        noest = [i for i in self.page["items"] if "estimate" not in i]
        self.assertTrue(noest, "fixture has items without an estimate")
        for i in noest:
            self.assertNotIn("estimate", i)

    def test_item_without_status_has_no_status_key(self):
        body = json.loads(payload("graphql-items-page-live.txt").split("\n\n", 1)[1])
        body["data"]["repositoryOwner"]["projectV2"]["items"]["nodes"][0]["status"] = None
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("status", json.loads(r.stdout)["items"][0])

    def test_draft_issue_and_redacted_content(self):
        body = {"data": {"repositoryOwner": {"projectV2": {"items": {
            "totalCount": 2, "pageInfo": {"hasNextPage": False, "endCursor": "c"},
            "nodes": [
                {"id": "D1", "status": None, "priority": None, "estimate": None,
                 "content": {"__typename": "DraftIssue", "title": "draft", "body": "b"}},
                {"id": "R1", "status": None, "priority": None, "estimate": None, "content": None}]}}}}}
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual(r.returncode, 0, r.stderr)
        items = json.loads(r.stdout)["items"]
        self.assertEqual(items[0]["content"]["type"], "DraftIssue")
        self.assertEqual(items[0]["title"], "draft")
        self.assertNotIn("number", items[0]["content"])
        self.assertEqual(items[1]["id"], "R1")


class Failures(unittest.TestCase):
    def test_real_rate_limit_payload_reports_githubs_error_and_header_reset(self):
        r = run("page", "--rc", "1", stdin=payload("graphql-rate-limit-payload.txt"))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "", "no partial JSON on stdout")
        self.assertIn("API rate limit already exceeded for user ID 12402908", r.stderr)
        self.assertIn("RATE_LIMIT", r.stderr)
        self.assertIn("2026-11-05T04:50:21Z", r.stderr)  # X-Ratelimit-Reset 1793854221

    def test_200_with_data_and_errors_is_a_failure(self):
        body = json.loads(payload("graphql-items-page-live.txt").split("\n\n", 1)[1])
        body["errors"] = [{"type": "RATE_LIMIT", "message": "API rate limit already exceeded for user ID 1."}]
        r = run("page", "--rc", "1", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")
        self.assertIn("rate limit", r.stderr)

    def test_nonzero_exit_fails_even_when_body_has_data_and_no_errors(self):
        # gh exiting nonzero means the read is not trustworthy, whatever the body says.
        body = payload("graphql-items-page-live.txt").split("\n\n", 1)[1]
        r = run("page", "--rc", "1", stdin="HTTP/2.0 200 OK\n\n" + body)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")

    def test_error_code_is_printed_so_a_reworded_payload_is_still_classifiable(self):
        r = run("page", "--rc", "1", stdin=payload("graphql-rate-limit-payload.txt"))
        self.assertIn("graphql_rate_limit", r.stderr)
        body = {"errors": [{"type": "X", "code": "graphql_rate_limit", "message": "Slow down."}]}
        r = run("page", "--rc", "1", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertIn("graphql_rate_limit", r.stderr)

    def _reset(self, headers):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "reset"
            body = {"message": "You have exceeded a secondary rate limit."}
            r = run("page", "--rc", "1", "--reset-file", str(f), stdin="HTTP/2.0 403 Forbidden\n" + headers + "\n\n" + json.dumps(body))
            return r, (int(f.read_text()) if f.exists() else None)

    def test_retry_after_wins_over_the_primary_reset(self):
        import time
        now = int(time.time())
        r, saved = self._reset("Retry-After: 600\nX-Ratelimit-Reset: %d" % (now + 5))
        self.assertIsNotNone(saved, r.stderr)
        self.assertGreaterEqual(saved, now + 590)

    def test_http_date_retry_after_is_ignored_and_the_primary_reset_is_used(self):
        # Retry-After may be an HTTP date; it must fail ALONE, not take X-Ratelimit-Reset down with it.
        r, saved = self._reset("Retry-After: Wed, 21 Oct 2037 07:28:00 GMT\nX-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: 1999999999")
        self.assertEqual(saved, 1999999999, r.stderr)
        self.assertIn("resets 2033-05-18T03:33:19Z", r.stderr)

    def test_garbage_retry_after_with_no_primary_reset_records_nothing(self):
        r, saved = self._reset("Retry-After: soon")
        self.assertIsNone(saved)

    def test_primary_reset_is_used_without_retry_after(self):
        import time
        now = int(time.time())
        r, saved = self._reset("X-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: %d" % (now + 5))
        self.assertEqual(saved, now + 5)

    def test_http_error_status_fails_even_with_exit_zero_and_no_errors_key(self):
        r = run("page", "--rc", "0", stdin="HTTP/2.0 403 Forbidden\n\n" + json.dumps({"message": "Forbidden"}))
        self.assertEqual(r.returncode, 1)
        self.assertIn("403", r.stderr)

    def test_errors_alongside_good_data_fail_even_with_exit_zero(self):
        body = json.loads(payload("graphql-items-page-live.txt").split("\n\n", 1)[1])
        body["errors"] = [{"type": "FORBIDDEN", "message": "partial"}]
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual((r.returncode, r.stdout), (1, ""))

    def test_invalid_utf8_in_a_body_does_not_crash_the_read(self):
        raw = (b'HTTP/2.0 200 OK\r\n\r\n{"data":{"repositoryOwner":{"projectV2":{"items":{"totalCount":1,'
               b'"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"I1","content":'
               b'{"__typename":"Issue","number":1,"title":"caf\xe9 \xff"}}]}}}}}')
        rc, out, err = run_bytes("page", "--rc", "0", stdin=raw)
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out)["items"][0]["id"], "I1")

    def test_strict_snapshot_without_total_count_is_rejected(self):
        import os
        r = subprocess.run([sys.executable, str(SCRIPTS / "wip.py"), "page"], input=json.dumps({"items": [{"id": "I1"}]}),
                           capture_output=True, text=True, env=dict(os.environ, PYTHONPATH=str(SCRIPTS)))
        self.assertEqual(r.returncode, 1)
        self.assertIn("WIP BLOCKED", r.stderr)

    def test_errors_with_zero_exit_still_fail(self):
        r = run("page", "--rc", "0", stdin=payload("graphql-rate-limit-payload.txt"))
        self.assertEqual(r.returncode, 1)

    def test_transport_failure_passes_stderr_through(self):
        err = GHF.parent.parent / "fixtures" / "gh-failures" / "masked-unknown-owner-type.txt"
        r = run("page", "--rc", "1", "--err", str(err), stdin="")
        self.assertEqual(r.returncode, 1)
        self.assertIn("unknown owner type", r.stderr)

    def test_owner_or_project_not_found(self):
        body = {"data": {"repositoryOwner": None}}
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual(r.returncode, 1)
        self.assertIn("not found", r.stderr)

    def test_next_page_without_cursor_is_incomplete(self):
        # non-empty page, so only the missing-cursor check (not the empty-page one) can reject it
        body = {"data": {"repositoryOwner": {"projectV2": {"items": {
            "totalCount": 5, "pageInfo": {"hasNextPage": True, "endCursor": None},
            "nodes": [{"id": "I1", "content": {"__typename": "Issue", "number": 1, "title": "t"}}]}}}}}
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual(r.returncode, 1)
        self.assertIn("endCursor", r.stderr)

    def test_missing_or_non_boolean_has_next_page_is_malformed_not_exhausted(self):
        # hasNextPage false is the ONLY proof of exhaustion; an absent/null/odd value proves nothing.
        node = {"id": "I1", "content": {"__typename": "Issue", "number": 1, "title": "t"}}
        for label, items in (
            ("no pageInfo", {"totalCount": 300, "nodes": [node]}),
            ("null pageInfo", {"totalCount": 300, "pageInfo": None, "nodes": [node]}),
            ("no hasNextPage", {"totalCount": 300, "pageInfo": {"endCursor": "c"}, "nodes": [node]}),
            ("null hasNextPage", {"totalCount": 300, "pageInfo": {"hasNextPage": None, "endCursor": "c"}, "nodes": [node]}),
            ("string hasNextPage", {"totalCount": 300, "pageInfo": {"hasNextPage": "false", "endCursor": "c"}, "nodes": [node]}),
            ("int hasNextPage", {"totalCount": 300, "pageInfo": {"hasNextPage": 0, "endCursor": "c"}, "nodes": [node]}),
        ):
            with self.subTest(label):
                body = {"data": {"repositoryOwner": {"projectV2": {"items": items}}}}
                r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
                self.assertEqual((r.returncode, r.stdout), (1, ""), r.stderr)
                self.assertIn("malformed board page", r.stderr)
                self.assertIn("hasNextPage", r.stderr)

    def test_next_page_with_no_items_is_no_progress(self):
        body = {"data": {"repositoryOwner": {"projectV2": {"items": {
            "totalCount": 5, "pageInfo": {"hasNextPage": True, "endCursor": "c1"}, "nodes": []}}}}}
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n" + json.dumps(body))
        self.assertEqual(r.returncode, 1)
        self.assertIn("no progress", r.stderr)

    def test_garbage_body_fails(self):
        r = run("page", "--rc", "0", stdin="HTTP/2.0 200 OK\n\n<html>")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")


class Merge(unittest.TestCase):
    def test_merge_concatenates_pages_in_order(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            for n, ids in enumerate((["a", "b"], ["c"])):
                (Path(d) / f"{n:05d}.json").write_text(json.dumps(
                    {"items": [{"id": i} for i in ids], "totalCount": 2 + n,
                     "hasNextPage": n == 0, "endCursor": "x"}))
            r = run("merge", d)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual([i["id"] for i in out["items"]], ["a", "b", "c"])
        self.assertEqual(out["totalCount"], 3, "totalCount comes from the LAST page (freshest)")
        self.assertNotIn("hasNextPage", out)


if __name__ == "__main__":
    unittest.main()
