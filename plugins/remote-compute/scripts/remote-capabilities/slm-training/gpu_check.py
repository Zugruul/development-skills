#!/usr/bin/env python3
"""gpu_check.py — fast sanity probe for the slm-training capability's env.

Run under the machine's declared training env (torch + unsloth). Prints one
line per fact and writes gpu-check.json into the per-job dir (COMPUTE_JOB_DIR,
falling back to --out or the cwd) so `remote-compute job-pull` retrieves a
machine-readable record. Exit codes: 0 ok · 1 CUDA unavailable / env broken.

Every claim comes from real torch calls — nothing is assumed (remote-compute
hard rule 4). The matmul timing is a smoke signal ("did a kernel actually
run"), not a benchmark.
"""
import argparse
import json
import os
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None,
                    help="output dir (default: $COMPUTE_JOB_DIR, else cwd)")
    args = ap.parse_args()
    out_dir = args.out or os.environ.get("COMPUTE_JOB_DIR") or "."

    report = {}
    try:
        import torch
    except ImportError as e:
        print("ERROR: torch not importable — is the training env activated? (%s)" % e)
        return 1
    report["torch"] = torch.__version__
    print("torch %s" % torch.__version__)

    report["cudaAvailable"] = torch.cuda.is_available()
    if not torch.cuda.is_available():
        print("ERROR: torch.cuda.is_available() is False")
        _write(out_dir, report)
        return 1

    report["device"] = torch.cuda.get_device_name(0)
    report["archList"] = torch.cuda.get_arch_list()
    free_b, total_b = torch.cuda.mem_get_info()
    report["vramTotalMB"] = total_b // (1024 * 1024)
    report["vramFreeMB"] = free_b // (1024 * 1024)
    print("device %s" % report["device"])
    print("archs %s" % " ".join(report["archList"]))
    print("vram total=%dMB free=%dMB" % (report["vramTotalMB"], report["vramFreeMB"]))

    n = 2048
    a = torch.randn(n, n, device="cuda")
    b = torch.randn(n, n, device="cuda")
    torch.cuda.synchronize()
    t0 = time.time()
    c = a @ b
    torch.cuda.synchronize()
    report["matmulMs"] = round((time.time() - t0) * 1000, 2)
    report["matmulChecksum"] = float(c.sum())
    print("matmul %dx%d ok in %sms" % (n, n, report["matmulMs"]))

    try:
        import unsloth
        report["unsloth"] = unsloth.__version__
        print("unsloth %s" % unsloth.__version__)
    except ImportError as e:
        # recorded, not fatal: gpu-check answers "can a kernel run", the
        # sft/export/eval jobs are what genuinely require unsloth
        report["unslothError"] = str(e)
        print("WARNING: unsloth not importable: %s" % e)

    _write(out_dir, report)
    return 0


def _write(out_dir, report):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "gpu-check.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=2)
    print("ARTIFACT %s" % path)


if __name__ == "__main__":
    sys.exit(main())
