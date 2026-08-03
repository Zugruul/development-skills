#!/usr/bin/env python3
"""export_gguf.py — merge adapters into a base SLM and export GGUF.

The remote half of the slm-training capability's `export-gguf` job. Loads the
model named by the config (a trained adapter dir from a previous sft job, or
a bare base model), then exports one GGUF per requested quantization via
unsloth's save_pretrained_gguf (which drives llama.cpp's converter inside the
training env — nothing is installed globally on the machine).

Config keys (JSON or YAML):
    base_model      HF id or local path (required)
    adapters        path to a trained adapter dir; omit to export base as-is
    quantizations   list, default ["q8_0"] (e.g. q4_k_m, q5_k_m, q8_0, f16)
    max_seq_length  default 2048
    smoke           OPTIONAL: {prompt, json_schema, max_tokens, llama_server,
                    llama_cli (deprecated)} — see "Smoke test" below. Absent
                    entirely -> no smoke step runs at all (fully backward
                    compatible with pre-smoke configs and callers).

Outputs (in --out, default $COMPUTE_JOB_DIR, else cwd):
    gguf/                   one .gguf per quantization
    export-summary.json     files, sizes, sha256, and (when `smoke` was
                             configured) per-file smoke results — see below.

Smoke test: a caller-requested pre-packaging gate — "smoke-test each
artifact in llama.cpp (load + one JSON-schema-constrained completion) before
it is eligible for packaging." When the config carries a `smoke` section, EVERY
produced GGUF is booted as an llama-server HTTP server and asked to complete
`smoke.prompt` under grammar-constrained decoding against `smoke.json_schema`,
via a `POST /completion` call carrying `json_schema` (confirmed against the
current llama.cpp server docs: "json_schema: Set a JSON schema for
grammar-based sampling") alongside `prompt`, `n_predict`, and
`temperature: 0` — all four documented, stable `/completion` request fields,
not inferred. The server is started fresh per GGUF and ALWAYS terminated
afterward (see run_smoke_for_file's try/finally), so nothing here ever holds
the shared GPU resource lock beyond one file's smoke.

llama-server, not llama-cli (issue #221): the smoke vehicle used to shell
out to llama-cli directly. On the only real GPU box (storm590x),
llama-cli's `--json-schema`/`--json-schema-file` failed at sampler init
("error initializing grammar sampler for grammar:", empty grammar echoed)
identically across three independent llama.cpp builds (shallow master, a
release build, unsloth's own from-source build) even though the schema was
trivially valid and `examples/json_schema_to_grammar.py` converted it
cleanly; routing around that via `--grammar-file` then made llama-cli
busy-loop its interactive "> " prompt forever despite `-no-cnv` AND stdin at
EOF (`</dev/null`), producing hundreds of MB of output with only `timeout`
able to stop it. llama-server has no in-process grammar-sampler init path
(schema handling lives in HTTP request processing, not CLI arg parsing) and
no interactive REPL, so both failure modes are structurally avoided — a
bounded `/health` poll plus an unconditional terminate/kill in `finally`
means a server that never becomes healthy, or that won't die on `terminate()`,
can never become this bug's kind of runaway process. This IS still
"llama.cpp" per the caller's original smoke requirement — llama-server ships
from the exact same build as llama-cli — only the vehicle within llama.cpp
changed.

    smoke.prompt        the single completion prompt (required if smoke set)
    smoke.json_schema   a JSON-Schema object (required if smoke set)
    smoke.max_tokens    default 128 (-> /completion's n_predict)
    smoke.llama_server  default "~/llama.cpp/build/bin/llama-server"; if that
                         path doesn't exist/isn't executable, falls back to
                         DISCOVERY: search (1) the current working directory,
                         then (2) $HOME, each for entries named `llama.cpp*`
                         (sorted alphabetically), and within each such dir
                         try, in order, build/bin/llama-server,
                         build/bin/server, llama-server, server — the first
                         existing+executable path wins. This is where
                         unsloth's own from-source llama.cpp build (used
                         internally by save_pretrained_gguf) typically lands.
    smoke.llama_cli     DEPRECATED alias for smoke.llama_server (issue #221
                         renamed the key when the vehicle changed). When
                         llama_server is absent and llama_cli is given, the
                         llama-server binary is derived from llama_cli's OWN
                         DIRECTORY (both binaries ship from the same
                         build/bin/, so this is a same-search-root
                         substitution, not a guess) — logging a deprecation
                         WARNING — rather than silently using the (wrong,
                         CLI-shaped) llama_cli path itself. If no sibling
                         llama-server/server exists next to the configured
                         llama_cli, resolution falls through to the same
                         DISCOVERY search above (never returns the llama_cli
                         path itself, which run_smoke_for_file cannot use).

Per produced GGUF, smoke records {file, loaded, constrainedOutputRaw
(truncated to 2000 chars), parsedOk} into export-summary.json's
`smoke.perFile` (alongside `smoke.schema`, an echo of smoke.json_schema) —
this SmokeFileResult shape is UNCHANGED by the #221 vehicle switch. `loaded`
is now true iff the llama-server process became healthy (`GET /health`
returned `{"status": "ok"}` within SMOKE_TIMEOUT_SEC) rather than "the CLI
exited 0" — a server that never loads the GGUF (bad file, OOM, wrong arch,
etc.) never reports healthy. `parsedOk` is true iff a JSON object could be
extracted from the `/completion` response's `content` field AND round-trips
through json.loads AND passes a SHALLOW, stdlib-only, TOP-LEVEL-ONLY
structural check against the schema: required keys present, and each present
property whose schema declares a `type` among
{string,number,integer,boolean,array,object,null} matches that type (nested
schemas, $ref, oneOf/anyOf/allOf, and array item schemas are NOT checked —
full JSON-Schema validation is out of scope for a load-bearing smoke gate;
APP-022's eval harness is where real answer-quality validation belongs).
Extraction rule: unlike llama-cli's stdout (which echoed the prompt before
the continuation), llama-server's `content` field is the completion ONLY —
but the extractor still scans for the LAST balanced `{...}` object (brace-
depth counting that ignores braces inside quoted strings) as a defensive
measure against trailing non-JSON tokens, rather than assuming `content` is
bare JSON.

IF `smoke` is configured AND any produced file fails either loaded or
parsedOk THEN this script exits 1 — a GGUF that can't load or produce
parseable constrained output must never look eligible for packaging — but
export-summary.json (including the failing file's real diagnostics) is
still written first, so the failure is auditable rather than discarded.

Exit codes: 0 ok · 1 export/env error (or smoke failure) · 2 config error.
"""
import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

SMOKE_TIMEOUT_SEC = 300  # safety net only, not a config knob: a hung/never-
                          # ready llama-server must not hold the shared GPU
                          # resource lock forever — bounds both the /health
                          # poll and the remaining time given to /completion.
CONSTRAINED_OUTPUT_TRUNCATE = 2000
SMOKE_SERVER_HOST = "127.0.0.1"
SMOKE_SERVER_CTX = 2048  # minimal context relative to real serving — plenty
                          # for the trivial smoke prompt/schema this gate uses.
SMOKE_HEALTH_POLL_INTERVAL_SEC = 0.5
SMOKE_PROCESS_KILL_TIMEOUT_SEC = 10  # bounds terminate()/kill() wait() calls
                                     # in _terminate_server so a stuck process
                                     # can never hang this script itself.
JSON_SCHEMA_TYPE_CHECKS = {
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    # bool is a subclass of int in Python — excluded explicitly so a real
    # bool never satisfies a number/integer type check.
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
    "null": lambda v: v is None,
}


def load_config(path):
    with open(path) as f:
        raw = f.read()
    if path.endswith((".yaml", ".yml")):
        import yaml
        return yaml.safe_load(raw) or {}
    return json.loads(raw)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _search_llama_cpp_dirs(rel_candidates):
    """Shared DISCOVERY search: (1) cwd, then (2) $HOME, each for entries
    named `llama.cpp*` (sorted alphabetically), trying each of
    rel_candidates in order within every such dir — first existing+
    executable path wins. Returns None if nothing matches."""
    for base in (os.getcwd(), os.path.expanduser("~")):
        if not os.path.isdir(base):
            continue
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            if not name.startswith("llama.cpp"):
                continue
            root = os.path.join(base, name)
            for rel in rel_candidates:
                candidate = os.path.join(root, rel)
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
    return None


def resolve_llama_server(smoke_cfg):
    """Returns an existing, executable llama-server path, or None if nothing
    was found. See this module's top doc comment for the exact resolution
    order: configured smoke.llama_server -> derived from the deprecated
    smoke.llama_cli's directory -> the documented default path -> DISCOVERY
    search."""
    configured = smoke_cfg.get("llama_server")
    if not configured:
        legacy_cli = smoke_cfg.get("llama_cli")
        if legacy_cli:
            print("WARNING: smoke.llama_cli is deprecated (issue #221 moved the smoke vehicle "
                  "to llama-server) — use smoke.llama_server instead. Deriving "
                  "llama-server from llama_cli's directory: %s" % legacy_cli)
            configured = os.path.join(os.path.dirname(os.path.expanduser(legacy_cli)), "llama-server")
        else:
            configured = "~/llama.cpp/build/bin/llama-server"
    expanded = os.path.expanduser(configured)
    if os.path.isfile(expanded) and os.access(expanded, os.X_OK):
        return expanded
    print("WARNING: llama_server not found/executable at %s — searching cwd/$HOME for a llama.cpp*/ build" % expanded)
    return _search_llama_cpp_dirs(("build/bin/llama-server", "build/bin/server", "llama-server", "server"))


def find_free_port():
    """Binds an ephemeral port on the loopback interface, releases it, and
    returns the number — a brief TOCTOU race is possible in principle (the
    port could theoretically be grabbed by something else before
    llama-server binds it) but is not a concern for a single-machine,
    single-job-at-a-time smoke step."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((SMOKE_SERVER_HOST, 0))
        return s.getsockname()[1]


def wait_for_health(port, deadline):
    """Polls GET /health until it reports {"status": "ok"} or `deadline`
    (an absolute time.time() value) passes. Any transport error or non-ready
    body (e.g. the documented 503 "Loading model" response) is treated as
    "not ready yet", never a crash — this loop's only job is to bound how
    long the caller waits before giving up."""
    url = "http://%s:%d/health" % (SMOKE_SERVER_HOST, port)
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                if resp.status == 200:
                    body = json.loads(resp.read().decode("utf-8"))
                    if body.get("status") == "ok":
                        return True
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError, ValueError):
            pass
        time.sleep(SMOKE_HEALTH_POLL_INTERVAL_SEC)
    return False


def post_completion(port, prompt, schema, max_tokens, timeout_sec):
    """POSTs the documented llama-server /completion request shape
    ({prompt, json_schema, n_predict, temperature: 0}) and returns the
    parsed JSON response (which carries the generated text in `content`)."""
    url = "http://%s:%d/completion" % (SMOKE_SERVER_HOST, port)
    payload = json.dumps({
        "prompt": prompt,
        "json_schema": schema,
        "n_predict": max_tokens,
        "temperature": 0,
    }).encode("utf-8")
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
        return json.loads(resp.read().decode("utf-8"))


def extract_last_json_object(text):
    """Scans for the LAST balanced {...} object in text (brace-depth
    counting that ignores braces inside quoted strings) and returns the
    substring, or None if no balanced object is found. See this module's
    top doc comment for why "last" and why this is the documented
    extraction rule."""
    depth = 0
    in_string = False
    escape = False
    start = None
    last_start, last_end = None, None
    for i, ch in enumerate(text):
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start is not None:
                    last_start, last_end = start, i + 1
    if last_start is None:
        return None
    return text[last_start:last_end]


def check_schema_shallow(parsed, schema):
    """Shallow, stdlib-only, top-level-only structural check — see this
    module's top doc comment for exactly what is and isn't checked."""
    if schema.get("type") == "object" and not isinstance(parsed, dict):
        return False
    if not isinstance(parsed, dict):
        return True  # nothing further to check without a dict to index into
    for key in schema.get("required", []):
        if key not in parsed:
            return False
    for key, subschema in (schema.get("properties") or {}).items():
        if key not in parsed:
            continue
        expected_type = subschema.get("type") if isinstance(subschema, dict) else None
        checker = JSON_SCHEMA_TYPE_CHECKS.get(expected_type)
        if checker is not None and not checker(parsed[key]):
            return False
    return True


def _terminate_server(proc):
    """Always stops a started llama-server process — terminate(), falling
    back to kill() if it doesn't die within SMOKE_PROCESS_KILL_TIMEOUT_SEC.
    Called from run_smoke_for_file's finally, so this runs on every code
    path (success, health timeout, /completion error) — the exact structural
    guarantee issue #221 asked for: no orphaned/runaway process is possible."""
    if proc is None:
        return
    if proc.poll() is not None:
        return  # already exited on its own
    proc.terminate()
    try:
        proc.wait(timeout=SMOKE_PROCESS_KILL_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=SMOKE_PROCESS_KILL_TIMEOUT_SEC)


def run_smoke_for_file(gguf_path, smoke_cfg, llama_server):
    prompt = smoke_cfg["prompt"]
    schema = smoke_cfg["json_schema"]
    max_tokens = int(smoke_cfg.get("max_tokens") or 128)
    deadline = time.time() + SMOKE_TIMEOUT_SEC
    proc = None
    try:
        port = find_free_port()
        cmd = [llama_server, "-m", gguf_path, "--host", SMOKE_SERVER_HOST,
               "--port", str(port), "-c", str(SMOKE_SERVER_CTX)]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        except OSError as e:
            return {"loaded": False, "constrainedOutputRaw": str(e)[:CONSTRAINED_OUTPUT_TRUNCATE], "parsedOk": False}

        if not wait_for_health(port, deadline):
            return {"loaded": False, "constrainedOutputRaw": "", "parsedOk": False}

        remaining = max(1, deadline - time.time())
        try:
            response = post_completion(port, prompt, schema, max_tokens, remaining)
        except Exception as e:
            return {"loaded": True, "constrainedOutputRaw": str(e)[:CONSTRAINED_OUTPUT_TRUNCATE], "parsedOk": False}

        content = response.get("content") or ""
        raw = content[:CONSTRAINED_OUTPUT_TRUNCATE]
        parsed_ok = False
        candidate = extract_last_json_object(content)
        if candidate is not None:
            try:
                parsed = json.loads(candidate)
            except ValueError:
                parsed = None
            if parsed is not None:
                parsed_ok = check_schema_shallow(parsed, schema)
        return {"loaded": True, "constrainedOutputRaw": raw, "parsedOk": parsed_ok}
    finally:
        _terminate_server(proc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--out", default=None,
                    help="output dir (default: $COMPUTE_JOB_DIR, else cwd)")
    args = ap.parse_args()
    out_dir = args.out or os.environ.get("COMPUTE_JOB_DIR") or "."

    try:
        cfg = load_config(args.config)
    except Exception as e:
        print("ERROR: could not load config %s: %s" % (args.config, e))
        return 2
    base_model = cfg.get("base_model")
    if not base_model:
        print("ERROR: config needs base_model")
        return 2
    adapters = cfg.get("adapters")
    if adapters and adapters.startswith("/mnt/"):
        print("WARNING: adapters under /mnt/* (DrvFs, slow) — prefer ext4 paths")
    quants = cfg.get("quantizations") or ["q8_0"]
    smoke_cfg = cfg.get("smoke")
    if smoke_cfg is not None:
        if not smoke_cfg.get("prompt") or not isinstance(smoke_cfg.get("json_schema"), dict):
            print("ERROR: config.smoke needs both prompt and json_schema (object)")
            return 2

    try:
        import torch  # noqa: F401 — env sanity before the heavy load
        from unsloth import FastLanguageModel
    except ImportError as e:
        print("ERROR: training env not active (torch/unsloth unavailable): %s" % e)
        return 1

    t_start = time.time()
    # loading the adapter dir directly rehydrates base+LoRA in one step (the
    # dir's adapter_config.json names the base); a bare base model exports as-is
    model_name = adapters or base_model
    print("loading %s" % model_name)
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=model_name,
        max_seq_length=int(cfg.get("max_seq_length") or 2048),
        load_in_4bit=False,  # merge/export needs the full-precision weights
    )

    gguf_dir = os.path.join(out_dir, "gguf")
    os.makedirs(gguf_dir, exist_ok=True)
    produced = []
    for quant in quants:
        print("exporting %s…" % quant)
        model.save_pretrained_gguf(gguf_dir, tokenizer, quantization_method=quant)
        # save_pretrained_gguf names files itself — and current unsloth
        # writes them to a SIBLING dir named "<dir>_gguf" (observed live:
        # asked for .../gguf, files landed in .../gguf_gguf). Normalize:
        # move any *.gguf from the sibling into gguf_dir before scanning,
        # so artifacts, manifests, and job-pull all see one canonical dir.
        import shutil
        sibling = gguf_dir + "_gguf"
        if os.path.isdir(sibling):
            for name in sorted(os.listdir(sibling)):
                if name.endswith(".gguf"):
                    shutil.move(os.path.join(sibling, name), os.path.join(gguf_dir, name))
        for name in sorted(os.listdir(gguf_dir)):
            path = os.path.join(gguf_dir, name)
            if name.endswith(".gguf") and all(p["file"] != name for p in produced):
                produced.append({"file": name, "quantization": quant,
                                 "sizeBytes": os.path.getsize(path),
                                 "sha256": sha256_file(path)})
                print("ARTIFACT %s" % path)

    if not produced:
        print("ERROR: no .gguf files were produced")
        return 1

    summary = {
        "baseModel": base_model,
        "adapters": adapters,
        "quantizations": quants,
        "files": produced,
        "wallClockSec": round(time.time() - t_start, 1),
    }

    smoke_failed = False
    if smoke_cfg is not None:
        llama_server = resolve_llama_server(smoke_cfg)
        per_file = []
        for entry in produced:
            gguf_path = os.path.join(gguf_dir, entry["file"])
            if llama_server is None:
                result = {"loaded": False, "constrainedOutputRaw": "", "parsedOk": False}
                print("ERROR: no llama-server binary found (configured/default path missing and discovery found none)")
            else:
                print("smoke-testing %s via %s…" % (entry["file"], llama_server))
                result = run_smoke_for_file(gguf_path, smoke_cfg, llama_server)
            per_file.append({"file": entry["file"], **result})
            if not (result["loaded"] and result["parsedOk"]):
                smoke_failed = True
                print("SMOKE FAIL %s: loaded=%s parsedOk=%s" % (entry["file"], result["loaded"], result["parsedOk"]))
        summary["smoke"] = {"schema": smoke_cfg["json_schema"], "perFile": per_file}

    summary_path = os.path.join(out_dir, "export-summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print("ARTIFACT %s" % summary_path)

    if smoke_failed:
        print("ERROR: one or more GGUFs failed the llama.cpp smoke test — see export-summary.json's smoke.perFile")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
