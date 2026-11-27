#!/usr/bin/env python3
"""Structural check of evals/**/case.yaml (schema_version 1.1). Requires PyYAML."""
import glob
import os
import sys

import yaml

GRADER_TYPES = {"regex", "tool_order", "tool_used", "file_exists", "llm", "baseline"}
plugin = os.path.join(os.path.dirname(__file__), "..")
fails = 0
cases = sorted(glob.glob(os.path.join(plugin, "evals", "*", "case.yaml")))
if not cases:
    sys.exit("no eval cases found")
for f in cases:
    try:
        d = yaml.safe_load(open(f))
        assert d["schema_version"] == "1.1", "schema_version must be '1.1'"
        assert d["name"], "missing name"
        assert d["execution"].get("prompt"), "missing execution.prompt"
        graders = d["graders"]
        assert graders, "graders must be non-empty"
        names = [g["name"] for g in graders]
        assert len(names) == len(set(names)), "duplicate grader names"
        for g in graders:
            assert g["type"] in GRADER_TYPES, f"unknown grader type {g['type']!r}"
        print(f"ok   {d['name']} ({len(graders)} graders)")
    except Exception as e:  # noqa: BLE001
        print(f"FAIL {f}: {e}")
        fails += 1
sys.exit(1 if fails else 0)
