#!/usr/bin/env bash
# remote-compute — the on-machine command for a box registered as a
# remote-compute resource. Installed by `remote-compute.py register` (and
# re-converged by `install-tools`) to ~/.remote-compute/bin/remote-compute,
# symlinked into ~/.local/bin. It reads the same ~/.remote-compute layout that
# dispatch writes (jobs/<id>/{job.log,pid,exitcode}, caps/<bundle>/), so the
# human at the keyboard and the orchestrator over ssh see one picture.
# Plain bash + python3 (for the dashboard). Never sudo. bash 3.2 compatible.
set -u
VERSION="0.2.0"
ROOT="${REMOTE_COMPUTE_ROOT:-$HOME/.remote-compute}"
JOBS="$ROOT/jobs"; CAPS="$ROOT/caps"; TOOLS="${REMOTE_COMPUTE_TOOLS:-$ROOT/tools}"; BIN="$ROOT/bin"

die() { echo "remote-compute: $*" >&2; exit 2; }

usage() {
    cat <<USAGE
remote-compute $VERSION — this machine is a remote-compute resource ($ROOT)

  top [--interval N]   live job dashboard (arrows browse, enter opens a log, q quits)
                       also reachable as the bare command compute-top
  jobs                 one-shot job table (pipe-friendly)
  running              ids of jobs still running
  log <id> [-f]        last 100 lines of a job's log (-f follows)
  status <id>          state, exit code, pid, timestamps, paths of one job
  cancel <id> [--yes]  stop a running job (TERM to its process group; asks first)
  caps | capabilities  installed capability bundles on this machine
  gpu                  GPU summary (nvidia-smi, WSL path aware; Apple GPU on macOS)
  disk                 free space and size of the job/capability roots
  paths                where everything lives
  identity             which registered resource this machine is (its .identity stamp)
  version | help

Controller commands (installed with install-cli or install-tools):
  register <nick> user@host | probe <nick> | list | connect [nick] | scan [nick]
  enable <nick> --root DIR | disable <nick> --root DIR
  capabilities list
  capabilities installed [<nick>]
  capabilities install <nick> <name-or-bundle-dir> [--env NAME]
  capabilities install <nick> <github-url> [name | --all] [--ref REF]
  capabilities sync <nick> | capabilities validate <bundle-dir>
  remove-capability <nick> <name> [--purge-remote | --retire-remote]
  add-env <nick> NAME --activate CMD | envs <nick>
  add-job <nick> NAME --cmd CMD --workdir DIR | remove-job <nick> NAME
  jobs <nick> | run <nick> JOB [--param key=value]
  exec <nick> -- COMMAND | dispatch <nick> --workdir DIR --cmd COMMAND
  job-status <id> | job-logs <id> | job-pull <id> | job-cancel <id>
  lock <nick> | unlock <nick> | policy <nick> --max-concurrent-jobs N
  doctor [nick] [--json] | install-cli [--prefix DIR] | install-tools <nick>
  identity <nick> | remove <nick> | setup-sheet wsl2|linux|macos

Use controller --help for full options; local <command> forces machine-local mode.
USAGE
}

job_dir() { # id -> dir, or die
    if [ $# -lt 1 ] || [ -z "$1" ]; then die "job id required"; fi
    case "$1" in */*|.*|_*) die "not a job id: $1" ;; esac
    if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [ ${#1} -gt 64 ]; then die "not a job id: $1"; fi
    [ -d "$JOBS/$1" ] || die "no such job: $1 (see: remote-compute jobs)"
    echo "$JOBS/$1"
}

mtime() { # portable file mtime
    stat -c '%y' "$1" 2>/dev/null | cut -d. -f1 || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1" 2>/dev/null
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

job_state() { # dir -> running|done|failed|unknown
    local d="$1"
    if [ -f "$TOOLS/compute-state.py" ]; then
        python3 "$TOOLS/compute-state.py" state-text "{\"id\":\"$(basename "$d")\"}"
        return
    fi
    if [ -f "$d/exitcode" ]; then
        if [ "$(cat "$d/exitcode" 2>/dev/null)" = "0" ]; then echo 'done'; else echo failed; fi
    elif [ -f "$d/pid" ]; then
        if pid_alive "$(cat "$d/pid")"; then echo running; else echo lost; fi
    else
        echo unknown
    fi
}

cmd_top() {
    [ -f "$TOOLS/compute-top.py" ] || die "dashboard missing at $TOOLS/compute-top.py (re-run register / install-tools from the orchestrator)"
    exec python3 "$TOOLS/compute-top.py" --dir "$JOBS" "$@"
}

cmd_running() {
    [ -d "$JOBS" ] || { echo "no jobs yet ($JOBS does not exist)"; return 0; }
    local d n=0
    for d in "$JOBS"/*/; do
        [ -d "$d" ] || continue
        case "$(basename "$d")" in _*) continue ;; esac
        [ "$(job_state "${d%/}")" = running ] && { basename "$d"; n=$((n + 1)); }
    done
    [ "$n" -eq 0 ] && echo "(nothing running)"
    return 0
}

cmd_log() {
    local d; d="$(job_dir "${1:-}")" || exit 2; shift
    [ -f "$d/job.log" ] || die "no job.log in $d yet"
    if [ "${1:-}" = "-f" ]; then exec tail -n 50 -f "$d/job.log"; fi
    tail -n 100 "$d/job.log"
}

cmd_status() {
    local d; d="$(job_dir "${1:-}")" || exit 2
    local id pid="" code="-" state alive="-"
    id="$(basename "$d")"
    [ -f "$d/pid" ] && pid="$(cat "$d/pid")"
    [ -f "$d/exitcode" ] && code="$(cat "$d/exitcode")"
    state="$(job_state "$d")"
    if [ -n "$pid" ]; then pid_alive "$pid" && alive=yes || alive=no; fi
    echo "job:       $id"
    echo "state:     $state"
    echo "exit:      $code"
    echo "pid:       ${pid:--}  (alive: $alive)"
    [ -f "$d/pid" ]      && echo "started:   $(mtime "$d/pid")"
    [ -f "$d/exitcode" ] && echo "finished:  $(mtime "$d/exitcode")"
    echo "dir:       $d"
    [ -f "$d/job.log" ]  && echo "log:       $d/job.log ($(wc -c < "$d/job.log" | tr -d ' ') bytes)"
    return 0
}

cmd_cancel() {
    local d; d="$(job_dir "${1:-}")" || exit 2; shift
    local id yes=0 pid
    id="$(basename "$d")"
    [ "${1:-}" = "--yes" ] && yes=1
    case "$(job_state "$d")" in running|cancelling) ;; *) die "$id is not running (state: $(job_state "$d"))" ;; esac
    pid="$(cat "$d/pid")"
    if [ "$yes" -ne 1 ]; then
        printf 'stop job %s (pid %s)? [y/N] ' "$id" "$pid"
        read -r ans
        case "$ans" in y|Y|yes) ;; *) echo "left running"; return 1 ;; esac
    fi
    if [ -f "$TOOLS/compute-state.py" ]; then
        python3 "$TOOLS/compute-state.py" cancel "{\"id\":\"$id\"}" || return $?
        echo "cancelled $id"
        return 0
    fi
    die "state helper missing; run install-tools before cancelling, or verify the legacy process manually"
}

yaml_scalar() { # file key -> top-level scalar value; folded/literal blocks (>-, |) joined on one line
    awk -v k="$2" '
        found && /^[^[:space:]]/ { exit }
        found { sub(/^[[:space:]]+/, ""); if ($0 != "") printf "%s%s", (n++ ? " " : ""), $0; next }
        $0 ~ "^" k ":" { v = $0; sub("^" k ":[[:space:]]*", "", v)
                         if (v ~ /^[>|][-+]?$/) { found = 1; next }
                         gsub(/^["\x27]|["\x27]$/, "", v); print v; exit }
        END { if (n) printf "\n" }
    ' "$1"
}

cmd_caps() {
    if [ -f "$TOOLS/compute-state.py" ]; then
        python3 "$TOOLS/compute-state.py" caps-text '{}'
        return
    fi
    [ -d "$CAPS" ] || { echo "no capability bundles installed ($CAPS does not exist)"; return 0; }
    local d m name desc n=0
    for d in "$CAPS"/*/; do
        [ -d "$d" ] || continue
        m="$d/capability.yaml"
        if [ -f "$m" ]; then
            name="$(yaml_scalar "$m" name)"
            desc="$(yaml_scalar "$m" description | cut -c1-96)"
        else
            name="$(basename "$d")"; desc="(no capability.yaml)"
        fi
        printf '%-20s %s\n' "${name:-$(basename "$d")}" "$desc"
        n=$((n + 1))
    done
    [ "$n" -eq 0 ] && echo "(none installed)"
    return 0
}

cmd_gpu() {
    local smi
    smi="$(command -v nvidia-smi 2>/dev/null || true)"
    [ -z "$smi" ] && [ -x /usr/lib/wsl/lib/nvidia-smi ] && smi=/usr/lib/wsl/lib/nvidia-smi
    if [ -n "$smi" ]; then
        "$smi" --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv
    elif [ "$(uname -s)" = Darwin ]; then
        system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset Model|Total Number of Cores|Metal' | sed 's/^ *//'
    else
        echo "no GPU tooling found (nvidia-smi not on PATH or at /usr/lib/wsl/lib/nvidia-smi)"
        return 1
    fi
}

cmd_disk() {
    df -h "$HOME" | tail -n 2
    [ -d "$JOBS" ] && du -sh "$JOBS" 2>/dev/null
    [ -d "$CAPS" ] && du -sh "$CAPS" 2>/dev/null
    return 0
}

cmd_identity() {
    if [ -s "$ROOT/.identity" ]; then cat "$ROOT/.identity"; else echo "(no identity file at $ROOT/.identity — register / install-tools stamps it)"; return 1; fi
}

cmd_paths() {
    echo "root:   $ROOT  (identity: $(cat "$ROOT/.identity" 2>/dev/null || echo unstamped))"
    echo "jobs:   $JOBS"
    echo "caps:   $CAPS"
    echo "tools:  $TOOLS"
    echo "bin:    $BIN  (this command: $BIN/remote-compute, linked from ~/.local/bin)"
}

main() {
    # invoked through the `compute-top` link: behave as `remote-compute top ...`
    case "$(basename "${0:-remote-compute}")" in compute-top) set -- top "$@" ;; esac
    local verb="${1:-help}"; [ $# -gt 0 ] && shift
    local controller="${REMOTE_COMPUTE_CONTROLLER:-$ROOT/controller/remote-compute.py}"
    if [ "$verb" = local ]; then
        verb="${1:-help}"; [ $# -gt 0 ] && shift
    else
    case "$verb" in
        controller) [ -f "$controller" ] || die "controller missing; run install-cli or install-tools"; exec python3 "$controller" "$@" ;;
        capabilities)
            if [ $# -gt 0 ]; then
                [ -f "$controller" ] || die "capability management needs the controller; run install-cli or install-tools"
                exec python3 "$controller" capabilities "$@"
            fi ;;
        register|probe|scan|enable|disable|add-env|envs|add-job|remove-job|run|list|exec|dispatch|lock|unlock|install-tools|install-cli|install-capability|remove-capability|remove|connect|setup-sheet|job-status|job-logs|job-pull|job-cancel|doctor|policy)
            [ -f "$controller" ] || die "controller missing; run install-cli or install-tools"
            exec python3 "$controller" "$verb" "$@" ;;
        jobs) if [ $# -gt 0 ]; then [ -f "$controller" ] || die "controller missing"; exec python3 "$controller" jobs "$@"; fi ;;
        identity) if [ $# -gt 0 ]; then [ -f "$controller" ] || die "controller missing"; exec python3 "$controller" identity "$@"; fi ;;
        status) if [ $# -gt 0 ] && [ ! -d "$JOBS/$1" ] && [ -f "$controller" ]; then exec python3 "$controller" status "$@"; fi ;;
    esac
    fi
    case "$verb" in
        jobs|running|caps|capabilities|gpu|disk|paths|identity|whoami|version|--version|help|-h|--help)
            [ $# -eq 0 ] || die "unexpected arguments to $verb" ;;
        status) [ $# -eq 1 ] || die "usage: status <id>" ;;
        log|logs) if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "usage: log <id> [-f]"; fi; [ $# -lt 2 ] || [ "$2" = -f ] || die "unknown log option" ;;
        cancel) if [ $# -lt 1 ] || [ $# -gt 2 ]; then die "usage: cancel <id> [--yes]"; fi; [ $# -lt 2 ] || [ "$2" = --yes ] || die "unknown cancel option" ;;
    esac
    case "$verb" in
        top)        cmd_top "$@" ;;
        jobs)       cmd_top --once ;;
        running)    cmd_running ;;
        log|logs)   cmd_log "$@" ;;
        status)     cmd_status "$@" ;;
        cancel)     cmd_cancel "$@" ;;
        caps|capabilities) cmd_caps ;;
        gpu)        cmd_gpu ;;
        disk)       cmd_disk ;;
        paths)      cmd_paths ;;
        identity|whoami) cmd_identity ;;
        version|--version) echo "remote-compute on-machine command $VERSION" ;;
        help|-h|--help) usage ;;
        *)          usage >&2; die "unknown verb '$verb'" ;;
    esac
}
main "$@"
