#!/usr/bin/env bash
# section-remote-compute.sh -- sourced by run-tests.sh; do not run standalone.
# Hermetic tests for scripts/remote-compute.py (remote-compute skill): probe
# parsers against captured fixtures, registration convergence via a scripted
# fake transport, allocation writer idempotence, lock semantics, dispatch
# job-state recovery from files alone. No network, no real ssh, ever.
# shellcheck disable=SC2088  # quoted tildes are payloads for the REMOTE shell (bash -lc expands them there), never the local one
# shellcheck disable=SC2153  # FIX is set by run-tests.sh before sourcing; CFIX is derived from it, not a typo
# shellcheck disable=SC2016  # $HOME in an expected-value string is LITERAL on purpose: the assertion checks that the payload sent to the remote carries the unexpanded "$HOME" for the REMOTE shell to expand
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== remote-compute =="

COMPUTE="$PLUGIN/scripts/remote-compute.py"
CFIX="$FIX/compute"
CSTUB="$FIX/stub-compute-transport"
chmod +x "$CSTUB"/* 2>/dev/null

# --- probe parsers (pure, stdin -> JSON) --------------------------------
out="$(python3 "$COMPUTE" parse gpu < "$CFIX/nvidia-smi.txt")"
check "gpu parser: name" "NVIDIA GeForce RTX 5090" "$out"
check "gpu parser: vramMB" '"vramMB": 24463' "$out"
check "gpu parser: cuda" '"cuda": "13.3"' "$out"
check "gpu parser: driver" '"driver": "610.62"' "$out"
out="$(python3 "$COMPUTE" parse gpu-csv < "$CFIX/nvidia-smi-csv.txt")"
check "gpu-csv: full untruncated name" "NVIDIA GeForce RTX 5090 Laptop GPU" "$out"
check "gpu-csv: vramMB" '"vramMB": 24463' "$out"
check "gpu-csv: driver" '"driver": "610.62"' "$out"
out="$(python3 "$COMPUTE" parse gpu < "$CFIX/nvidia-smi.txt")"
check "gpu parser: WSL KMD/UMD header yields cuda" '"cuda": "13.3"' "$out"
check "gpu parser: WSL KMD header yields driver" '"driver": "610.62"' "$out"
out="$(python3 "$COMPUTE" parse df < "$CFIX/df-hpt.txt")"
check "df -T: marks 9p slow" '"mount": "/mnt/c", "freeGB": 720, "slow": true' "$out"
check "df -T: marks drvfs slow" '"mount": "/mnt/f", "freeGB": 122, "slow": true' "$out"
check "df -T: ext4 not slow" '"mount": "/", "freeGB": 876' "$out"
check_absent "df -T: drops WSL pseudo-mounts" "/mnt/wslg" "$out"
out="$(python3 "$COMPUTE" parse free < "$CFIX/free-g.txt")"
check "free parser: ramGB" '"ramGB": 96' "$out"
out="$(python3 "$COMPUTE" parse df < "$CFIX/df-h.txt")"
check "df parser: freeGB" '"freeGB": 410' "$out"
check "df parser: drvfs slow" '"slow": true' "$out"
out="$(python3 "$COMPUTE" parse profiler < "$CFIX/system-profiler.txt")"
check "profiler parser: chip" "Apple M3 Max" "$out"
check "profiler parser: mps" '"mps": true' "$out"
# hard rule 4: mps must be DERIVED from the output, not asserted. An Intel Mac
# with an AMD GPU must not be claimed as MPS-capable.
out="$(printf 'Graphics/Displays:\n\n    AMD Radeon Pro 5500M:\n\n      Chipset Model: AMD Radeon Pro 5500M\n' | python3 "$COMPUTE" parse profiler)"
check "profiler parser: non-Apple GPU is not claimed as mps" '"mps": false' "$out"
check "profiler parser: still reports the real chip" "AMD Radeon Pro 5500M" "$out"

# --- shared hermetic environment ----------------------------------------
CT="$(mktemp -d)"
CH="$CT/compute-home"; SSHDIR="$CT/sshdir"; mkdir -p "$SSHDIR"
TLOG="$CT/transport.log"; : > "$TLOG"
HANDLER="$CT/handler.sh"
run_compute() {
    COMPUTE_HOME="$CH" COMPUTE_SSH_CONFIG="$SSHDIR/config" \
    COMPUTE_SSH_BIN="$CSTUB/ssh" COMPUTE_NC_BIN="$CSTUB/nc" \
    COMPUTE_KEYSCAN_BIN="$CSTUB/ssh-keyscan" COMPUTE_RSYNC_BIN="$CSTUB/rsync" \
    COMPUTE_PING_BIN="$CSTUB/ping" \
    FAKE_TRANSPORT_LOG="$TLOG" FAKE_SSH_HANDLER="$HANDLER" FIXDIR="$CFIX" \
    python3 "$COMPUTE" "$@"
}
cat > "$HANDLER" <<'EOF'
#!/usr/bin/env bash
# happy-path remote: WSL2 linux box with an RTX 5090, zsh, torch env ok
CMD="${!#}"
case "$CMD" in
    *query-gpu*) cat "$FIXDIR/nvidia-smi-csv.txt" ;;
    *nvidia-smi*) cat "$FIXDIR/nvidia-smi.txt" ;;
    *"free -g"*) cat "$FIXDIR/free-g.txt" ;;
    *df\ *|*"df -"*) cat "$FIXDIR/df-hpt.txt" ;;
    *SHELL*) echo /usr/bin/zsh ;;
    *uname*) echo Linux ;;
    *proc/version*) echo "Linux version 6.6.36 microsoft-standard-WSL2" ;;
    *torch*) echo "2.7.1 True" ;;
    *busy1*) echo __RUNNING__ ;;
    *exitcode*) echo 0 ;;
    *) exit 0 ;;
esac
EOF

# --- register: unreachable host stops early ------------------------------
out="$(FAKE_NC_RC=1 run_compute register gpubox testuser@192.0.2.17 2>&1)"; rc=$?
check "register unreachable: message" "UNREACHABLE" "$out"
check_rc "register unreachable: exit 1" 1 "$rc"

# --- register: key auth missing -> stop with exact ssh-copy-id line ------
cat > "$CT/keyfail.sh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
out="$(FAKE_SSH_HANDLER="$CT/keyfail.sh" COMPUTE_HOME="$CH" COMPUTE_SSH_CONFIG="$SSHDIR/config" \
    COMPUTE_SSH_BIN="$CSTUB/ssh" COMPUTE_NC_BIN="$CSTUB/nc" COMPUTE_KEYSCAN_BIN="$CSTUB/ssh-keyscan" \
    COMPUTE_RSYNC_BIN="$CSTUB/rsync" FAKE_TRANSPORT_LOG="$TLOG" FIXDIR="$CFIX" \
    python3 "$COMPUTE" register gpubox testuser@192.0.2.17 --accept-hostkey 2>&1)"; rc=$?
check "register keyfail: NEEDS_KEY_AUTH" "NEEDS_KEY_AUTH" "$out"
check "register keyfail: exact ssh-copy-id" "ssh-copy-id testuser@192.0.2.17" "$out"
check_rc "register keyfail: exit 3" 3 "$rc"

# --- register: unknown host key -> ack required (fresh known_hosts) ------
mkdir -p "$CT/sshdir2"
out="$(COMPUTE_SSH_CONFIG="$CT/sshdir2/config" COMPUTE_HOME="$CH" \
    COMPUTE_SSH_BIN="$CSTUB/ssh" COMPUTE_NC_BIN="$CSTUB/nc" COMPUTE_KEYSCAN_BIN="$CSTUB/ssh-keyscan" \
    COMPUTE_RSYNC_BIN="$CSTUB/rsync" FAKE_TRANSPORT_LOG="$TLOG" FAKE_SSH_HANDLER="$HANDLER" FIXDIR="$CFIX" \
    python3 "$COMPUTE" register gpubox testuser@192.0.2.17 2>&1)"; rc=$?
check "register hostkey: NEEDS_HOSTKEY_ACK" "NEEDS_HOSTKEY_ACK" "$out"
check_rc "register hostkey: exit 4" 4 "$rc"

# --- register: happy path (with hostkey ack) -----------------------------
out="$(run_compute register gpubox testuser@192.0.2.17 --accept-hostkey 2>&1)"; rc=$?
check_rc "register: exit 0" 0 "$rc"
check "register: REGISTERED line" "REGISTERED gpubox" "$out"
check "register: hostkey recorded" "ssh-ed25519" "$(cat "$SSHDIR/known_hosts" 2>/dev/null)"
reg="$(cat "$CH/resources.yaml")"
check "registry: gpu name" "NVIDIA GeForce RTX 5090" "$reg"
check "registry: vram" "24463" "$reg"
check "registry: cuda version" "13.3" "$reg"
check "registry: wsl platform" "windows-wsl2" "$reg"
check "registry: zsh shell" "zsh" "$reg"
check "registry: slow drvfs mount" "slow" "$reg"
# on WSL, free reports the VM's allotment (typically half the host's RAM) --
# label it, so a 94GB reading on a 192GB machine is not a wrong-looking claim
check "registry: RAM scope labelled on WSL" "wsl2-vm" "$reg"
check "registry: icmpBlocked recorded from a real probe" "icmpBlocked" "$reg"
check "gate stays hermetic: ping goes through the stub seam" "ping " "$(cat "$TLOG")"
check "ssh config: alias block" "Host gpubox" "$(cat "$SSHDIR/config")"
check "ssh config: hostname" "HostName 192.0.2.17" "$(cat "$SSHDIR/config")"
# hard rule 1 is per-INVOCATION: assert EVERY ssh and EVERY rsync carries the
# hardening, not merely that it appears somewhere in the log
_unhardened_ssh="$(grep '^ssh ' "$TLOG" | grep -cv 'BatchMode=yes' || true)"
check "transport: every ssh invocation is BatchMode" "0" "$_unhardened_ssh"
check "transport: BatchMode always" "-o BatchMode=yes" "$(cat "$TLOG")"
check "transport: remote job layout converged" ".remote-compute/jobs" "$(cat "$TLOG")"

# --- register: idempotent convergence (consistent setup every run) -------
out="$(run_compute register gpubox 2>&1)"; rc=$?
check_rc "re-register: exit 0" 0 "$rc"
check "re-register: single ssh-config block" "1" "$(grep -c '^Host gpubox$' "$SSHDIR/config")"
check "re-register: single registry entry" "1" "$(grep -c 'name: gpubox' "$CH/resources.yaml")"

# --- list / status -------------------------------------------------------
out="$(run_compute list 2>&1)"
check "list: shows resource" "gpubox" "$out"

# --- exec: payload runs, sudo rejected -----------------------------------
out="$(run_compute exec gpubox -- echo hi 2>&1)"; rc=$?
check_rc "exec: exit 0" 0 "$rc"
# exec has two legitimate shapes and must handle both:
#  - multiple argv words: quoting must be PRESERVED (python -c 'import os; print(1)'
#    must not be re-split by the remote shell)
#  - one argument that is already a whole command line: it must pass through,
#    not be quoted into a single unrunnable command name
: > "$TLOG"
run_compute exec gpubox -- python -c 'import os; print(1)' >/dev/null 2>&1
check "exec preserves quoting across argv words" "import os; print(1)" "$(cat "$TLOG")"
: > "$TLOG"
run_compute exec gpubox -- 'ls ~/.remote-compute/jobs' >/dev/null 2>&1
check "exec passes a single command-line argument through" "bash -lc 'ls ~/.remote-compute/jobs'" "$(cat "$TLOG")"
out="$(run_compute exec gpubox -- sudo apt install foo 2>&1)"; rc=$?
check "exec sudo: rejected" "sudo" "$out"
check_rc "exec sudo: exit 5" 5 "$rc"

# --- enable: advertises the resource via the gitignored local overlay ----
REPO="$CT/repo"; mkdir -p "$REPO/.claude"
cp "$FIX/valid.project.yaml" "$REPO/.claude/project.yaml"
out="$(run_compute enable gpubox --root "$REPO" --role training 2>&1)"; rc=$?
check_rc "enable: exit 0" 0 "$rc"
check "enable: AVAILABLE line" "AVAILABLE gpubox" "$out"
check "enable: says non-exclusive" "non-exclusive" "$out"
pyl="$(cat "$REPO/.claude/project.local.yaml")"
check "enable: writes the LOCAL overlay" "compute:" "$pyl"
check "enable: alias-keyed map" "gpubox:" "$pyl"
check "enable: enabled true" "enabled: true" "$pyl"
check "enable: role" "training" "$pyl"
check "enable: snapshot vram" "24463" "$pyl"
check_absent "enable: no host leaked" "192.0.2.17" "$pyl"
check_absent "enable: committed project.yaml untouched" "compute:" "$(cat "$REPO/.claude/project.yaml")"
run_compute enable gpubox --root "$REPO" --role training >/dev/null 2>&1
check "re-enable: single entry" "1" "$(grep -c 'gpubox:' "$REPO/.claude/project.local.yaml")"
check "enable: committed config still VALID" "VALID" "$(python3 "$PLUGIN/scripts/validate-config.py" "$REPO/.claude/project.yaml" 2>&1)"
# config.py merges the overlay: compute is readable through the ONE loader
check "overlay: merged read via config.py" "training" "$(python3 "$PLUGIN/scripts/config.py" "$REPO" get compute.resources.gpubox.roles.0)"
check "overlay: enabled flag merged" "true" "$(python3 "$PLUGIN/scripts/config.py" "$REPO" get compute.resources.gpubox.enabled)"
# non-allowlisted overlay keys are deliberately ignored (no silent override)
printf 'project:\n    name: hacked-by-overlay\n' >> "$REPO/.claude/project.local.yaml"
check "overlay: non-allowlisted key ignored" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$REPO" get project.name)"
# a missing local file is the normal case, never an error
REPO2="$CT/repo2"; mkdir -p "$REPO2/.claude"
cp "$FIX/valid.project.yaml" "$REPO2/.claude/project.yaml"
check "overlay: absent file is fine" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$REPO2" get project.name)"
# a SECOND project can enable the same machine — availability is not exclusive
out="$(run_compute enable gpubox --root "$REPO2" --role inference 2>&1)"; rc=$?
check_rc "enable second project: exit 0" 0 "$rc"
check "enable second project: entry present" "gpubox:" "$(cat "$REPO2/.claude/project.local.yaml")"
check "first project untouched by second enable" "training" "$(cat "$REPO/.claude/project.local.yaml")"
# disable keeps the entry, capability-style
out="$(run_compute disable gpubox --root "$REPO2" 2>&1)"; rc=$?
check_rc "disable: exit 0" 0 "$rc"
check "disable: entry kept with enabled false" "enabled: false" "$(cat "$REPO2/.claude/project.local.yaml")"

# --- lock semantics ------------------------------------------------------
run_compute lock gpubox --holder alice --reason training >/dev/null 2>&1
out="$(run_compute dispatch gpubox --workdir "~/train" --cmd "python train.py" --holder bob --job-id j1 2>&1)"; rc=$?
check "dispatch locked: refused loudly" "LOCKED" "$out"
check "dispatch locked: names holder" "alice" "$out"
check_rc "dispatch locked: nonzero" 6 "$rc"
out="$(run_compute unlock gpubox --force 2>&1)"
check "force-unlock: warns with prior holder" "alice" "$out"

# --- dispatch + job state recovered from files alone ---------------------
out="$(run_compute dispatch gpubox --workdir "~/train" --cmd "python train.py" --holder bob --job-id j1 2>&1)"; rc=$?
check_rc "dispatch: exit 0" 0 "$rc"
check "dispatch: job id echoed" "j1" "$out"
check "dispatch: state file exists" "j1" "$(ls "$CH/jobs")"
# assert on THIS dispatch only (a cumulative log makes "bash -lc" trivially
# present); pin the detached-launch shape, not merely that ssh ran
: > "$TLOG"
run_compute dispatch gpubox --workdir "~/train" --cmd "python train.py" --holder bob --job-id jshape >/dev/null 2>&1
check "dispatch: launches detached (tmux else setsid)" "tmux new-session -d" "$(cat "$TLOG")"
check "dispatch: writes exitcode for file-only recovery" "exitcode" "$(cat "$TLOG")"
check "dispatch: exports COMPUTE_JOB_DIR for artifacts" "COMPUTE_JOB_DIR" "$(cat "$TLOG")"
out="$(run_compute dispatch gpubox --workdir "~/train" --cmd "sudo python train.py" --holder bob --job-id j2 2>&1)"; rc=$?
check_rc "dispatch sudo: exit 5" 5 "$rc"
out="$(run_compute job-status j1 2>&1)"
check "job-status: recovered from files" "completed" "$out"
# artifacts are pulled from the job's OWN remote dir, not a shared workdir
: > "$TLOG"; run_compute job-pull j1 --dest "$CT/pulled" >/dev/null 2>&1
check "job-pull: pulls the per-job dir" ".remote-compute/jobs/j1" "$(cat "$TLOG")"
check_absent "job-pull: not the shared workdir" ":~/train/" "$(cat "$TLOG")"
# maxConcurrentJobs is enforced, not advisory (two agents share one GPU)
run_compute dispatch gpubox --workdir "~/train" --cmd "sleep 1" --holder bob --job-id busy1 >/dev/null 2>&1
out="$(run_compute dispatch gpubox --workdir "~/train" --cmd "sleep 1" --holder bob --job-id busy2 2>&1)"; rc=$?
check "concurrency: second job refused at the limit" "maxConcurrentJobs" "$out"
check_rc "concurrency: exit 6" 6 "$rc"
check "concurrency: names the running job" "busy1" "$out"
# stop simulating busy1 as in-flight so later sections see an idle resource
grep -v 'busy1' "$HANDLER" > "$HANDLER.new" && mv "$HANDLER.new" "$HANDLER"
run_compute unlock gpubox --force >/dev/null 2>&1

# --- declared envs: named activations, probe-verified ---------------------
out="$(run_compute add-env gpubox training --activate 'source ~/.venv/bin/activate' \
    --verify 'import torch; print(torch.__version__, torch.cuda.is_available())' 2>&1)"; rc=$?
check_rc "add-env: exit 0" 0 "$rc"
out="$(run_compute envs gpubox 2>&1)"
check "envs: lists declared env" "training" "$out"
check "envs: shows activate line" "source ~/.venv/bin/activate" "$out"
out="$(run_compute probe gpubox 2>&1)"
check "probe: verifies env from real output" "2.7.1" "$out"
check "envs: verification recorded in registry" "2.7.1" "$(cat "$CH/resources.yaml")"
out="$(run_compute add-env gpubox evil --activate 'sudo su' 2>&1)"; rc=$?
check_rc "add-env: sudo activate rejected" 5 "$rc"

# hard rule 3: a probe is READ-ONLY. Creating the remote job layout belongs to
# register's convergence, not to probe/enable/add-env.
: > "$TLOG"; run_compute probe gpubox >/dev/null 2>&1
check_absent "probe is read-only: no mkdir on the remote" "mkdir" "$(cat "$TLOG")"
# hard rule 2 defence in depth: a hand-edited env activate must not smuggle
# sudo into a dispatched command
run_compute add-env gpubox tainted --activate "source ~/ok/bin/activate" >/dev/null 2>&1
python3 - "$CH/resources.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p))
d["resources"]["gpubox"]["envs"]["tainted"]["activate"] = "sudo -i"
yaml.safe_dump(d, open(p, "w"), default_flow_style=False, sort_keys=False, indent=4)
PY
out="$(run_compute dispatch gpubox --workdir "~/w" --cmd "echo hi" --env tainted --job-id tainted1 2>&1)"; rc=$?
check "hand-edited sudo activate refused at dispatch" "sudo" "$out"
check_rc "hand-edited sudo activate: exit 5" 5 "$rc"

# --- capability bundles: the core stays domain-agnostic -------------------
# A bundle is DATA (manifest + payload) that the generic engine installs; the
# engine must learn nothing about any specific domain to support a new one.
BUNDLE="$CT/demo-cap"; mkdir -p "$BUNDLE"
cat > "$BUNDLE/capability.yaml" <<'EOF'
version: 1
name: demo
description: A fake capability proving the engine is domain-agnostic
payload:
-   runner.py
jobs:
    greet:
        description: Greet someone
        cmd: python3 {capdir}/runner.py --who {who}
        params:
            who: "[A-Za-z ]+"
EOF
printf '#!/usr/bin/env python3\nprint("hi")\n' > "$BUNDLE/runner.py"
out="$(run_compute install-capability gpubox "$BUNDLE" 2>&1)"; rc=$?
check_rc "install-capability: exit 0" 0 "$rc"
check "install-capability: reports the capability" "demo" "$out"
check "install-capability: rsyncs the payload" "remote-compute/caps/demo" "$(cat "$TLOG")"
# rsync spawns its own ssh: without -e it bypasses BatchMode, the pinned
# known_hosts and COMPUTE_SSH_CONFIG entirely (can block on a password prompt)
_unhardened_rsync="$(grep '^rsync ' "$TLOG" | grep -cv 'BatchMode=yes' || true)"
check "transport: every rsync carries a hardened -e ssh" "0" "$_unhardened_rsync"
check "install-capability: declares bundle jobs" "demo:greet" "$(run_compute jobs gpubox 2>&1)"
check "install-capability: records it on the resource" "demo" "$(run_compute capabilities gpubox 2>&1)"
out="$(run_compute run gpubox demo:greet --param 'who=World' --job-id capjob 2>&1)"; rc=$?
check_rc "bundle job runs: exit 0" 0 "$rc"
check "bundle job: capdir resolved in remote cmd" "remote-compute/caps/demo/runner.py" "$(cat "$TLOG")"
# a bundle that tries to smuggle sudo is refused at install time
BADB="$CT/bad-cap"; mkdir -p "$BADB"
cat > "$BADB/capability.yaml" <<'EOF'
version: 1
name: bad
jobs:
    nuke:
        cmd: sudo rm -rf /
EOF
out="$(run_compute install-capability gpubox "$BADB" 2>&1)"; rc=$?
check_rc "install-capability: sudo bundle rejected" 5 "$rc"
# the shipped comfyui bundle is a real bundle, not engine code
check "comfyui ships as a bundle manifest" "name: comfyui" "$(cat "$PLUGIN/scripts/remote-capabilities/comfyui/capability.yaml")"
check_absent "engine has no comfy code" "comfy" "$(grep -iv '^#' "$PLUGIN/scripts/remote-compute.py" | grep -i comfy)"

# --- shipped slm-training bundle: installs, declares, refuses bad params --
# Same contract as the demo bundle above, but against the REAL shipped
# bundle: install end to end through the fake transport, assert the
# declared training:<job> roster, and prove a hostile param value is
# refused by its declared pattern before anything reaches a shell.
SLMB="$PLUGIN/scripts/remote-capabilities/slm-training"
out="$(run_compute install-capability gpubox "$SLMB" 2>&1)"; rc=$?
check_rc "slm-training: install exit 0" 0 "$rc"
check "slm-training: payload rsynced" "remote-compute/caps/slm-training" "$(cat "$TLOG")"
jobs_out="$(run_compute jobs gpubox 2>&1)"
check "slm-training: declares sft" "slm-training:sft" "$jobs_out"
check "slm-training: declares export-gguf" "slm-training:export-gguf" "$jobs_out"
check "slm-training: declares eval" "slm-training:eval" "$jobs_out"
check "slm-training: declares gpu-check" "slm-training:gpu-check" "$jobs_out"
check "slm-training: recorded on the resource" "slm-training" "$(run_compute capabilities gpubox 2>&1)"
out="$(run_compute run gpubox slm-training:sft --param 'config=cfg.yaml; rm -rf /' --job-id slm1 2>&1)"; rc=$?
check "slm-training: hostile config param refused" "ERROR" "$out"
check_rc "slm-training: bad param exit 2" 2 "$rc"
out="$(run_compute run gpubox slm-training:sft --param 'config=configs/tiny-sft.yaml' --job-id slm2 2>&1)"; rc=$?
check_rc "slm-training: sft dispatches" 0 "$rc"
check "slm-training: capdir resolved in remote cmd" "remote-compute/caps/slm-training/train.py" "$(cat "$TLOG")"
check "slm-training: runs under the training env" "activate" "$(cat "$TLOG")"
run_compute unlock gpubox --force >/dev/null 2>&1
# the bundle must stay project-agnostic (any project brings its own config)
# and the engine must know nothing about the training domain
check_absent "slm-training payload is project-agnostic" "fab" \
    "$(grep -rhi 'fabrary\|fab-cli\|fab-app' "$SLMB")"
check_absent "engine has no training-domain code" "unsloth" \
    "$(grep -iv '^#' "$PLUGIN/scripts/remote-compute.py" | grep -i 'unsloth\|slm-training')"

# --- APP-021 (fab-cli issue #133): export_gguf.py's llama.cpp smoke-test
# extension to the export-gguf job (optional `smoke` config section). No
# python executes in this hermetic suite, so what's provable here is that
# capability.yaml is still valid (install succeeds) and the job roster is
# unchanged — the smoke logic itself (grammar-constrained decoding, JSON
# extraction, shallow schema check) is exercised by fab-cli's own pipeline
# test suite and the real 5090 run, not here.
out="$(run_compute install-capability gpubox "$SLMB" 2>&1)"; rc=$?
check_rc "slm-training: install exit 0 after APP-021 smoke extension" 0 "$rc"
jobs_out="$(run_compute jobs gpubox 2>&1)"
check "slm-training: job roster unchanged after APP-021 (sft)" "slm-training:sft" "$jobs_out"
check "slm-training: job roster unchanged after APP-021 (export-gguf)" "slm-training:export-gguf" "$jobs_out"
check "slm-training: job roster unchanged after APP-021 (eval)" "slm-training:eval" "$jobs_out"
check "slm-training: job roster unchanged after APP-021 (gpu-check)" "slm-training:gpu-check" "$jobs_out"
check "slm-training: capability.yaml documents the optional smoke section" "smoke" \
    "$(cat "$SLMB/capability.yaml")"
run_compute unlock gpubox --force >/dev/null 2>&1

# --- declared jobs: capability-style dispatch by intent -------------------
# A resource declares named jobs (template + schema-validated params, like
# capability.yaml invoke); `run` maps a job name to a real detached dispatch.
out="$(run_compute add-job gpubox gen-duck --workdir "~/comfy" \
    --cmd "python run_workflow.py --workflow workflows/duck3d.json --prompt {prompt}" \
    --description "Generate a 3D duck via the pre-authored ComfyUI workflow template" \
    --param "prompt:[A-Za-z0-9 ._-]+" 2>&1)"; rc=$?
check_rc "add-job: exit 0" 0 "$rc"
out="$(run_compute jobs gpubox 2>&1)"
check "jobs: lists declared job" "gen-duck" "$out"
check "jobs: shows description" "3D duck" "$out"
out="$(run_compute add-job gpubox evil --workdir "~" --cmd "sudo rm -rf /tmp/x" 2>&1)"; rc=$?
check_rc "add-job: sudo template rejected" 5 "$rc"
out="$(run_compute run gpubox gen-duck --param "prompt=a rubber duck" --job-id j3 2>&1)"; rc=$?
check_rc "run: exit 0" 0 "$rc"
check "run: dispatched declared job" "j3" "$out"
check "run: rendered param into remote cmd" "a rubber duck" "$(cat "$TLOG")"
# {jobdir} is an engine-supplied placeholder: it must be REPLACED with the
# job's real remote dir, never passed through literally
: > "$TLOG"
run_compute add-job gpubox jobdir-probe --workdir "~/w" --cmd "echo out={jobdir}" >/dev/null 2>&1
run_compute run gpubox jobdir-probe --job-id jd1 >/dev/null 2>&1
check "run: {jobdir} substituted with the job dir" 'out="$HOME"/.remote-compute/jobs/jd1' "$(cat "$TLOG")"
check_absent "run: {jobdir} never passed through literally" "out={jobdir}" "$(cat "$TLOG")"
# a newline is allowed by the permissive [^`$;|&<>]+ patterns, so quoting --
# not the regex -- is what stops it becoming a second command
: > "$TLOG"
run_compute add-job gpubox quote-probe --workdir "~/w" --cmd "echo {v}" --param 'v:[^`$;|&<>]+' >/dev/null 2>&1
run_compute run gpubox quote-probe --param "v=$(printf 'a\nrm -rf /tmp/x')" --job-id q1 >/dev/null 2>&1
# quoting neutralizes the newline in place rather than removing it, so assert
# the UNQUOTED form never appears: quoted renders `echo '...'a`, a regression
# renders bare `echo a` followed by a live newline
check_absent "param values are shell-quoted, not just regex-checked" "echo a" "$(cat "$TLOG")"
out="$(run_compute run gpubox gen-duck --param "prompt=x; rm -rf /" --job-id j4 2>&1)"; rc=$?
check "run: param failing pattern rejected" "ERROR" "$out"
check_rc "run: bad param exit 2" 2 "$rc"
out="$(run_compute run gpubox gen-duck --job-id j5 2>&1)"; rc=$?
check "run: missing required param named" "prompt" "$out"
check_rc "run: missing param exit 2" 2 "$rc"
out="$(run_compute run gpubox no-such-job 2>&1)"; rc=$?
check "run: unknown job names available ones" "gen-duck" "$out"
check_rc "run: unknown job exit 2" 2 "$rc"
check "run: declared job recoverable like any job" "completed" "$(run_compute job-status j3 2>&1)"

# --- comfy-run helper: prompt substitution only, never graph composition --
out="$(python3 - "$PLUGIN/scripts/remote-capabilities/comfyui/comfy-run.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("comfyrun", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
wf = {"1": {"class_type": "KSampler", "inputs": {}},
      "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "old"}}}
nid = m.substitute_prompt(wf, "a rubber duck")
print(nid, wf["2"]["inputs"]["text"])
try:
    m.substitute_prompt({"1": {"class_type": "X", "inputs": {}}}, "y")
    print("NOKEYERR")
except KeyError:
    print("KEYERR")
PY
)"
check "comfy-run: substitutes first CLIPTextEncode" "2 a rubber duck" "$out"
check "comfy-run: refuses when no prompt node exists" "KEYERR" "$out"
out="$(python3 - "$PLUGIN/scripts/remote-capabilities/comfyui/comfy-run.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("comfyrun", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
wf = {"3": {"class_type": "CLIPTextEncode", "inputs": {"text": "p"}, "_meta": {"title": "PositivePrompt"}},
      "4": {"class_type": "CLIPTextEncode", "inputs": {"text": "n"}, "_meta": {"title": "NegativePrompt"}},
      "7": {"class_type": "Seed", "inputs": {"value": 42}, "_meta": {"title": "Seed"}}}
m.apply_set(wf, "PositivePrompt.text=new pos")
m.apply_set(wf, "Seed.value=123")
print(wf["3"]["inputs"]["text"], type(wf["7"]["inputs"]["value"]).__name__, wf["7"]["inputs"]["value"])
try:
    m.apply_set(wf, "Nope.text=x")
except KeyError as e:
    print("KEYERR names available:", "PositivePrompt" in str(e))
PY
)"
check "comfy-run: set by node title" "new pos" "$out"
check "comfy-run: int inputs stay ints" "int 123" "$out"
check "comfy-run: unknown node errors naming titles" "KEYERR names available: True" "$out"
# a UI-format save (nodes/links arrays) is NOT postable to /prompt — refuse
# with the exact fix, never a traceback
UIWF="$CT/ui-format.json"
printf '{"id":"x","last_node_id":9,"nodes":[{"id":3,"type":"KSampler"}],"links":[]}\n' > "$UIWF"
out="$(python3 "$PLUGIN/scripts/remote-capabilities/comfyui/comfy-run.py" --workflow "$UIWF" 2>&1)"; rc=$?
check "comfy-run: UI-format refused honestly" "not API format" "$out"
check "comfy-run: UI-format names the fix" "Export (API)" "$out"
check_rc "comfy-run: UI-format exit 2" 2 "$rc"
check_absent "comfy-run: UI-format no traceback" "Traceback" "$out"

# model enumeration + enum validation (fail fast, naming what IS available)
out="$(python3 - "$PLUGIN/scripts/remote-capabilities/comfyui/comfy-run.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("comfyrun", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
info = {"CheckpointLoaderSimple": {"input": {"required": {"ckpt_name": [["a.safetensors", "b.safetensors"], {}]}}}}
print("OPTS", m.enum_options(info, "CheckpointLoaderSimple", "ckpt_name"))
wf = {"37": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "nope.safetensors"}}}
print("BAD", m.validate_enums(wf, info, [("37", "ckpt_name")]))
wf["37"]["inputs"]["ckpt_name"] = "b.safetensors"
print("GOOD", m.validate_enums(wf, info, [("37", "ckpt_name")]))
PY
)"
check "comfy-run: enumerates model options" "OPTS ['a.safetensors', 'b.safetensors']" "$out"
check "comfy-run: rejects unavailable model" "is not offered by this server" "$out"
check "comfy-run: names available models" "a.safetensors, b.safetensors" "$out"
check "comfy-run: accepts an offered model" "GOOD []" "$out"

# --- the SHIPPED comfyui bundle must be invocable, not just installable ---
# (its render job was unrunnable for every input: the manifest documented a
# space-separated `sets` list, but a param is shell-quoted into ONE argv word
# and the payload declared no positional argument)
out="$(python3 "$PLUGIN/scripts/remote-capabilities/comfyui/comfy-run.py" --workflow "$CT/missing.json" --sets "A.text=hello world" 2>&1)"; rc=$?
check "comfy-run: --sets accepts one quoted multi-pair argument" "not found ON THIS MACHINE" "$out"
check_rc "comfy-run: missing workflow exits 2, no traceback" 2 "$rc"
check_absent "comfy-run: missing workflow has no traceback" "Traceback" "$out"
: > "$TLOG"
run_compute install-capability gpubox "$PLUGIN/scripts/remote-capabilities/comfyui" >/dev/null 2>&1
run_compute run gpubox comfyui:render --param workflow=/tmp/wf.json --param port=8000 \
    --param "sets=Seed.value=1 Prompt.text=a duck" --job-id rendercheck >/dev/null 2>&1
check "comfyui:render renders --sets into the remote command" "--sets" "$(cat "$TLOG")"
check "comfyui:render passes the pairs through" "Seed.value=1 Prompt.text=a duck" "$(cat "$TLOG")"

# --- a dispatched job must actually run inside its declared env ----------
run_compute add-env gpubox envprobe --activate "source ~/envprobe/bin/activate" >/dev/null 2>&1
: > "$TLOG"
run_compute dispatch gpubox --workdir "~/w" --cmd "python train.py" --env envprobe --job-id envjob >/dev/null 2>&1
check "dispatched job activates its env before the command" "source ~/envprobe/bin/activate && python train.py" "$(cat "$TLOG")"

# --- an env activate line may hold a token: it must not be republished ----
run_compute add-env gpubox secretenv --activate "export TOK=s3cr3t-value && source ~/v/bin/activate" >/dev/null 2>&1
run_compute enable gpubox --root "$REPO" --role training >/dev/null 2>&1
check_absent "enable never publishes the activate line into the repo" "s3cr3t-value" "$(cat "$REPO/.claude/project.local.yaml")"
check "enable still names the env" "secretenv" "$(cat "$REPO/.claude/project.local.yaml")"

# --- injection: operator-facing flags reach the remote shell --------------
: > "$TLOG"
out="$(run_compute dispatch gpubox --workdir "~/w" --cmd "echo hi" --job-id 'j1; touch /tmp/PWNED' 2>&1)"; rc=$?
check "job-id injection refused" "ERROR" "$out"
check_rc "job-id injection: exit 2" 2 "$rc"
check_absent "job-id injection never reached the remote" "touch /tmp/PWNED" "$(cat "$TLOG")"
out="$(run_compute dispatch gpubox --workdir "~/w" --cmd "echo hi" --job-id '../../ESCAPED' 2>&1)"; rc=$?
check_rc "job-id path traversal: exit 2" 2 "$rc"
: > "$TLOG"
out="$(run_compute dispatch gpubox --workdir '~/w; sudo rm -rf /' --cmd "echo hi" --job-id wd1 2>&1)"; rc=$?
check "workdir sudo smuggling refused" "sudo" "$out"
check_rc "workdir sudo smuggling: exit 5" 5 "$rc"
: > "$TLOG"
run_compute dispatch gpubox --workdir '~/w; touch /tmp/OOPS' --cmd "echo hi" --job-id wd2 >/dev/null 2>&1
# quoted renders `cd '~/w; touch /tmp/OOPS'`; a regression renders `cd ~/w; touch ...`
check_absent "workdir metacharacters never reach the remote unquoted" "cd ~/w;" "$(cat "$TLOG")"
run_compute unlock gpubox --force >/dev/null 2>&1

# --- host-key gate must not be skippable by substring collision -----------
mkdir -p "$CT/sshdir3"
printf '192.0.2.170 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeOther\n' > "$CT/sshdir3/known_hosts"
out="$(COMPUTE_SSH_CONFIG="$CT/sshdir3/config" COMPUTE_HOME="$CT/ch3" \
    COMPUTE_SSH_BIN="$CSTUB/ssh" COMPUTE_NC_BIN="$CSTUB/nc" COMPUTE_KEYSCAN_BIN="$CSTUB/ssh-keyscan" \
    COMPUTE_RSYNC_BIN="$CSTUB/rsync" FAKE_TRANSPORT_LOG="$TLOG" FAKE_SSH_HANDLER="$HANDLER" FIXDIR="$CFIX" \
    python3 "$COMPUTE" register other testuser@192.0.2.17 2>&1)"; rc=$?
check "host-key gate: substring collision still requires ack" "NEEDS_HOSTKEY_ACK" "$out"
check_rc "host-key gate: exit 4" 4 "$rc"

# --- register converges a CHANGED target, not just a missing alias --------
run_compute register gpubox testuser@192.0.2.99 --accept-hostkey >/dev/null 2>&1
check "register rewrites HostName on retarget" "HostName 192.0.2.99" "$(cat "$SSHDIR/config")"
check "register: still exactly one alias block" "1" "$(grep -c '^Host gpubox$' "$SSHDIR/config")"
run_compute register gpubox testuser@192.0.2.17 --accept-hostkey >/dev/null 2>&1

# --- rendered payloads must WORK on a real shell, not merely look quoted --
# The fake transport records argv and never executes it, so a payload can be
# perfectly quoted and still be broken (a tilde inside single quotes is
# literal: `cd '~/train'` fails and `mkdir -p '~/x'` makes a dir named "~").
# Render the real thing and run it under a scratch HOME.
RP="$CT/realpath-probe"; mkdir -p "$RP/home"
_rendered="$(python3 - "$PLUGIN/scripts/remote-compute.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.remote_path("~/train"))
print(m.remote_path("~/.remote-compute/jobs/j9"))
PY
)"
_wd="$(printf '%s\n' "$_rendered" | sed -n 1p)"
_jd="$(printf '%s\n' "$_rendered" | sed -n 2p)"
check_absent "rendered workdir does not quote the tilde" "'~/" "$_wd"
HOME="$RP/home" bash -c "mkdir -p $_jd && mkdir -p $_wd && cd $_wd" 2>/dev/null
check "rendered job dir lands under the real HOME" "yes" "$([ -d "$RP/home/.remote-compute/jobs/j9" ] && echo yes || echo no)"
check "rendered workdir is enterable on a real shell" "yes" "$([ -d "$RP/home/train" ] && echo yes || echo no)"
check "no literal tilde directory was created" "no" "$([ -d "$RP/home/~" ] && echo yes || echo no)"
# a workdir with shell metacharacters is still inert after the tilde rewrite
_hostile="$(python3 - "$PLUGIN/scripts/remote-compute.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.remote_path("~/w; touch /tmp/RC_SHOULD_NOT_EXIST"))
PY
)"
rm -f /tmp/RC_SHOULD_NOT_EXIST
HOME="$RP/home" bash -c "mkdir -p $_hostile" 2>/dev/null
check "hostile workdir stays inert after tilde rewrite" "no" "$([ -f /tmp/RC_SHOULD_NOT_EXIST ] && echo yes || echo no)"

# --- compute-top: the on-machine job monitor ------------------------------
TOP="$PLUGIN/scripts/remote-capabilities/_shared/compute-top.py"
JT="$CT/jobsdir"; mkdir -p "$JT/j-run" "$JT/j-ok" "$JT/j-bad" "$JT/_caps"
printf 'still going\n' > "$JT/j-run/job.log"
printf 'all good\n' > "$JT/j-ok/job.log"; printf '0\n' > "$JT/j-ok/exitcode"
printf 'boom\n' > "$JT/j-bad/job.log"; printf '7\n' > "$JT/j-bad/exitcode"
out="$(python3 "$TOP" --dir "$JT" --once 2>&1)"; rc=$?
check_rc "compute-top --once: exit 0" 0 "$rc"
check "compute-top: reports each job's duration" "took" "$out"
check "compute-top: counts running/done/failed" "1 running, 1 done, 1 failed" "$out"
check "compute-top: running job has no exit code" "running   j-run" "$out"
check "compute-top: failed job shows its code" "exit 7" "$out"
check_absent "compute-top: payload dirs are not jobs" "_caps" "$out"
out="$(python3 "$TOP" --dir "$CT/nope" --once 2>&1)"; rc=$?
check_rc "compute-top: missing dir exits 1, no traceback" 1 "$rc"
check_absent "compute-top: missing dir has no traceback" "Traceback" "$out"
# a half-written job (dispatch in flight) must not crash the reader
mkdir -p "$JT/j-partial"
out="$(python3 "$TOP" --dir "$JT" --once 2>&1)"
check "compute-top: tolerates a half-created job dir" "running   j-partial" "$out"
printf 'not-a-number\n' > "$JT/j-partial/exitcode"
out="$(python3 "$TOP" --dir "$JT" --once 2>&1)"; rc=$?
check_rc "compute-top: unreadable exitcode does not crash" 0 "$rc"
# duration: finished jobs measure start->exit, running jobs measure elapsed
out="$(python3 - "$TOP" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("ct", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
now = 1000.0
print("FIN", m.duration({"started": 900.0, "finished": 960.0}, now))
print("RUN", m.duration({"started": 940.0, "finished": None}, now))
print("UNK", m.duration({"started": None, "finished": None}, now))
PY
)"
check "duration: finished job measures start to exit" "FIN 60.0" "$out"
check "duration: running job measures elapsed so far" "RUN 60.0" "$out"
check "duration: unknown start reports nothing rather than guessing" "UNK None" "$out"
# key bindings: L opens logs, esc leaves the log view, q does NOT quit the list
_src="$(cat "$TOP")"
check "compute-top: L opens the log view" 'ord("L")' "$_src"
check "compute-top: esc leaves the log view" 'ord("q"), 27, ord("h")' "$_src"
check "compute-top: footer tells the human ctrl-c quits" "ctrl-c quit" "$_src"

# --- optional params: a declared default makes a param omittable ----------
run_compute add-job gpubox with-default --workdir "~/w" --cmd "echo m={model} p={prompt}" \
    --param 'prompt:[^`$;|&<>]+' --param-default 'model=base.safetensors' >/dev/null 2>&1
: > "$TLOG"
run_compute run gpubox with-default --param "prompt=hi" --job-id od1 >/dev/null 2>&1
check "omitted param falls back to its default" "m=base.safetensors" "$(cat "$TLOG")"
: > "$TLOG"
run_compute run gpubox with-default --param "prompt=hi" --param "model=other.safetensors" --job-id od2 >/dev/null 2>&1
check "supplied value overrides the default" "m=other.safetensors" "$(cat "$TLOG")"
out="$(run_compute jobs gpubox 2>&1)"
check "jobs listing marks a param as optional" "model (optional" "$out"
# a default must still satisfy the declared pattern, or the job is a trap
out="$(run_compute add-job gpubox bad-default --workdir "~/w" --cmd "echo {n}" \
    --param 'n:[0-9]+' --param-default 'n=abc' 2>&1)"; rc=$?
check "default that violates its own pattern is refused" "does not match" "$out"
check_rc "bad default: exit 2" 2 "$rc"

# --- job-id schema: artifact jobs get consistent, sortable ids -------------
# A capability may declare how job ids are built, so every artifact run is
# identifiable after the fact (which model, which seed) without opening logs.
IDB="$CT/idcap"; mkdir -p "$IDB"
cat > "$IDB/capability.yaml" <<'EOF'
version: 1
name: idcap
description: capability declaring a job-id schema
payload:
-   run.py
jobIdSchema:
    template: "img-{model}-{seed}"
    description: prefix, model slug, then the seed as the suffix
jobs:
    render:
        description: fake render
        cmd: python3 {capdir}/run.py --seed {seed} --model {model}
        params:
            seed: "[0-9]+"
            model: "[^`$;|&<>]+"
EOF
printf '#!/usr/bin/env python3\nprint("ok")\n' > "$IDB/run.py"
run_compute install-capability gpubox "$IDB" >/dev/null 2>&1
: > "$TLOG"
run_compute run gpubox idcap:render --param seed=12345 --param 'model=waiIllustriousSDXL_v150.safetensors' >/dev/null 2>&1
_ids="$(ls "$CH/jobs" 2>/dev/null)"
check "job id is derived from the declared schema" "img-waiillustrioussdxl-v150-12345.json" "$_ids"
# an explicit --job-id still wins over the schema
run_compute run gpubox idcap:render --param seed=999 --param 'model=x.safetensors' --job-id explicit-wins >/dev/null 2>&1
check "explicit --job-id overrides the schema" "explicit-wins.json" "$(ls "$CH/jobs")"
# the rendered id must satisfy the same validation as a hand-typed one
# a ';' is already refused by the param pattern, so use a value the pattern
# ALLOWS but that would still be ugly in a filename (spaces, slashes)
run_compute run gpubox idcap:render --param seed=77 --param 'model=a b/c d.safetensors' >/dev/null 2>&1
check_absent "schema-derived ids carry no path separators" "a b/c" "$(ls "$CH/jobs")"
check "schema slugifies a hostile model name" "img-a-b-c-d-77.json" "$(ls "$CH/jobs")"
# a template whose placeholders the job does not declare must NOT collapse to
# a constant: two runs would share one id and the second would clobber the
# first's state file
_uniq="$(python3 - "$COMPUTE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a = m.render_job_id({"template": "img-{model}-{seed}"}, {"port": "8000"})
b = m.render_job_id({"template": "img-{model}-{seed}"}, {"port": "8000"})
print("A", a); print("B", b); print("DIFFER", a != b)
PY
)"
check "unfilled placeholders still yield a unique id" "DIFFER True" "$_uniq"
check "unfilled placeholders keep the prefix and add a unique suffix" "A img-" "$_uniq"

# --- @workflow: leave an input at whatever the workflow itself declares ----
# An optional param still SUBSTITUTES its default, so the workflow's own value
# is overwritten. The @workflow sentinel means "do not touch this input".
_wfkeep="$(python3 - "$PLUGIN/scripts/remote-capabilities/comfyui/comfy-run.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
wf = {"29": {"class_type": "SaveImage", "inputs": {"filename_prefix": "workflow/own/value"}},
      "40": {"class_type": "CLIPTextEncode", "inputs": {"text": "orig"}}}
print("SKIPPED", m.apply_set(wf, "29.filename_prefix=@workflow"))
print("KEPT", wf["29"]["inputs"]["filename_prefix"])
m.apply_set(wf, "40.text=")
print("EMPTY_STILL_SETS", repr(wf["40"]["inputs"]["text"]))
PY
)"
check "@workflow leaves the input untouched" "KEPT workflow/own/value" "$_wfkeep"
check "@workflow reports the node it skipped" "SKIPPED 29" "$_wfkeep"
check "an empty value is still a real value, not a skip" "EMPTY_STILL_SETS ''" "$_wfkeep"

# --- remove-job: retire a declared job without touching the machine --------
run_compute add-job gpubox scratch-job --workdir "~/w" --cmd "echo hi" >/dev/null 2>&1
check "remove-job: job exists first" "scratch-job" "$(run_compute jobs gpubox 2>&1)"
out="$(run_compute remove-job gpubox scratch-job 2>&1)"; rc=$?
check_rc "remove-job: exit 0" 0 "$rc"
check_absent "remove-job: job is gone" "scratch-job" "$(run_compute jobs gpubox 2>&1)"
out="$(run_compute remove-job gpubox no-such-job 2>&1)"; rc=$?
check "remove-job: unknown job names what IS declared" "declared jobs:" "$out"
check_rc "remove-job: unknown job exit 2" 2 "$rc"

# --- remove-capability: uninstall a bundle and its declared jobs -----------
run_compute install-capability gpubox "$BUNDLE" >/dev/null 2>&1
check "remove-capability: installed first" "demo" "$(run_compute capabilities gpubox 2>&1)"
out="$(run_compute remove-capability gpubox demo 2>&1)"; rc=$?
check_rc "remove-capability: exit 0" 0 "$rc"
check_absent "remove-capability: gone from the roster" "demo" "$(run_compute capabilities gpubox 2>&1)"
check_absent "remove-capability: its jobs go too" "demo:greet" "$(run_compute jobs gpubox 2>&1)"
check "remove-capability: says the payload stayed" "payload" "$out"
# --purge-remote additionally deletes the payload directory on the machine
run_compute install-capability gpubox "$BUNDLE" >/dev/null 2>&1
: > "$TLOG"
out="$(run_compute remove-capability gpubox demo --purge-remote 2>&1)"; rc=$?
check_rc "remove-capability --purge-remote: exit 0" 0 "$rc"
check "purge-remote deletes only the capability dir" "rm -rf" "$(cat "$TLOG")"
check "purge-remote targets that capability path" "caps/demo" "$(cat "$TLOG")"
out="$(run_compute remove-capability gpubox nope 2>&1)"; rc=$?
check "remove-capability: unknown names what IS installed" "installed:" "$out"
check_rc "remove-capability: unknown exit 2" 2 "$rc"

# --- a bundle manifest's `env:` must reach the dispatched payload ---------
# (#527) env: is honored in code but was only ever exercised via add-job --env.
# The shipped training bundle declares it on every job, so a regression here
# would silently run training outside its virtualenv.
run_compute add-env gpubox bundleenv --activate "source ~/bundleenv/bin/activate" >/dev/null 2>&1
ENVB="$CT/envcap"; mkdir -p "$ENVB"
cat > "$ENVB/capability.yaml" <<'EOF'
version: 1
name: envcap
description: bundle whose job declares the env it needs
payload:
-   run.py
jobs:
    work:
        description: runs inside a declared env
        cmd: python3 {capdir}/run.py
        env: bundleenv
EOF
printf '#!/usr/bin/env python3\nprint("ok")\n' > "$ENVB/run.py"
run_compute install-capability gpubox "$ENVB" >/dev/null 2>&1
: > "$TLOG"
run_compute run gpubox envcap:work --job-id bundleenvjob >/dev/null 2>&1
check "bundle manifest env activates before the command" "source ~/bundleenv/bin/activate && python3" "$(cat "$TLOG")"

# --- remove --------------------------------------------------------------
out="$(run_compute remove gpubox 2>&1)"
check_absent "remove: gone from registry" "gpubox" "$(cat "$CH/resources.yaml")"
check "remove: ssh alias intentionally kept" "Host gpubox" "$(cat "$SSHDIR/config")"

# --- platform setup sheets print on demand -------------------------------
check "sheet wsl2: mirrored networking" "networkingMode=mirrored" "$(run_compute setup-sheet wsl2 2>&1)"
check "sheet linux: sshd" "openssh-server" "$(run_compute setup-sheet linux 2>&1)"
check "sheet macos: Remote Login" "Remote Login" "$(run_compute setup-sheet macos 2>&1)"

rm -rf "$CT"
