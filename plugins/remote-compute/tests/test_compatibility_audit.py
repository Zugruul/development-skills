"""Bounded CDX-050 document contract, negative fixtures, and local engine probes."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[1]
ROOT = PLUGIN.parents[1]
MATRIX = ROOT / "docs/compatibility-matrix.md"
NAMES = ("remote-compute", "compute-top", "scan", "ssh")
STATUS = "Source-reviewed; live unverified"
SCOPE = "This incremental matrix audits only four remote-compute skills; the rest of the marketplace is NOT audited here."
CLAIMS = (
    SCOPE,
    "CDX-042 remains incomplete.",
    "Execution target: WSL/Linux/macOS; native PowerShell is unsupported.",
    "Windows Codex hosts need a WSL bridge and WSL paths.",
    "Live Claude/Codex installation, live SSH, and interactive dashboard execution: unverified (not performed).",
    "Human fingerprint verification and intent authorization remain agent policy; an accepted flag does not prove either.",
    "Neither allowed-tools nor host hooks establish a cross-host security boundary.",
)
DETAILS = {
    "remote-compute": (
        "Interaction: bare skill request runs list, then asks which verb; never guess a nickname.",
        "skills/remote-compute/SKILL.md#L50", "scripts/remote-compute.py#L678", "G1", "G2"),
    "compute-top": (
        "Interaction: browse/prune needs the human's TTY; non-TTY output is a one-shot snapshot.",
        "skills/compute-top/SKILL.md#L114", "scripts/remote-capabilities/_shared/compute-top.py#L364", "G1"),
    "scan": (
        "Interaction: bare skill request scans all registered machines; duplicate identity requires the human's choice.",
        "skills/scan/SKILL.md#L17", "scripts/remote-compute.py#L2162"),
    "ssh": (
        "Interaction: bare skill request runs connect and prints commands; the agent does not open an interactive session.",
        "skills/ssh/SKILL.md#L14", "scripts/remote-compute.py#L2495"),
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def read_delta(root):
    pending = root / "docs/spec-deltas/CDX-050.md"
    applied = root / "docs/spec-deltas/applied/CDX-050.md"
    require(pending.is_file() != applied.is_file(), "expected exactly one pending/applied delta")
    text = (pending if pending.is_file() else applied).read_text(encoding="utf-8")
    if applied.is_file():
        canonical = (root / "SPEC-CODEX-COMPAT.md").read_text(encoding="utf-8")
        # These are the two changed clauses and their existing sibling bounds.
        patterns = (r"^## \u00a711 [^\n]*\n", r"^- \*\*\u00a711\.1\*\* ",
                    r"^- \*\*\u00a711\.2\*\* ", r"^- \*\*\u00a711\.3\*\* ", r"^## \u00a712 ")
        bounds = []
        for pattern in patterns:
            matches = list(re.finditer(pattern, canonical, re.MULTILINE))
            require(len(matches) == 1, "archived delta has not been folded into unique canonical section bounds")
            bounds.append(matches[0])
        require([bound.start() for bound in bounds] == sorted(bound.start() for bound in bounds),
                "archived delta has not been folded into ordered canonical sections")
        replacements = [section.split("\n", 1)[1].strip() for section in text.split("\n## ")[1:]]
        require(len(replacements) == 2, "expected the introduction and 11.1 delta only")
        for index, replacement in enumerate(replacements):
            actual = canonical[bounds[index].end():bounds[index + 1].start()]
            require(" ".join(replacement.split()) == " ".join(actual.split()),
                    "archived delta has not been folded into its exact canonical section")
    return text


def validate_matrix(text):
    """Check a small published contract, not arbitrary natural-language semantics."""
    lines = text.splitlines()
    for claim in CLAIMS:
        require(claim in lines, "missing exact claim: " + claim)
    start, end = "<!-- remote-audit:start -->", "<!-- remote-audit:end -->"
    require(text.count(start) == text.count(end) == 1, "expected one audit marker pair")
    require(text.index(start) < text.index(end), "audit markers are reversed")
    for name in NAMES:
        require(len(re.findall(r"^##[ \t]+" + re.escape(name) + r"[ \t]*$", text, re.MULTILINE)) == 1,
                "expected one skill heading: " + name)
    for gap in ("G1", "G2"):
        require(len(re.findall(r"^###[ \t]+" + gap + r"(?:[ \t]|$)", text, re.MULTILINE)) == 1,
                "expected one gap heading: " + gap)
    table = text.split("<!-- remote-audit:start -->")[1].split("<!-- remote-audit:end -->")[0]
    rows = [line for line in table.splitlines() if line.startswith("| `")]
    require(len(rows) == 4, "expected exactly four rows")
    seen = []
    for row in rows:
        cells = [cell.strip() for cell in row.strip("|").split("|")]
        require(len(cells) == 7, "expected seven audit columns")
        name = cells[0].strip("`")
        seen.append(name)
        require(name in NAMES, "unexpected skill")
        require(cells[1:3] == [STATUS, STATUS], "unsupported host support claim")
        require(cells[3] == "[Section 7](#" + name + ")", "wrong interaction coverage")
        require(cells[4] == "N/A: no delegation/model routing", "wrong Section 8 coverage")
        require(cells[5] == "N/A: no build-loop/board transitions; [mechanics](#mechanical-enforcement)",
                "wrong Section 9 coverage")
        require(cells[6] == "[Limitations](#" + name + ")", "missing limitations")
    require(sorted(seen) == sorted(NAMES), "missing or duplicate skill")
    for name, claims in DETAILS.items():
        block = text.split("## " + name + "\n")[1].split("\n## ")[0]
        for claim in claims:
            require(claim in block, name + ": missing claim/reference " + claim)
    for gap, source in (("G1", "skills/compute-top/SKILL.md#L114"),
                        ("G2", "skills/remote-compute/SKILL.md#L307")):
        block = text.split("### " + gap + " ")[1].split("\n### ")[0].split("\n## ")[0]
        require(re.search(r"https://github.com/Zugruul/development-skills/issues/[1-9][0-9]*", block),
                gap + ": missing filed follow-up")
        require(source in block, gap + ": missing source evidence")
        require("Status: open; not fixed by this audit." in block, gap + ": unsupported resolution")


class AuditDocuments(unittest.TestCase):
    def text(self):
        self.assertTrue(MATRIX.is_file(), "CDX-050 matrix is missing")
        return MATRIX.read_text(encoding="utf-8")

    def test_matrix_contract(self):
        validate_matrix(self.text())

    def test_scan_claims_state_the_legacy_and_pick_limits(self):
        text = self.text()
        scan = text.split("## scan\n")[1].split("\n## ")[0]
        mechanics = text.split("## Mechanical enforcement\n")[1].split("\n## ")[0]
        claims = (
            "Legacy fallback: without a registered machineId and without a candidate identity stamp, scan can accept the pinned key alone.",
            "Pick validation: candidate membership is checked only when resolving multiple matching candidates; a single match ignores an out-of-candidate --pick.",
        )
        for claim in claims:
            self.assertIn(claim, scan.splitlines())
        self.assertNotIn("requires matched pinned keys plus stable UUID", " ".join(scan.split()))
        self.assertNotIn("[two-factor scan]", mechanics)
        self.assertIn("Two-factor matching has a legacy key-only fallback; --pick membership validation is limited to duplicate-candidate resolution.",
                      mechanics.splitlines())

    def test_duplicate_audit_structures_are_rejected(self):
        text = self.text()
        table = "<!-- remote-audit:start -->" + text.split("<!-- remote-audit:start -->")[1].split("<!-- remote-audit:end -->")[0] + "<!-- remote-audit:end -->"
        mutations = {
            "duplicate contradictory table": text + "\n" + table.replace(STATUS, "Live parity verified"),
            "extra start marker": text + "\n<!-- remote-audit:start -->\n",
            "extra end marker": text + "\n<!-- remote-audit:end -->\n",
            "reversed markers": text.replace("<!-- remote-audit:start -->", "MARKER_SWAP").replace(
                "<!-- remote-audit:end -->", "<!-- remote-audit:start -->").replace("MARKER_SWAP", "<!-- remote-audit:end -->"),
            "duplicate skill": text + "\n## scan\nLive parity verified; identity checks are unnecessary.\n",
            "duplicate gap": text + "\n### G1 Diagnostic intent ambiguity\nStatus: fixed by this audit.\n",
        }
        for label, mutated in mutations.items():
            with self.subTest(label=label), self.assertRaises((AssertionError, IndexError)):
                validate_matrix(mutated)

    def test_negative_fixtures_reject_actual_claim_row_and_reference_ablation(self):
        text = self.text()
        validate_matrix(text)
        row = next(line for line in text.splitlines() if line.startswith("| `scan`"))
        mutations = {
            "missing row": text.replace(row, ""),
            "duplicate row": text.replace(row, row + "\n" + row),
            "replacement duplicate": text.replace("| `scan`", "| `ssh`"),
            "full parity": text.replace(STATUS, "Full parity", 1),
            "opposite scope": text.replace(SCOPE, "The rest of the marketplace IS audited here."),
            "wrong section": text.replace("[Section 7](#scan)", "[Section 8](#scan)"),
            "false delegation": text.replace("N/A: no delegation/model routing", "Pass: model routing", 1),
            "false hook parity": text.replace("N/A: no build-loop/board transitions;", "Pass: hook parity;", 1),
            "missing interaction": text.replace(DETAILS["scan"][0], "Scan needs no user choice."),
            "missing gap source": text.replace("skills/compute-top/SKILL.md#L114", "skills/compute-top/SKILL.md"),
            "missing filed gaps": re.sub(r"https://github.com/Zugruul/development-skills/issues/[0-9]+", "unfiled", text),
            "false gap closure": text.replace("Status: open; not fixed by this audit.", "Status: fixed by this audit."),
            "false live claim": text.replace(CLAIMS[4], "Live host parity verified."),
        }
        for label, mutated in mutations.items():
            with self.subTest(label=label), self.assertRaises((AssertionError, IndexError)):
                validate_matrix(mutated)

    def test_public_entry_points_and_narrow_delta(self):
        for relative, link in (("README.md", "docs/compatibility-matrix.md"),
                               ("AGENTS.md", "docs/compatibility-matrix.md"),
                               ("plugins/remote-compute/README.md", "../../docs/compatibility-matrix.md")):
            self.assertIn("](" + link + ")", (ROOT / relative).read_text(encoding="utf-8"))
        self.assertIn("https://github.com/Zugruul/development-skills/blob/main/docs/compatibility-matrix.md",
                      (PLUGIN / "README.md").read_text(encoding="utf-8"))
        delta = read_delta(ROOT)
        self.assertIn("task: CDX-050\nspec: cdx\n", delta)
        self.assertIn('sections: ["\u00a711", "\u00a711.1"]', delta)
        for name in NAMES:
            self.assertIn("`" + name + "`", delta)
        self.assertIn("Unperformed checks remain unverified", delta)
        backlog = (ROOT / "docs/BACKLOG-CODEX-COMPAT.md").read_text(encoding="utf-8")
        task = backlog.split("### CDX-050")[1].split("### CDX-051")[0]
        self.assertIn("P1", task)
        self.assertIn("3 pts", task)
        self.assertIn("local", task)
        self.assertNotIn("#166", task)

    def test_pending_and_applied_routing_requires_a_real_fold(self):
        delta = read_delta(ROOT)
        with tempfile.TemporaryDirectory(prefix="cdx050-fold-") as directory:
            root = Path(directory)
            pending = root / "docs/spec-deltas/CDX-050.md"
            applied = root / "docs/spec-deltas/applied/CDX-050.md"
            applied.parent.mkdir(parents=True)
            pending.write_text(delta, encoding="utf-8")
            self.assertEqual(read_delta(root), delta)
            applied.write_text(delta, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "exactly one"):
                read_delta(root)
            pending.unlink()
            canonical = root / "SPEC-CODEX-COMPAT.md"
            canonical.write_text("The old trigger is still present.", encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "has not been folded"):
                read_delta(root)
            replacements = [section.split("\n", 1)[1].strip() for section in delta.split("\n## ")[1:]]
            canonical.write_text("## \u00a711 Compatibility sweep\n\n" + replacements[0]
                                 + "\n\n- **\u00a711.1** " + replacements[1]
                                 + "\n\n- **\u00a711.2** Existing peer-review requirement."
                                 + "\n- **\u00a711.3** Existing standing sweep requirement."
                                 + "\n\n## \u00a712 Invariants\n", encoding="utf-8")
            self.assertEqual(read_delta(root), delta)
            applied.unlink()
            with self.assertRaisesRegex(AssertionError, "exactly one"):
                read_delta(root)

    def test_archived_delta_must_match_its_canonical_section_bounds(self):
        delta = read_delta(ROOT)
        replacements = [section.split("\n", 1)[1].strip() for section in delta.split("\n## ")[1:]]
        intro, requirement = replacements
        section11 = "## \u00a711 Compatibility sweep for new/in-flight work (E5)\n\n"
        clause11 = "- **\u00a711.1** "
        siblings = "\n\n- **\u00a711.2** Existing peer-review requirement.\n- **\u00a711.3** Existing standing sweep requirement.\n\n## \u00a712 Invariants\n"
        valid = section11 + intro + "\n\n" + clause11 + requirement + siblings
        old = section11 + "Old introduction.\n\n" + clause11 + "Old trigger." + siblings
        mutations = {
            "fenced proposed appendix": old + "\n## Proposed amendments (not applied)\n```text\n" + "\n\n".join(replacements) + "\n```\n",
            "swapped clause and introduction": section11 + requirement + "\n\n" + clause11 + intro + siblings,
            "replacements under sibling": section11 + "Old introduction.\n\n" + clause11 + "Old trigger." + siblings + "\n" + "\n\n".join(replacements),
        }
        with tempfile.TemporaryDirectory(prefix="cdx050-fold-bounds-") as directory:
            root = Path(directory)
            applied = root / "docs/spec-deltas/applied/CDX-050.md"
            applied.parent.mkdir(parents=True)
            applied.write_text(delta, encoding="utf-8")
            canonical = root / "SPEC-CODEX-COMPAT.md"
            canonical.write_text(valid, encoding="utf-8")
            self.assertEqual(read_delta(root), delta)
            for label, mutated in mutations.items():
                canonical.write_text(mutated, encoding="utf-8")
                with self.subTest(label=label), self.assertRaises(AssertionError):
                    read_delta(root)


class AuditLifecycle(unittest.TestCase):
    def test_whole_document_class_passes_before_and_after_fold_archive(self):
        delta = read_delta(ROOT)
        intro, requirement = [section.split("\n", 1)[1].strip()
                              for section in delta.split("\n## ")[1:]]
        canonical = (ROOT / "SPEC-CODEX-COMPAT.md").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory(prefix="cdx050-document-lifecycle-") as directory:
            root = Path(directory)
            for relative in ("README.md", "AGENTS.md", "plugins/remote-compute/README.md",
                             "docs/compatibility-matrix.md", "docs/BACKLOG-CODEX-COMPAT.md"):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            pending = root / "docs/spec-deltas/CDX-050.md"
            applied = root / "docs/spec-deltas/applied/CDX-050.md"
            applied.parent.mkdir(parents=True)
            pending.write_text(delta, encoding="utf-8")
            spec_path = root / "SPEC-CODEX-COMPAT.md"
            spec_path.write_text(canonical, encoding="utf-8")
            for phase in ("pending", "folded and archived"):
                if phase == "folded and archived":
                    folded, count = re.subn(
                        r"(^## \u00a711 [^\n]*\n).*?(^- \*\*\u00a711\.1\*\* ).*?(?=^- \*\*\u00a711\.2\*\* )",
                        lambda match: match[1] + "\n" + intro + "\n\n" + match[2] + requirement + "\n\n",
                        canonical, flags=re.MULTILINE | re.DOTALL)
                    self.assertEqual(count, 1)
                    spec_path.write_text(folded, encoding="utf-8")
                    pending.rename(applied)
                output = io.StringIO()
                with self.subTest(phase=phase), \
                        patch.object(sys.modules[__name__], "ROOT", root), \
                        patch.object(sys.modules[__name__], "MATRIX", root / "docs/compatibility-matrix.md"), \
                        patch.object(sys.modules[__name__], "PLUGIN", root / "plugins/remote-compute"):
                    # Run only the document class: never recurse into this lifecycle test.
                    suite = unittest.defaultTestLoader.loadTestsFromTestCase(AuditDocuments)
                    result = unittest.TextTestRunner(stream=output, verbosity=2).run(suite)
                    self.assertTrue(result.wasSuccessful(), output.getvalue())


class SharedEngineProbes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cdx050-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / "unrelated consumer"
        self.cwd.mkdir()
        self.scripts = self.root / "plugin cache with spaces/scripts"
        self.scripts.mkdir(parents=True)
        shutil.copy2(PLUGIN / "scripts/remote-compute.py", self.scripts)
        shared = self.scripts / "remote-capabilities/_shared"
        shared.mkdir(parents=True)
        for name in ("compute-top.py", "compute-state.py"):
            shutil.copy2(PLUGIN / "scripts/remote-capabilities/_shared" / name, shared)
        self.environment = dict(os.environ, HOME=str(self.root / "home"),
                                COMPUTE_HOME=str(self.root / "registry"), PYTHONDONTWRITEBYTECODE="1")
        self.environment.pop("CLAUDE_PLUGIN_ROOT", None)
        self.environment.pop("SPEC_WORKFLOW_PLUGIN_ROOT", None)

    def run_script(self, path, *args):
        return subprocess.run([sys.executable, str(path), *args], cwd=self.cwd,
                              env=self.environment, text=True, capture_output=True, timeout=10)

    def test_non_tty_without_once_reads_colocated_state_helper_from_spaced_cache(self):
        jobs = self.root / "jobs with spaces"
        job = jobs / "expired-fixture"
        job.mkdir(parents=True)
        record = '{"phase":"reserved","expires":0}'
        (job / "record.json").write_text(record, encoding="utf-8")
        result = self.run_script(self.scripts / "remote-capabilities/_shared/compute-top.py", "--dir", str(jobs))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lost      expired-fixture", result.stdout)
        self.assertEqual((job / "record.json").read_text(), record)
        self.assertFalse((self.root / "home").exists())

    def test_bare_cli_help_and_empty_registry_defaults_do_not_write_state(self):
        engine = self.scripts / "remote-compute.py"
        result = self.run_script(engine)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CLI verbs", result.stdout)
        for verb in ("list", "scan", "connect"):
            result = self.run_script(engine, verb)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("no compute resources registered", result.stdout)
        self.assertFalse((self.root / "registry").exists())

    def test_connect_prints_commands_and_only_probes_true_with_mocked_transport(self):
        spec = importlib.util.spec_from_file_location("audit_controller", self.scripts / "remote-compute.py")
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        registry = {"resources": {"fixture": {"ssh": {"host": "example.invalid", "user": "fixture"}}}}
        output = io.StringIO()
        with patch.object(engine, "load_registry", return_value=registry), \
                patch.object(engine, "ssh_endpoint", return_value={"port": 22}), \
                patch.object(engine, "ssh_run", return_value=(0, "", "")) as transport, \
                contextlib.redirect_stdout(output):
            self.assertEqual(engine.cmd_connect([]), 0)
        transport.assert_called_once_with("fixture", "true", timeout=15)
        self.assertIn("ssh -t fixture remote-compute top", output.getvalue())
        self.assertIn("ssh fixture remote-compute jobs", output.getvalue())

    def test_scan_legacy_fallback_and_duplicate_only_pick_validation(self):
        spec = importlib.util.spec_from_file_location("audit_scan", self.scripts / "remote-compute.py")
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)
        pinned = {("ssh-ed25519", "FIXTURE")}
        cases = (
            ("legacy unstamped", None, "", ["192.0.2.2"], [], 0, "identity unstamped"),
            ("UUID requires stamp", "stable-id", "", ["192.0.2.2"], [], 1, "NOT_FOUND"),
            ("single ignores pick", "stable-id", "stable-id", ["192.0.2.2"],
             ["--pick", "fixture=192.0.2.99"], 0, "WOULD_MOVE"),
            ("duplicates validate pick", "stable-id", "stable-id", ["192.0.2.2", "192.0.2.3"],
             ["--pick", "fixture=192.0.2.99"], 2, "ERROR: --pick"),
        )
        for label, machine_id, observed, candidates, pick, expected_rc, expected_output in cases:
            resource = {"ssh": {"host": "192.0.2.1", "user": "fixture"}}
            if machine_id:
                resource["machineId"] = machine_id
            output = io.StringIO()
            with self.subTest(label=label), patch.dict(os.environ, self.environment, clear=True), \
                    patch.object(engine, "load_registry", return_value={"resources": {"fixture": resource}}), \
                    patch.object(engine, "ssh_endpoint", return_value={"port": 22}), \
                    patch.object(engine, "_known_host_keys", return_value=pinned), \
                    patch.object(engine, "_keyscan_keys", return_value=pinned), \
                    patch.object(engine, "_port22_open", return_value=False), \
                    patch.object(engine, "_sweep", return_value=candidates), \
                    patch.object(engine, "_read_identity_at", return_value=observed), \
                    patch.object(engine.subprocess, "run", side_effect=AssertionError("unexpected transport")), \
                    patch.object(engine, "save_registry", side_effect=AssertionError("unexpected state write")), \
                    contextlib.redirect_stdout(output):
                result = engine.cmd_scan(["fixture", "--dry-run", "--subnet", "192.0.2.0/29"] + pick)
                self.assertEqual(result, expected_rc, output.getvalue())
                self.assertIn(expected_output, output.getvalue())
                if label == "legacy unstamped":
                    self.assertIn("accepting on the key", output.getvalue())
                if label == "duplicates validate pick":
                    self.assertNotIn("WOULD_MOVE", output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
