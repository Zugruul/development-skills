#!/usr/bin/env python3
"""eval_suite.py — run a config-defined eval suite against an SLM.

The remote half of the slm-training capability's `eval` job. Loads a base
model (optionally with trained adapters), generates deterministically for
every item, checks each item's expectation, and writes a machine-readable
result file. The suite definition is entirely the caller's: this script
knows how to generate and check, never what any project's answers should be.

Config keys (JSON or YAML):
    model        {base_model (required), adapters, max_seq_length: 2048,
                  load_in_4bit: true}
    generation   {max_new_tokens: 256, temperature: 0.0}
                 temperature 0 (default) means greedy decoding — evals are
                 deterministic unless a config explicitly opts out.
    items        [{id, prompt | messages, expect: {contains: [..] |
                  regex: ".." | equals: ".." | one_of: [..]}}]
                 every listed check must hold for the item to pass
    fail_under   optional fraction; exit 1 when score < fail_under
                 (release-gate style — the artifact is still written)

Outputs (in --out, default $COMPUTE_JOB_DIR, else cwd):
    eval-results.json    {items: [{id, passed, checks, response}], passed,
                          total, score}

Exit codes: 0 ok (or score >= fail_under) · 1 env error / below fail_under ·
2 config error.
"""
import argparse
import json
import os
import re
import sys
import time


def load_config(path):
    with open(path) as f:
        raw = f.read()
    if path.endswith((".yaml", ".yml")):
        import yaml
        return yaml.safe_load(raw) or {}
    return json.loads(raw)


def check_expect(expect, response):
    """Every check present in `expect` must hold. Returns [(check, ok), ...]."""
    results = []
    if "contains" in expect:
        needles = expect["contains"]
        if isinstance(needles, str):
            needles = [needles]
        for needle in needles:
            results.append(("contains:%s" % needle, needle in response))
    if "regex" in expect:
        results.append(("regex:%s" % expect["regex"],
                        re.search(expect["regex"], response) is not None))
    if "equals" in expect:
        results.append(("equals", response.strip() == str(expect["equals"]).strip()))
    if "one_of" in expect:
        results.append(("one_of", response.strip() in [str(o).strip() for o in expect["one_of"]]))
    if not results:
        results.append(("no-checks-declared", False))
    return results


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
    model_cfg = cfg.get("model") or {}
    base_model = model_cfg.get("base_model")
    items = cfg.get("items") or []
    if not base_model or not items:
        print("ERROR: config needs model.base_model and a non-empty items list")
        return 2

    try:
        import torch  # noqa: F401
        from unsloth import FastLanguageModel
    except ImportError as e:
        print("ERROR: training env not active (torch/unsloth unavailable): %s" % e)
        return 1

    t_start = time.time()
    model_name = model_cfg.get("adapters") or base_model
    print("loading %s" % model_name)
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=model_name,
        max_seq_length=int(model_cfg.get("max_seq_length") or 2048),
        load_in_4bit=bool(model_cfg.get("load_in_4bit", True)),
    )
    FastLanguageModel.for_inference(model)

    gen = cfg.get("generation") or {}
    temperature = float(gen.get("temperature") or 0.0)
    gen_kwargs = {
        "max_new_tokens": int(gen.get("max_new_tokens") or 256),
        "do_sample": temperature > 0,
    }
    if temperature > 0:
        gen_kwargs["temperature"] = temperature

    results = []
    for item in items:
        item_id = item.get("id") or "item-%d" % len(results)
        messages = item.get("messages") or [{"role": "user", "content": item.get("prompt") or ""}]
        inputs = tokenizer.apply_chat_template(
            messages, tokenize=True, add_generation_prompt=True,
            return_tensors="pt").to(model.device)
        output = model.generate(input_ids=inputs, **gen_kwargs)
        response = tokenizer.decode(output[0][inputs.shape[1]:], skip_special_tokens=True)
        checks = check_expect(item.get("expect") or {}, response)
        passed = all(ok for _, ok in checks)
        results.append({"id": item_id, "passed": passed,
                        "checks": [{"check": c, "ok": ok} for c, ok in checks],
                        "response": response})
        print("%s %s" % ("PASS" if passed else "FAIL", item_id))

    passed = sum(1 for r in results if r["passed"])
    score = passed / len(results)
    report = {"items": results, "passed": passed, "total": len(results),
              "score": round(score, 4), "model": model_name,
              "wallClockSec": round(time.time() - t_start, 1)}
    os.makedirs(out_dir, exist_ok=True)
    report_path = os.path.join(out_dir, "eval-results.json")
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    print("ARTIFACT %s" % report_path)
    print("score %d/%d = %.2f" % (passed, len(results), score))

    fail_under = cfg.get("fail_under")
    if fail_under is not None and score < float(fail_under):
        print("ERROR: score %.4f is below fail_under %.4f" % (score, float(fail_under)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
