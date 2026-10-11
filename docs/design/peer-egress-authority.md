# Design - peer: shipped egress authority (#529)

Grounded in SPEC-PEER-REVIEW.md sections 4-9 and the owner's #529 triage.
This decision supersedes the historical HTTP-registry assumptions in
compute-registry-plan-v3.md and peer-E0.md. Canonical contract edits must travel
through docs/spec-deltas/529.md and be folded only after merge.

## Components

- Peer-review provider selection reads scripts/providers.tsv, then dispatches to
  trusted local scripts. Shipped providers invoke the user-installed Codex or
  Claude CLI; both must be represented in disclosure and contract text.
- The selected CLI owns authentication and transport configuration. Review flags
  constrain intended file editing; they are not a plugin-enforced network
  endpoint allowlist. Provider-registry overrides also name executable code and
  must be trusted.
- Remote-compute's user-local ~/.remote-compute/resources.yaml records SSH
  machines, host identity, environments and declared recipes. It is not a peer
  HTTP model/token endpoint authority, and registration grants no such consent.
- The former .claude/compute-registry.yaml, status skill and synchronous HTTP
  helper were proposals, not shipped controls. No code reads that registry.

## Interfaces / Contracts

The existing provider command shapes, selection, empty-diff short circuit,
read-only flags and legacy registry behavior remain unchanged. No HTTP
dispatcher, second registry, new schema, credentials, network policy or
production implementation is added by this task.

Current disclosure must cover the selected provider's cloud and potential repo
context as well as the embedded diff. It must not claim the plugin enforces
destination restrictions inside user-configured CLIs. Raw provider errors are
currently forwarded; unimplemented token-redaction requirements are not active
security guarantees.

## Key Sequences

1. The human selects a trusted provider entry, then the skill resolves the diff.
2. Existing provider scripts invoke their local CLI with existing review flags.
3. The selected CLI may transmit review material using its configured transport;
   the plugin labels the external findings and does not apply them.
4. A future HTTP backend requires an explicit reviewed endpoint/authentication/
   redirect/redaction design and tests before it is enabled. SSH registration
   alone cannot authorize that path.

## Decisions

- Document shipped reality rather than instantiate the obsolete registry.
- Mark E1 HTTP requirements and backlog entries as deferred historical plans,
  not completed implementations or currently enforced invariants. Preserve
  historical proposals with clear status rather than rewriting their history.
- Reconcile glossary, architecture, requirements, invariant/config metadata,
  performance/testing claims and public docs together via a paste-ready delta.
- Test the effective pending contract before merge, then the canonical contract
  after folding; tests must not accept an arbitrary delta as a blanket bypass.
- Run the full local repository gate plus the separate peer-review suite and
  validators. No pipeline changes or dependency on cloud checks.

## Out Of Scope

Remote execution security (#347), assistant integration, new provider backends,
changes to existing CLI semantics, filesystem/network sandbox claims, live
cloud review, actual endpoint provisioning, and marketplace-wide compatibility.
