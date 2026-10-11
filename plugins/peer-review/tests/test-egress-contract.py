"""Offline checks of #529's pending/folded contract and the shipped dispatcher."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
PLUGIN = ROOT / "plugins/peer-review"
CHANGED = {"Preamble", "1", "2", "3", "4", "5", "7", "8", "9", "10", "11", "12"}


def sections(text):
    # Only the peer spec's existing level-two section format is needed here.
    pieces = re.split(r"(?m)^(## §(\d+(?:\.\d+)*)[^\n]*\n)", text)
    result = {"Preamble": pieces[0]}
    for index in range(1, len(pieces), 3):
        result[pieces[index + 1]] = pieces[index] + pieces[index + 2]
    return result


def effective_contract(canonical, delta):
    current = sections(canonical)
    if delta is None:
        return current
    assert delta.startswith("---\n"), "pending delta needs frontmatter"
    metadata = delta.split("---", 2)[1]
    assert re.search(r"(?m)^task: ['\"]?529['\"]?$", metadata)
    assert re.search(r"(?m)^spec: peer$", metadata)
    declared = re.search(r"(?m)^sections: (.+)$", metadata)
    assert declared, "pending delta needs affected sections"
    assert set(json.loads(declared[1])) == {
        "Preamble" if key == "Preamble" else "§" + key for key in CHANGED
    }
    blocks = re.split(r"(?m)^## (Preamble|§\d+) [^\n]*MODIFIED\n", delta)[1:]
    replacements = dict(zip(blocks[::2], blocks[1::2]))
    assert {key.removeprefix("§") for key in replacements} == CHANGED, "incomplete delta"
    for key, body in replacements.items():
        key = key.removeprefix("§")
        assert body.strip(), "empty replacement"
        if key != "Preamble":
            assert body.lstrip().startswith("## §" + key + " "), "paste-ready heading missing"
        current[key] = body.strip() + "\n"
    return current


def normalized(text):
    return " ".join(text.lower().replace("`", "").split())


def require_clause(text, pattern):
    # Match the approved wording within one clause, never across unrelated disclaimers.
    clauses = re.split(r"[.;:]", normalized(text))
    assert any(re.fullmatch(pattern, clause.strip(" *-")) for clause in clauses), (
        "missing authority clause: " + pattern
    )


def disclosure(text):
    text = normalized(text)
    for pattern in (
        r"openai (?:through|via) (?:the user-installed )?codex(?: cli)?, "
        r"or anthropic (?:through|via) (?:the user-installed )?claude(?: cli)?",
        r"the user's cli configuration owns authentication and transport, "
        r"including (?:any )?configured endpoints? or intermediar(?:y|ies)",
        r"the cli may read and send repository context beyond the diff",
        r"the plugin enforces no destination allowlist",
        r"(?:codex's --sandbox read-only and claude's --permission-mode plan "
        r"protect intended review edits|review uses codex's --sandbox read-only or "
        r"claude's --permission-mode plan to constrain intended review edits|"
        r"these flags constrain intended review edits), not network isolation",
        r"(?:there is no plugin token-redaction guarantee|"
        r"provider errors and raw fallback output are forwarded, without a plugin "
        r"token-redaction guarantee|the plugin does not guarantee token redaction)",
        r"(?:ssh registration does not authorize peer http transmission, grant consent "
        r"to send a diff, or validate a model endpoint|ssh registration does not authorize "
        r"peer http endpoints or token transmission|registration does not authorize "
        r"peer http endpoints or transmission)",
    ):
        require_clause(text, pattern)
    for pattern in (
        r"cloud", r"not a security sandbox", r"no (?:shipped )?(?:peer )?http dispatcher",
    ):
        assert re.search(pattern, text), "missing disclosure: " + pattern


def invariants(text):
    text = normalized(text)
    for stale in (".claude/compute-registry.yaml", "registry token fields",
                  "resolved token values never appear", "content leaves the machine only"):
        assert stale not in text, "stale active invariant: " + stale
    for pattern in (
        r"external transmission (?:to openai/codex and anthropic/claude is disclosed|"
        r"is disclosed for both openai/codex and anthropic/claude), including possible "
        r"repository context beyond the diff",
        r"the user's cli configuration owns transport",
        r"the plugin enforces no destination allowlist",
        r"these flags constrain intended review edits, not network isolation",
        r"ssh-machine registration grants no peer http authority",
        r"(?:provider errors and raw fallback output are forwarded, so no plugin "
        r"redaction guarantee is asserted|peer review adds no credential store "
        r"or token-redaction guarantee)",
    ):
        require_clause(text, pattern)
    for required in ("codex", "claude", "--sandbox read-only", "--permission-mode plan",
                     "secrets", "git", "disclos", "source", "persistent", "bash 3.2",
                     "stdlib", "shellcheck", "transport", "configuration"):
        assert required in text, "missing invariant: " + required


def contract_checks(contract):
    disclosure(contract["5"])
    invariants(contract["9"])
    for key in ("Preamble", "1", "2", "3", "4", "7", "8", "10", "11", "12"):
        text = normalized(contract[key])
        assert "deferred" in text, "E1 status missing in section " + key
        assert "unimplemented" in text, "E1 implementation status missing in section " + key
    authority = normalized(contract["5"] + contract["7"])
    for required in ("providers.tsv", "executable configuration", "~/.remote-compute/resources.yaml",
                     "redirect", "redaction", "token"):
        assert required in authority, "missing authority boundary: " + required
    require_clause(contract["7"],
                   r"ssh registration does not authorize http model endpoints or token transmission")
    for key in ("7", "8"):
        assert "historical" in normalized(contract[key])
        for number in range(1, 6):
            assert "§" + key + "." + str(number) in contract[key], "lost historical requirement"
    assert "default applied" not in normalized(contract["12"])


class EgressContract(unittest.TestCase):
    def setUp(self):
        self.canonical = (ROOT / "SPEC-PEER-REVIEW.md").read_text()
        pending = ROOT / "docs/spec-deltas/529.md"
        self.delta = pending.read_text() if pending.exists() else None

    def effective(self):
        return effective_contract(self.canonical, self.delta)

    def test_effective_contract_before_and_after_fold(self):
        effective = self.effective()
        contract_checks(effective)
        # The exact same assertions run on a simulated canonical fold, without a delta.
        folded = "\n".join(effective.values())
        contract_checks(effective_contract(folded, None))
        for key in ("6", "6.11", "6.12"):
            self.assertEqual(effective[key], sections(self.canonical)[key])

    def test_empty_or_incomplete_delta_is_rejected(self):
        for bad in ("", "---\ntask: 529\nspec: peer\n---\n", "arbitrary bypass text"):
            with self.subTest(delta=bad), self.assertRaises(AssertionError):
                effective_contract(self.canonical, bad)

    def test_stale_invariant_is_rejected(self):
        effective = self.effective()
        effective["9"] += "\nContent leaves the machine only to endpoints explicitly declared in .claude/compute-registry.yaml.\n"
        with self.assertRaisesRegex(AssertionError, "stale active invariant"):
            invariants(effective["9"])

    def test_wrong_and_missing_disclosures_are_rejected(self):
        good = self.effective()["5"]
        disclosure(good)
        for bad in ("", good.replace("Anthropic", "OtherVendor").replace("anthropic", "other"),
                    good.replace("context beyond", "diff only")):
            with self.subTest(disclosure=bad[:40]), self.assertRaises(AssertionError):
                disclosure(bad)

    def test_reversed_authority_is_rejected_before_and_after_fold(self):
        effective = self.effective()
        contract_checks(effective)
        mutations = (
            ("5", "OpenAI through Codex, or Anthropic through Claude.",
             "Anthropic through Codex, or OpenAI through Claude."),
            ("5", "The user's CLI configuration owns authentication and transport",
             "The user's CLI configuration does not own authentication and transport"),
            ("5", "there is no plugin token-redaction guarantee.",
             "The plugin guarantees token redaction."),
            ("5", "the plugin enforces no destination allowlist.",
             "The plugin enforces a destination allowlist."),
            ("5", "The CLI may read and send repository context beyond the diff.",
             "The CLI never sends repository context beyond the diff."),
            ("5", "Codex's `--sandbox read-only` and Claude's `--permission-mode plan` "
             "protect intended review edits, not network isolation.",
             "Review flags enforce network isolation."),
            ("5", "SSH registration does not authorize peer HTTP transmission, "
             "grant consent to send a diff, or validate a model endpoint.",
             "SSH registration authorizes peer HTTP transmission."),
            ("9", "OpenAI/Codex and Anthropic/Claude",
             "Anthropic/Codex and OpenAI/Claude"),
            ("9", "The user's CLI configuration owns transport",
             "The user's CLI configuration does not own authentication and transport"),
            ("9", "no plugin redaction guarantee is asserted.",
             "The plugin guarantees token redaction."),
            ("9", "the plugin enforces no destination allowlist.",
             "The plugin enforces a destination allowlist."),
            ("9", "including possible repository context beyond the diff.",
             "including no repository context beyond the diff."),
            ("9", "These flags constrain intended review edits, not network isolation.",
             "Review flags enforce network isolation."),
            ("9", "SSH-machine registration grants no peer HTTP authority.",
             "SSH-machine registration grants peer HTTP authority."),
            ("5", "there is no plugin token-redaction guarantee.", ""),
            ("9", "no plugin redaction guarantee is asserted.", ""),
        )
        for section, original, replacement in mutations:
            changed = dict(effective)
            pattern = r"\s+".join(re.escape(word) for word in original.split())
            changed[section], count = re.subn(pattern, replacement, changed[section])
            self.assertEqual(count, 1, "mutation must alter exactly one documented statement")
            # Serialize both forms so the same mutations still run after the delta is folded.
            keys = [key for key in changed if key in CHANGED]
            labels = ["Preamble" if key == "Preamble" else "§" + key for key in keys]
            pending = "---\ntask: 529\nspec: peer\nsections: " + json.dumps(labels) + "\n---\n"
            pending += "\n".join("## " + label + " - MODIFIED\n\n" + changed[key]
                                 for key, label in zip(keys, labels))
            for form, canonical, delta in (
                ("pending", self.canonical, pending),
                ("folded", "\n".join(changed.values()), None),
            ):
                parsed = effective_contract(canonical, delta)
                with self.subTest(section=section, replacement=replacement, form=form):
                    with self.assertRaises(AssertionError):
                        contract_checks(parsed)

    def test_registered_invariants(self):
        result = subprocess.run(
            ["python3", str(ROOT / "plugins/spec-workflow/scripts/config.py"), str(ROOT), "json"],
            capture_output=True, text=True, check=True,
        )
        peer = next(item for item in json.loads(result.stdout)["specs"] if item["id"] == "peer")
        invariants(" ".join(peer["invariants"]))
        self.assertIn("deferred", peer["epics"][1]["title"].lower())

    def test_public_disclosures_and_history(self):
        for path in ("plugins/peer-review/README.md", "plugins/peer-review/skills/peer-review/SKILL.md"):
            with self.subTest(path=path):
                disclosure((ROOT / path).read_text())
        for path in ("README.md", "AGENTS.md"):
            text = normalized((ROOT / path).read_text())
            for phrase in ("anthropic", "context beyond", "transport", "no peer http dispatcher"):
                with self.subTest(path=path, phrase=phrase):
                    self.assertTrue(phrase in text, "missing summary boundary: " + phrase)
        for path in ("docs/BACKLOG-PEER-REVIEW.md", "docs/design/compute-registry-plan-v3.md"):
            text = normalized((ROOT / path).read_text())
            for phrase in ("superseded", "deferred", "unimplemented", "peer-egress-authority.md"):
                with self.subTest(path=path, phrase=phrase):
                    self.assertTrue(phrase in text, "missing historical status: " + phrase)


class ShippedRouting(unittest.TestCase):
    def test_both_providers_and_refusal_paths(self):
        with tempfile.TemporaryDirectory(prefix="peer-529-") as temporary:
            fixture = Path(temporary)
            binaries = fixture / "bin"
            binaries.mkdir()
            log = fixture / "args.json"
            env = {"PATH": str(binaries) + ":/usr/bin:/bin", "HOME": temporary,
                   "ARGLOG": str(log), "LC_ALL": "C.UTF-8"}
            # Use real git diff and real provider wrappers; only the cloud CLIs are fake.
            subprocess.run(["git", "init", "-q", temporary], env=env, check=True)
            (fixture / "review.txt").write_text("review-529-marker\n")
            subprocess.run(["git", "-C", temporary, "add", "review.txt"], env=env, check=True)
            fake = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
Path(os.environ["ARGLOG"]).write_text(json.dumps(sys.argv))
result = {"findings": [], "verdict": "fixture review"}
if Path(sys.argv[0]).name == "claude":
    result = {"structured_output": result, "is_error": False}
print(json.dumps(result))
'''
            for provider in ("codex", "claude"):
                binary = binaries / provider
                binary.write_text(fake)
                binary.chmod(0o755)

            def dispatch(*args, extra=None):
                return subprocess.run(
                    ["bash", str(PLUGIN / "scripts/provider-dispatch.sh"), *args],
                    cwd=fixture, env=dict(env, **(extra or {})), capture_output=True, text=True,
                )

            for provider, mode, value in (("codex", "--sandbox", "read-only"),
                                          ("claude", "--permission-mode", "plan")):
                result = dispatch(provider, "run", "--", "--staged", "--model", "fixture-model")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("External review", result.stdout)
                self.assertIn(provider, result.stdout.lower())
                args = json.loads(log.read_text())
                self.assertEqual(Path(args[0]).name, provider)
                self.assertEqual(args[args.index(mode) + 1], value)
                self.assertIn("fixture-model", args)
                self.assertIn("review-529-marker", args[-1])
                self.assertEqual((fixture / "review.txt").read_text(), "review-529-marker\n")
                log.unlink()

            for args, extra, code, message in (
                (("unknown-529", "run"), {}, 2, "unknown provider: unknown-529"),
                (("codex", "run"), {"PEER_REVIEW_PROVIDERS_FILE": str(fixture / "absent.tsv")},
                 1, "provider registry not found"),
            ):
                result = dispatch(*args, extra=extra)
                self.assertEqual(result.returncode, code)
                self.assertIn(message, result.stderr)
                self.assertFalse(log.exists(), "refusal must not invoke either CLI")
            missing = fixture / "missing.tsv"
            missing.write_text("missing\tMissing backend\t\tabsent.sh\n")
            result = dispatch("missing", "run", extra={"PEER_REVIEW_PROVIDERS_FILE": str(missing)})
            self.assertEqual(result.returncode, 1)
            self.assertIn("registered script not found", result.stderr)
            self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
