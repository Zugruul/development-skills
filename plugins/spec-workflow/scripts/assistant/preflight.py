"""Preflight assistant checks with enumerated failures (SPEC-ASSISTANT.md §6.6,
AST-006, issue #306).

Per §6.6 the preflight verifies, for each discovered assistant: the config
parses/validates, and each enabled capability's bin resolves AND is
authenticated -- with an enumerated, specific message per failure mode. Per
§17.1 this module NEVER invokes an LLM completion: authentication is checked
via each CLI's own status subcommand (`codex login status`, `claude auth
status --json`), always under a timeout, never a turn/completion call.

Discovery here is intentionally minimal (§7.1's full discovery UX is
AST-020/E2): this module only inspects the ONE given `root` -- marker
presence (`.claude/.neural-network`, reused via assistant.marker.read_marker)
plus a valid, enabled `assistant:` section of project.yaml. Per §6.2 a
marker with no assistant section is not an error -- that repo is simply not
an assistant repo, reported as an informational line, not a FAIL.

Auth probes (verified against the CLIs installed on the dev machine, see
module history / PR report for the exact `--help` transcripts):
  - codex:       `<bin> login status`            -- rc 0 == logged in.
  - claude-code: `<bin> auth status --json`       -- rc 0 AND (no parseable
                 JSON, OR JSON has no "loggedIn" key, OR JSON["loggedIn"] is
                 true) counts as authenticated. A JSON body with
                 "loggedIn": false is the one positive signal Claude Code
                 gives for "authenticated but logged out"; everything else
                 falls back to the process exit code, which is what every
                 other CLI convention (including codex's) uses.
Capabilities other than these two known names have no auth probe defined
(no known provider maps to them yet, per assistant.config.PROVIDER_CAPABILITY)
-- their bin is still resolved and must exist, but no auth check runs.

Positive-path caching (§6.6 AC: "positive path cached"): a successful verdict
is cached per assistant name, keyed by a hash of the assistant section's
content plus every enabled capability's resolved bin path, with a
CACHE_TTL_SECONDS TTL. A cache hit skips the subprocess auth probes entirely
(the expensive part); bin resolution via shutil.which is always re-checked
(cheap, no subprocess). Any config or bin-PATH change invalidates the cache
(the hash changes); an in-place binary swap at the SAME resolved path is not
detected until the TTL lapses (path-keyed, not content-keyed -- deliberate,
matching common local dev tooling). Negative verdicts are NEVER cached --
only "all enabled capabilities resolved + authenticated" is written. A cache
write failure (read-only state dir) degrades the cache only; the verdict is
still reported.

Cache location: <state_dir>/assistant-preflight-cache.json, where state_dir
defaults to <root>/.claude/neural-view/ (already gitignored, per
local-state.manifest and setup.py's set_default) and can be overridden via
the NEURAL_VIEW_STATE env var (tests) exactly like setup.py.set_default.

Library:
    preflight_lines(root, state_dir=None, probe_timeout=5.0) -> list[str]
        One or more advisory lines for `root`, or [] when there's no marker
        at all (zero noise for non-assistant repos).

CLI: `preflight.py <root>` prints each line, always exits 0 (advisory only,
matching preflight.sh's contract -- see preflight.sh's own header comment).
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

_SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Force scripts/ to the FRONT of sys.path, not merely present: when this
# script is run under preflight.sh (which exports PYTHONPATH=scripts/),
# scripts/ is already somewhere in sys.path, but Python has ALSO
# auto-prepended this script's own directory (scripts/assistant/) at index
# 0 -- and scripts/assistant/ contains its own same-named config.py
# (assistant.config, a different module). An `if _SCRIPTS_DIR not in
# sys.path: insert(...)` guard (setup.py's original pattern, copied here)
# is a no-op in that case, so `import config` below silently resolves to
# assistant/config.py instead of the real scripts/config.py. Unconditionally
# moving scripts/ to index 0 avoids the shadow regardless of what already
# put it on sys.path.
if _SCRIPTS_DIR in sys.path:
    sys.path.remove(_SCRIPTS_DIR)
sys.path.insert(0, _SCRIPTS_DIR)

import config as project_config  # noqa: E402  scripts/config.py, the shared loader
from assistant import marker  # noqa: E402
from assistant.config import validate_assistant  # noqa: E402

MARKER_NAME = ".neural-network"
STATE_DIR_REL = os.path.join(".claude", "neural-view")  # already gitignored (manifest)
CACHE_FILE_NAME = "assistant-preflight-cache.json"
CACHE_TTL_SECONDS = 3600  # 1h -- see module docstring

# capability name -> auth probe spec. `args` is appended to the resolved bin
# path; `ok` inspects (rc, stdout) and returns True iff authenticated.
_PROVIDER_MISMATCH_MARKER = "requires capabilities."


def _claude_auth_ok(rc, out):
    try:
        data = json.loads(out)
    except (ValueError, TypeError):
        data = None
    if isinstance(data, dict) and "loggedIn" in data:
        return bool(data["loggedIn"])
    return rc == 0


AUTH_PROBES = {
    "codex": {
        "args": ["login", "status"],
        "ok": lambda rc, out: rc == 0,
        "login_cmd": "codex login",
    },
    "claude-code": {
        "args": ["auth", "status", "--json"],
        "ok": _claude_auth_ok,
        "login_cmd": "claude auth login",
    },
}


def _dig(d, *keys):
    node = d
    for k in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(k)
    return node


def _which(bin_name):
    """shutil.which, but tolerant of a bin_name that isn't a plain string."""
    if not isinstance(bin_name, str) or not bin_name.strip():
        return None
    return shutil.which(bin_name)


def _state_dir(root):
    return os.environ.get("NEURAL_VIEW_STATE") or os.path.join(root, STATE_DIR_REL)


def _cache_path(root, state_dir=None):
    return os.path.join(state_dir or _state_dir(root), CACHE_FILE_NAME)


def _load_cache(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_cache_atomic(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".assistant-preflight-cache-tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _cache_key(assistant_section, bin_paths):
    payload = json.dumps(assistant_section, sort_keys=True, default=str) + "\n" + json.dumps(
        sorted(bin_paths.items()), sort_keys=True
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _run_probe(bin_path, args, timeout):
    try:
        proc = subprocess.run(
            [bin_path] + args, capture_output=True, text=True, timeout=timeout
        )
        return proc.returncode, proc.stdout
    except (subprocess.TimeoutExpired, OSError):
        return 1, ""


def preflight_lines(root, state_dir=None, probe_timeout=5.0):
    marker_path = os.path.join(root, ".claude", MARKER_NAME)
    if not os.path.isfile(marker_path):
        return []  # no marker at all -- not a candidate, zero noise

    # Presence-only reuse of assistant.marker per §6.1: the marker itself
    # carries no assistant identity/enabled flags, so its parsed content is
    # never consulted below -- only that the file exists and is readable.
    try:
        marker.read_marker(marker_path)
    except OSError as e:
        return [f"assistant preflight FAIL: {root}: cannot read marker: {e}"]

    cfg_path = project_config.find_config(root)
    if cfg_path is None:
        return [
            f"assistant preflight: {root}: marker present, no assistant section "
            "(not an assistant repo)"
        ]

    try:
        cfg = project_config.load_config(root=root, path=cfg_path, warn=False)
    except project_config.ConfigError as e:
        return [f"assistant preflight FAIL: {root}: invalid assistant section: cannot parse config: {e}"]
    except OSError as e:
        # review r2: PermissionError et al. are OSError, not ConfigError -- an
        # unreadable config must be an enumerated FAIL line, never a traceback
        # (preflight is advisory-only; the parent script never checks rc).
        return [f"assistant preflight FAIL: {root}: cannot read config: {e}"]

    assistant_section = (cfg or {}).get("assistant")
    if assistant_section is None:
        return [
            f"assistant preflight: {root}: marker present, no assistant section "
            "(not an assistant repo)"
        ]

    errs = validate_assistant(assistant_section)
    if errs:
        provider_errs = [e for e in errs if _PROVIDER_MISMATCH_MARKER in e]
        other_errs = [e for e in errs if _PROVIDER_MISMATCH_MARKER not in e]
        lines = []
        if other_errs:
            lines.append(f"assistant preflight FAIL: {root}: invalid assistant section: {other_errs[0]}")
        if provider_errs:
            lines.append(f"assistant preflight FAIL: {root}: provider mismatch: {provider_errs[0]}")
        return lines

    if assistant_section.get("enabled") is not True:
        return [
            f"assistant preflight: {root}: marker present, assistant section present "
            "but not enabled (assistant.enabled: true required) (not an assistant repo)"
        ]

    names = assistant_section.get("names") or ["assistant"]
    main_name = names[0]
    provider = _dig(assistant_section, "llm", "provider")
    caps = assistant_section.get("capabilities") or {}
    enabled = sorted(
        (name, entry) for name, entry in caps.items()
        if isinstance(entry, dict) and entry.get("enabled") is True
    )

    failures = []
    bin_paths = {}
    for cap_name, entry in enabled:
        bin_name = _dig(entry, "provisioning", "bin") or cap_name
        resolved = _which(bin_name)
        if resolved is None:
            failures.append(
                f"assistant preflight FAIL: {root}: capability '{cap_name}' bin '{bin_name}' "
                f"not found on PATH — install it or fix "
                f"assistant.capabilities.{cap_name}.provisioning.bin"
            )
            continue
        bin_paths[cap_name] = resolved

    cache_path = _cache_path(root, state_dir)
    key = _cache_key(assistant_section, bin_paths)
    cache = _load_cache(cache_path)
    entry = cache.get(main_name)
    cache_hit = (
        isinstance(entry, dict)
        and entry.get("key") == key
        and (time.time() - float(entry.get("ts", 0))) < CACHE_TTL_SECONDS
    )

    if not failures and not cache_hit:
        for cap_name, bin_path in bin_paths.items():
            probe = AUTH_PROBES.get(cap_name)
            if probe is None:
                continue  # unknown capability type -- no auth probe defined
            rc, out = _run_probe(bin_path, probe["args"], probe_timeout)
            if not probe["ok"](rc, out):
                failures.append(
                    f"assistant preflight FAIL: {root}: {cap_name} ('{bin_path}') not "
                    f"authenticated — run '{probe['login_cmd']}'"
                )

    if failures:
        return failures  # negative verdicts are NEVER cached

    cache[main_name] = {"key": key, "ts": time.time()}
    try:
        _write_cache_atomic(cache_path, cache)
    except OSError:
        # review r2: an unwritable state dir (read-only mount, CI sandbox)
        # degrades the CACHE only -- the verdict must still be reported.
        pass
    return [f"assistant preflight ok: {main_name} ({provider}, {len(enabled)} capabilities)"]


def _cli(argv):
    if len(argv) < 1:
        sys.stderr.write("usage: preflight.py <root>\n")
        return 2
    for line in preflight_lines(argv[0]):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
