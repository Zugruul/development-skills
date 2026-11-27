#!/usr/bin/env python3
"""schema-lint.py — structural hover-completeness gate for a JSON Schema file.

Human directive (#80): the project-config JSON schema must be fully
documented so editor hover (via the `yaml-language-server: $schema=` line
atop `.neural-network/project.yaml`) shows every key's explanation, possible values,
and defaults. Prose review misses keys; this walks the schema JSON itself
(never greps it -- a grep can't tell a documented property from a bare key
mentioned in a comment) and FAILS on any property or enum that isn't
hover-complete, so a future undocumented key cannot land silently. Mirrors
the schema/validator-parity convention started in #53 (every constraint the
validator enforces must exist in the schema and vice versa) applied to
documentation instead of constraints.

Rules enforced, at every nesting level (`properties`, `patternProperties`,
array `items`, `oneOf`/`anyOf`/`allOf` branches, `if`/`then`/`else`, an
object-valued `additionalProperties`, and `definitions`):
  1. Every property's (or patternProperties entry's) subschema carries a
     NON-EMPTY `description` or `markdownDescription` -- OR, if the
     subschema is a bare `{"$ref": "..."}` (siblings are ignored by $ref per
     draft-07, so a description there would never render), the definition
     it points at carries one instead. `"description": ""` does NOT count --
     that's the undocumented-key case sneaking past under another name.
  2. Every subschema with an `enum` -- wherever it appears, not just as a
     named property -- carries an `enumDescriptions` array of the SAME
     length as `enum`, one line per value (VS Code YAML extension
     convention).

CLI: schema-lint.py <path-to-schema.json>
Exit 0 + "OK" on a clean schema; exit 1 + one "PROBLEMS:"-prefixed line per
finding (also newline-joined for readability) otherwise.
"""
import json
import sys


def _resolve(ref, defs):
    # Only local "#/definitions/<name>" refs occur in this schema family.
    name = ref.rsplit("/", 1)[-1]
    return defs.get(name, {})


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def _has_desc(node):
    if not isinstance(node, dict):
        return False
    return _nonempty_str(node.get("description")) or _nonempty_str(node.get("markdownDescription"))


def _is_bare_ref(node):
    return isinstance(node, dict) and set(node.keys()) == {"$ref"}


def _effective_desc(node, defs):
    if _has_desc(node):
        return True
    if _is_bare_ref(node):
        return _has_desc(_resolve(node["$ref"], defs))
    return False


def _check_enum(node, path, problems):
    if not isinstance(node, dict):
        return
    enum = node.get("enum")
    if not enum:
        return
    descs = node.get("enumDescriptions")
    if not descs or len(descs) != len(enum):
        problems.append(f"{path}: enumDescriptions missing or length mismatch with enum (enum has {len(enum)})")


def _walk(node, path, defs, problems, visited):
    if not isinstance(node, dict):
        return

    if _is_bare_ref(node):
        ref = node["$ref"]
        if ref in visited:
            return
        _walk(_resolve(ref, defs), path, defs, problems, visited | {ref})
        return

    # Centralized: every node visited is enum-checked here, once -- whether
    # it arrived as a named property, a patternProperties entry, an items
    # schema, a oneOf/anyOf/allOf branch, an if/then/else, or an
    # additionalProperties schema. Named-property description-completeness
    # stays keyed to the property loops below (an anonymous node like an
    # `items` schema has nothing to hang a "missing description" on beyond
    # its own enum/nested content).
    _check_enum(node, path, problems)

    props = node.get("properties")
    if isinstance(props, dict):
        for name, sub in props.items():
            p = f"{path}.{name}"
            if not _effective_desc(sub, defs):
                problems.append(f"{p}: missing description")
            _walk(sub, p, defs, problems, visited)

    pattern_props = node.get("patternProperties")
    if isinstance(pattern_props, dict):
        for pattern, sub in pattern_props.items():
            p = f"{path}/patternProperties[{pattern}]"
            if not _effective_desc(sub, defs):
                problems.append(f"{p}: missing description")
            _walk(sub, p, defs, problems, visited)

    items = node.get("items")
    if isinstance(items, dict):
        _walk(items, path + "[]", defs, problems, visited)
    elif isinstance(items, list):
        for i, it in enumerate(items):
            _walk(it, f"{path}[{i}]", defs, problems, visited)

    for comb in ("oneOf", "anyOf", "allOf"):
        branches = node.get(comb)
        if isinstance(branches, list):
            for i, sub in enumerate(branches):
                _walk(sub, f"{path}/{comb}[{i}]", defs, problems, visited)

    for kw in ("if", "then", "else"):
        sub = node.get(kw)
        if isinstance(sub, dict):
            _walk(sub, f"{path}/{kw}", defs, problems, visited)

    ap = node.get("additionalProperties")
    if isinstance(ap, dict):
        _walk(ap, path + "/additionalProperties", defs, problems, visited)


def lint(schema):
    problems = []
    defs = schema.get("definitions", {}) if isinstance(schema, dict) else {}
    _walk(schema, "$", defs, problems, set())
    # Definitions are walked implicitly wherever a $ref reaches them, but a
    # definition with no referrer (or an unreferenced sub-branch) would
    # otherwise escape coverage -- walk each one directly too, under its own
    # path, so nothing in `definitions` can hide.
    for name, d in defs.items():
        _walk(d, f"definitions.{name}", defs, problems, set())
    return problems


def main(argv):
    if len(argv) != 2:
        print("usage: schema-lint.py <path-to-schema.json>", file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        schema = json.load(f)
    problems = lint(schema)
    if problems:
        print(f"PROBLEMS: {len(problems)} finding(s):")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
