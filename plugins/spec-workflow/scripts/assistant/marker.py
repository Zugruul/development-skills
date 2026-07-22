"""`.neural-network` marker grammar (SPEC-ASSISTANT.md §6.2).

Per §6.1 the marker is a pure discovery anchor: it carries no assistant
identity/enabled flags (that's the `assistant:` section of project.yaml,
owned by config.py) and its content must never be able to break discovery.
That is why the grammar here is deliberately permissive -- see the
docstrings below for exactly what is tolerated vs. what raises.
"""


def parse_marker(text):
    """Parse `.neural-network` marker text into a dict of key -> value.

    Grammar (§6.2):
      - A line whose first non-whitespace character is '#' is a full-line
        comment and is ignored.
      - Blank / whitespace-only lines are ignored.
      - Any other line containing '=' is a key=value pair: split at the
        FIRST '=', then strip() both the key and the value. A later
        duplicate key overwrites an earlier one (last-wins).
      - A non-comment line WITHOUT '=' is tolerated and skipped -- never a
        parse error (legacy/free-form marker content must not break
        discovery).
      - There are no inline (trailing) comments: in "k=v # c" the value is
        "v # c" verbatim. Values may legitimately contain '#' and '=';
        only full-line comments are grammar.

    Returns ALL parsed keys -- filtering to known keys is caller semantics,
    not the parser's job, so the grammar stays forward-compatible with
    future keys.

    `text` must be a string; there must be SOME content to parse, even if
    that content is the empty string (which yields `{}`, same as any other
    all-comments/all-blank input).
    """
    result = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped[0] == "#":
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def read_marker(path):
    """Read and parse the marker file at `path`.

    Raises FileNotFoundError if `path` does not exist -- presence checks
    are the caller's job, matching existing marker consumers.
    """
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    return parse_marker(text)
