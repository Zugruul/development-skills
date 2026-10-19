# Compatibility matrix: incremental remote-compute audit

CDX-050 / issue #194, 2026-10-11. Semantic review of the four shipped skills
at source revision `9759fa7`, against SPEC-CODEX-COMPAT sections 7-9 and
[the binding E5 design](design/cdx-E5.md). Runtime, schemas, manifests, hooks,
and source skill instructions are unchanged by this audit.

This incremental matrix audits only four remote-compute skills; the rest of the marketplace is NOT audited here.
CDX-042 remains incomplete.

"Source-reviewed" means the shared instructions and engine were inspected for
host assumptions. It is not certification that either host successfully
installed, invoked, or followed the skill. Named gaps below affect both hosts.

<!-- remote-audit:start -->
| Skill | Claude support | Codex support | Interaction/invocation | Section 8 | Section 9 | Known limitations |
| --- | --- | --- | --- | --- | --- | --- |
| `remote-compute` | Source-reviewed; live unverified | Source-reviewed; live unverified | [Section 7](#remote-compute) | N/A: no delegation/model routing | N/A: no build-loop/board transitions; [mechanics](#mechanical-enforcement) | [Limitations](#remote-compute) |
| `compute-top` | Source-reviewed; live unverified | Source-reviewed; live unverified | [Section 7](#compute-top) | N/A: no delegation/model routing | N/A: no build-loop/board transitions; [mechanics](#mechanical-enforcement) | [Limitations](#compute-top) |
| `scan` | Source-reviewed; live unverified | Source-reviewed; live unverified | [Section 7](#scan) | N/A: no delegation/model routing | N/A: no build-loop/board transitions; [mechanics](#mechanical-enforcement) | [Limitations](#scan) |
| `ssh` | Source-reviewed; live unverified | Source-reviewed; live unverified | [Section 7](#ssh) | N/A: no delegation/model routing | N/A: no build-loop/board transitions; [mechanics](#mechanical-enforcement) | [Limitations](#ssh) |
<!-- remote-audit:end -->

## Common interaction and execution scope

Execution target: WSL/Linux/macOS; native PowerShell is unsupported.
Windows Codex hosts need a WSL bridge and WSL paths.

This follows the [controller skill's platform restriction](../plugins/remote-compute/skills/remote-compute/SKILL.md#L288)
and [dashboard's target platforms](../plugins/remote-compute/skills/compute-top/SKILL.md#L24).
The controller needs Python 3, PyYAML, Bash, SSH and rsync for the operations
that use them; the dashboard uses Python's stdlib curses. The controller imports
`fcntl` and the dashboard imports `curses`, reinforcing the POSIX execution
boundary. Linux tests under WSL do not establish a native macOS test result.
No Windows-native command or dashboard support is implied by a Codex manifest.

For all four skills, section 7.1's questions are plain user-facing instructions,
without required host tool names. None relies on `ARGUMENTS` or `$ARGUMENTS`
being populated (7.4), or on implicit host `!` command-substitution at load
time (7.5). Follow the selected skill and the remainder of the user's request.
The explicit shell example `--root "$(git rev-parse --show-toplevel)"` in
remote-compute is ordinary Bash evaluation when that command is run, not an
implicit host pre-start action. Its result identifies a consumer repo, not
the plugin root. There is no no-write research/plan phase (7.2), no subagent
spawn (7.3), and no session-ID/resume-link/live-session-metadata behavior (7.6).
These three clauses are N/A, not execution passes.

Resolve `../../scripts/...` relative to the selected `SKILL.md`, not an arbitrary
consumer working directory. Preserve the whole plugin's relative layout and
quote paths, including paths with spaces. Convert Windows paths to their WSL
mount paths before the WSL shell executes them. The controller finds shared
payloads from [`__file__`](../plugins/remote-compute/scripts/remote-compute.py#L98);
the dashboard finds its state helper from its
[own file location](../plugins/remote-compute/scripts/remote-capabilities/_shared/compute-top.py#L42).
The new hermetic cache-with-spaces probe exercises the latter from a separate
consumer directory without Claude plugin-root variables. It does not prove
an actual host resolves skill references correctly after installation.

Invocation evidence is local metadata and prose: the
[Claude manifest](../plugins/remote-compute/.claude-plugin/plugin.json) names
`remote-compute`; the [Codex manifest](../plugins/remote-compute/.codex-plugin/plugin.json)
points at `./skills/` and provides natural-language default prompts. Every skill
has `name` and `description` frontmatter. Literal `/remote-compute:scan` and
`/remote-compute:ssh` are documented in their source skills. For remote-compute
and compute-top, this audit uses their source descriptions' natural-language
requests rather than inventing an unverified slash invocation. For Codex,
select the installed named skill or request its described operation, with
arguments in the request text; this is instruction semantics, not a claim
that a particular Codex CLI command was tested. No install/update commands
are newly verified by this audit.

Sections 8.1-8.3 are N/A for each row: all four invoke the same Python engine
or dashboard directly; none reads delegation identities, selects a model,
spawns a dev/reviewer, or authors workflow commits. Sections 9.1-9.3's board
gate, checkpoint, reviews, WIP, brain isolation, retro and hook transitions are
N/A for these skill workflows: none performs a Project status transition or
enters the autonomous build loop. Remote job admission is a different concern.
The spec-workflow dependency for `enable` does not make the four skills run
that plugin's board hooks.

Neither allowed-tools nor host hooks establish a cross-host security boundary.

## remote-compute

Interaction: bare skill request runs list, then asks which verb; never guess a nickname.

The [bare-invocation rule](../plugins/remote-compute/skills/remote-compute/SKILL.md#L50)
and description support requests such as "register this machine as a compute
resource" and "make gpubox available to this project". Registration asks the
human to verify the host fingerprint before `--accept-hostkey`, relays
`ssh-copy-id` for the human to run, and stops on unreachable/authentication
errors. Power-policy confirmation is an informational user assertion.
The [engine acknowledgement branch](../plugins/remote-compute/scripts/remote-compute.py#L678)
checks flag presence, not whether a human actually verified the key.

CLI bare invocation prints help; chat skill bare invocation selects `list`.
These are deliberately distinct interfaces, documented in the same skill at
[line 289](../plugins/remote-compute/skills/remote-compute/SKILL.md#L289) and
covered by local CLI tests. Registration and enable can write state and contact
machines; they are not discovery-only operations. `enable` needs spec-workflow
and an explicit repo `--root`; the registry and SSH configuration remain
machine-local, and the project receives a gitignored availability overlay.
Normal controller operations return text, not an interactive TTY interface.

Limitations: G1 leaves the diagnostic intent route ambiguous; G2 overstates
the sudo-token guard. See [filed gaps](#filed-gaps). Shared recipes execute
with the SSH account's permissions and are not an OS sandbox. Live host and
transport behavior remain unverified in this audit.

## compute-top

Interaction: browse/prune needs the human's TTY; non-TTY output is a one-shot snapshot.

The [skill](../plugins/remote-compute/skills/compute-top/SKILL.md#L24) describes
execution on the machine holding the jobs, or `ssh -t <alias> compute-top` in
the human's terminal. It has no explicit bare-chat default; its flags default
to `~/.remote-compute/jobs` and a two-second refresh. Missing job directories
produce an explanation and exit 1. Cleanup is destructive and the skill tells
the agent to relay that fact; the dashboard asks before deleting selected or
finished jobs and refuses nonterminal jobs. Its "READ tool" label should be
read together with those explicitly documented pruning controls.

For "what is running", [the source recommendation](../plugins/remote-compute/skills/compute-top/SKILL.md#L114)
is an exec snapshot, creating G1. The
[actual non-TTY branch](../plugins/remote-compute/scripts/remote-capabilities/_shared/compute-top.py#L364)
renders once without curses, also selected by `--once`. The new local probe
omits `--once` and captures stdout to exercise this branch with an expired
reservation; it does not launch the interactive dashboard.

Limitations: G1's policy ambiguity; interactive navigation/pruning on a real
host remains unverified. The host must supply a human TTY for interactive use;
a captured agent-shell result is only a snapshot. Per-machine job directories
are not a consolidated multi-machine dashboard.

## scan

Interaction: bare skill request scans all registered machines; duplicate identity requires the human's choice.

Literal Claude-style `/remote-compute:scan` and the natural-language request
"did its IP change" are present in the
[skill](../plugins/remote-compute/skills/scan/SKILL.md#L17). Codex can follow that
same named skill with a request and optional nickname/subnet/pick values.
The skill instructs the agent to ask which duplicate is real, relay statuses,
never erase a pin to hide KEY_MISMATCH, and never invent the chosen address.
No TTY is needed. Bare `scan` can update registry, alias and known_hosts;
`--dry-run` reports moves without applying them but still probes the network.

The [engine](../plugins/remote-compute/scripts/remote-compute.py#L2162) validates
subnets (no wider than /22) and detects conflicting claimants. Recovery normally
matches a pinned key plus the registered stable UUID or legacy nickname stamp,
but the inherited legacy path can accept an unstamped candidate.

Legacy fallback: without a registered machineId and without a candidate identity stamp, scan can accept the pinned key alone.
Pick validation: candidate membership is checked only when resolving multiple matching candidates; a single match ignores an out-of-candidate --pick.

The [legacy branch](../plugins/remote-compute/scripts/remote-compute.py#L2296)
uses key-only candidates when no identity-matched candidate exists, reports that
fallback, and stamps a successful actual move. A UUID-bearing registration
with a missing candidate UUID is not eligible for this recovery fallback.
The [duplicate-candidate branch](../plugins/remote-compute/scripts/remote-compute.py#L2315)
checks membership for `--pick`; the single-match branch chooses that match
without checking the supplied address. The human choice remains policy: a
valid pick alone does not prove the human supplied it. Proxied machines use
strict SSH checks and need their route repaired rather than local discovery.

Limitations: no new semantic gap found for this skill within sections 7-9;
hashed known_hosts entries and CA/revoked marker entries are not discovery
pins in [`_known_host_keys`](../plugins/remote-compute/scripts/remote-compute.py#L2019).
This is an existing source limitation, not proof that host verification was
performed. Real LAN recovery, macOS execution and host invocation are unverified.

## ssh

Interaction: bare skill request runs connect and prints commands; the agent does not open an interactive session.

Literal Claude-style `/remote-compute:ssh` and "give me the ssh command for
storm" are supported by the [skill prose](../plugins/remote-compute/skills/ssh/SKILL.md#L14).
For Codex, use that named skill and request semantics. `connect` defaults to
all registered machines, optionally filtered by nickname. It relays fenced
command blocks; a missing target command prompts an offer to install tools,
and an apparently powered-on but unreachable machine prompts a scan suggestion.

The [implementation](../plugins/remote-compute/scripts/remote-compute.py#L2495)
probes availability using strict `ssh_run(nick, "true")`, then prints shell,
TTY dashboard, snapshot and GPU commands. Thus connect is not an offline
inventory operation, even though it opens no interactive session. A new local
probe mocks the transport and verifies that only `true` is requested while
the interactive commands appear in output.

Limitations: printed commands depend on the user's effective SSH setup and
installed target tools; printing them does not prove that they work. There is
no new sections 7-9 semantic gap identified for this skill. The live shell,
dashboard, GPU command and host skill invocation remain unverified.

## Mechanical enforcement

Human fingerprint verification and intent authorization remain agent policy; an accepted flag does not prove either.

- Shared [SSH/rsync options](../plugins/remote-compute/scripts/remote-compute.py#L303)
  enforce `BatchMode=yes`, strict host-key checking and configured known_hosts.
  Existing [transport tests](../plugins/remote-compute/tests/section-remote-compute.sh#L138)
  cover missing acknowledgement, authentication and per-invocation BatchMode;
  [rsync checks](../plugins/remote-compute/tests/section-remote-compute.sh#L390)
  and [scan checks](../plugins/remote-compute/tests/section-remote-compute.sh#L922)
  cover strict transport. These are fake-transport assertions, not live SSH.
- [Exact pin matching](../plugins/remote-compute/scripts/remote-compute.py#L2019)
  and [scan identity matching with a legacy fallback](../plugins/remote-compute/scripts/remote-compute.py#L2296)
  are exercised by the [substring regression](../plugins/remote-compute/tests/section-remote-compute.sh#L616),
  [identity/pick tests](../plugins/remote-compute/tests/section-remote-compute.sh#L890)
  and [revoked-key exclusion test](../plugins/remote-compute/tests/test_hardening.py#L517).
  The script cannot establish that a past human acknowledgement was informed.

Two-factor matching has a legacy key-only fallback; --pick membership validation is limited to duplicate-candidate resolution.

Four focused hermetic cases exercise unstamped legacy acceptance, refusal of
an unstamped candidate for a UUID-bearing registration, ignored invalid pick
with one match, and rejected invalid pick with multiple matches. They mock
discovery/identity responses and prohibit subprocess transport and registry
writes. This is local engine evidence, not live identity verification.

- [Declared-job validation](../plugins/remote-compute/scripts/remote-compute.py#L1838)
  rejects unknown jobs/params, validates patterns and renders quoted values
  once. [Parameter tests](../plugins/remote-compute/tests/test_hardening.py#L341)
  exercise literal substitution through a local shell. The choice to use a
  declared job for an outcome, and the decision that a human dictated a raw
  command, remain agent instructions; the CLI does not classify conversation.
- [Lexical sudo rejection](../plugins/remote-compute/scripts/remote-compute.py#L432)
  and [activation recheck](../plugins/remote-compute/scripts/remote-compute.py#L1024)
  have [explicit sudo tests](../plugins/remote-compute/tests/section-remote-compute.sh#L295).
  They are useful checks on trusted recipes, not a privilege boundary (G2).
- [Target admission and immutable IDs](../plugins/remote-compute/scripts/remote-capabilities/_shared/compute-state.py#L219)
  and [cancellation fingerprints](../plugins/remote-compute/scripts/remote-capabilities/_shared/compute-state.py#L282)
  are tested by the [local protocol tests](../plugins/remote-compute/tests/test_hardening.py#L557),
  including cancellation that does not report success while a tracked process
  survives. These coordinate cooperating clients under one SSH account; they
  do not constrain arbitrary code the account can execute.

## Filed gaps

### G1 Diagnostic intent ambiguity

Status: open; not fixed by this audit.

[Follow-up #536](https://github.com/Zugruul/development-skills/issues/536), filed by the parent.
P2: [compute-top's outcome-to-exec recommendation](../plugins/remote-compute/skills/compute-top/SKILL.md#L114)
conflicts with [remote-compute's explicit-command-only policy](../plugins/remote-compute/skills/remote-compute/SKILL.md#L118).
This may be an intended read-only diagnostic exception, but that exception is
not explicitly reconciled. Both hosts can choose inconsistent intent boundaries.
Follow-up acceptance: align the route or document a precise diagnostic exception,
retain declared-job policy, and add a targeted conflicting-instruction regression.
This is semantic ambiguity, not a claimed OS exploit.

### G2 Sudo guard wording overclaim

Status: open; not fixed by this audit.

[Follow-up #537](https://github.com/Zugruul/development-skills/issues/537), filed by the parent.
P2: [the activation claim](../plugins/remote-compute/skills/remote-compute/SKILL.md#L307)
overstates what a regex can guarantee, contradicting the skill's own
[trusted-recipe disclaimer](../plugins/remote-compute/skills/remote-compute/SKILL.md#L100).
Follow-up acceptance: narrow the assertion to lexical sudo-token rejection,
state the trusted-recipe/SSH-account boundary, preserve existing checks and
test the corrected statement. This documentation issue is distinct from #347's
forced-command boundary; no new security engine is proposed here.

Both follow-up issues exist. Project item creation was blocked by missing
Project scope; issue filing does not imply Project-board placement.

## Evidence and unverified limits

Static semantic review: all four complete SKILL.md files, local host manifests,
associated engine/dashboard/target command paths and the cited tests were read.
Sections 7-9 were considered per skill, including N/A reasoning above.

Executed locally under WSL with the prescribed clean tool PATH:

- `python3 plugins/remote-compute/tests/test_compatibility_audit.py`: twelve
  tests pass, including the original three engine probes, four scan-branch
  cases, row/claim/reference ablations, public documentation and delta routing.
  The checker rejects duplicate marker pairs and recognized skill/gap headings.
  Archived delta text must match the exact canonical section 11 introduction
  and 11.1 bounds; appended proposals or text under other clauses do not count.
  A separate lifecycle test runs all seven document tests before and after a
  correct fold/archive in a temporary copy, without recursively running itself.
  Capture: `/tmp/194-review-r2-focused-green.log`.
- `bash plugins/remote-compute/tests/run-tests.sh`: exit 0, `ALL PASS`.
  Capture: `/tmp/194-review-r2-remote-green.log`. The suite executed the cited existing
  `section-remote-compute.sh`, `section-remote-command.sh` and
  `test_hardening.py` checks, as well as lint and the new audit section.
  Existing `--once`/CLI-alias tests run actual local snapshots; the new probe
  exercises automatic non-TTY fallback from a spaced cache path. Tests of
  interactive key labels inspect source; no interactive dashboard was launched.
- `shellcheck -x plugins/remote-compute/tests/section-compatibility-audit.sh`:
  exit 0, no diagnostics; `/tmp/194-shellcheck.log`.

Exact red capture: `/tmp/194-red.log`; original tests-first commit before
rebase: `a167b67`. It records three missing-document failures and three passing
engine probes. The parent independently replayed that commit's complete remote
suite: the same three document failures, three passing probes, and all
preexisting suite checks passing (`/tmp/194-independent-red.log`). The initial
draft fixture incorrectly omitted reservation expiry; before the red commit,
it was corrected to explicitly expired state using observed engine output and
the state helper's contract. Fixtures and mocks do not create live host or SSH
evidence. The logs are local execution artifacts, not portable live-host proof.

Review-fix red commit `b7363cb` records nine failing subcases for the scan
overclaim, duplicate audit structures and misplaced folded text, while the
original probes and new scan cases pass (`/tmp/194-review-r1-red.log`). The
parent independently replayed that exact focused red result in
`/tmp/194-review-independent-red.log`. The resulting correction changes only
audit wording and its tests; inherited scan behavior remains unchanged.

Lifecycle red commit `4b0b65c` reproduces the document-class failure after
correct archival (`/tmp/194-review-r2-red.log`). Its minimal fix makes the
obsolete-spec negative fixture explicitly obsolete, independent of whether
the real canonical spec has since been folded. Only temporary copies are
folded by the test; the repository's canonical spec remains untouched.

External validation is a separate evidence class:

- Claude: installed `claude plugin validate plugins/remote-compute` exited 0,
  "Validation passed"; captured in `/tmp/194-claude-validator.log`. This
  validates the manifest, not skill execution or instruction adherence.
- Codex skills: the parent ran WSL `python3` with the existing
  `~/.codex/skills/.system/skill-creator/scripts/quick_validate.py` (on the
  Windows-mounted home) against each of the four unchanged skill directories.
  All four exited 0 with "Skill is valid!". Command shape:
  `python3 <installed-quick_validate.py> <worktree>/plugins/remote-compute/skills/<skill>`.
  This is parent-reported metadata lint evidence, not a copied validator or
  host execution test.
- Codex plugin: `~/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py`
  is absent at the parent-checked Windows location. External plugin validation
  is unavailable/unverified, not passed. No validator was installed.

Live Claude/Codex installation, live SSH, and interactive dashboard execution: unverified (not performed).

No cloud execution, real-machine registration, target install, LAN scan,
personal-state write or pipeline was performed for this audit. Tests use
disposable local fixtures. No native macOS or standalone Linux host run was
performed; only WSL execution is measured here. Section 10.1's broader CI
infrastructure requirements are unchanged and outside this task. The current
local-only instruction controls this work; no pipeline evidence is presumed.
The parent owns the exact full repository gate, independent review, merge,
and post-merge folding of CDX-050 in the [spec-delta registry](spec-deltas/)
(pending at `CDX-050.md`, archived at `applied/CDX-050.md` after the fold).

## Project inventory: scoped #277 addition

This entry covers only the new `neural-network-projects-list` skill and does not
complete CDX-042 or extend the four-skill remote-compute audit above.

| Skill | Claude support | Codex support | Evidence and limitations |
| --- | --- | --- | --- |
| `neural-network-projects-list` | Automatic skills-directory discovery; source reviewed | Existing manifest `skills: ./skills/` discovery; source reviewed | Local metadata and hermetic CLI tests; live host invocation unverified |

The [skill](../plugins/spec-workflow/skills/neural-network-projects-list/SKILL.md)
uses `name`/`description` frontmatter and one Python engine resolved from its
installed skill location, with quoted absolute paths independent of cwd.
`allowed-tools` is a Claude-only enhancement, not a cross-host security boundary.
Arguments come from request text, without implicit `ARGUMENTS` substitution or
load-time commands. No delegation/model routing, session metadata, board access,
or approval flow applies. Invalid configs remain inventory rows, so no workflow
preflight rejects them. Tests exercise local discovery, shared scanner caller
policies, config validation, metadata registration and no-write behavior; they
do not establish live Claude/Codex installation or invocation parity. The command
requires Python 3 and PyYAML; no native PowerShell execution was tested.
