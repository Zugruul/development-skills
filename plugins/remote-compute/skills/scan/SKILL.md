---
name: scan
description: Re-finds registered remote-compute machines whose network address changed (DHCP gave the GPU box a new IP, so ssh times out at the old one) -- sweeps the subnet for ssh hosts, identifies each machine by the host key already pinned in known_hosts, and converges known_hosts, the ssh alias, and the registry to the new address. Use for '/remote-compute:scan', 'the box is up but ssh times out', 'did its IP change', 'find gpubox on the network', or after any UNREACHABLE from register/connect while the human says the machine is on.
---

# scan

Part of the remote-compute plugin. One verb of the same engine script:

```bash
python3 "../../scripts/remote-compute.py" scan                       # every registered machine
python3 "../../scripts/remote-compute.py" scan gpubox                # just one
python3 "../../scripts/remote-compute.py" scan --dry-run             # report, change nothing
python3 "../../scripts/remote-compute.py" scan --subnet 10.0.0.0/24  # override the sweep range (repeatable)
python3 "../../scripts/remote-compute.py" scan gpubox --pick gpubox=192.0.2.5  # resolve a DUPLICATE_IDENTITY
python3 "../../scripts/remote-compute.py" identity gpubox            # what the machine says it is
```

**Bare invocation** (`/remote-compute:scan` with no arguments): run `scan` over
every registered machine, relay each status line, and summarise what moved.

## What it does

1. For each registered machine, TCP-connects to port 22 at its recorded
   address (never ICMP: Windows boxes block ping) and asks sshd for its host
   key. Key present and matching the pinned one: `OK <nick> <host>`, nothing
   written.
2. Otherwise the machine is stale (`UNREACHABLE`, or `KEY_MISMATCH` when a
   stranger now answers at the old address). One sweep covers all stale
   machines: the /24 of each old address plus this machine's own /24, unless
   `--subnet` was given. Every address answering on port 22 is key-scanned.
3. A candidate is the same machine only when BOTH factors agree: it presents
   a key already pinned in known_hosts for the old address, AND its
   `~/.remote-compute/.identity` stamp (written by `register`/`install-tools`,
   holding the nick and only that) says `<nick>`. The stamp is read with
   exactly the matched key pinned in a throwaway known_hosts, so trust never
   widens. On a match it pins that key under the new address, rewrites the
   `Host <nick>` block (keeping any Port/IdentityFile lines the human added),
   updates `ssh.host` in the registry (`ssh.previousHost` keeps the old one),
   verifies a BatchMode login, and stamps the identity if the box predates
   stamping: `MOVED <nick> <old> -> <new>`.

Identity is the pinned key plus the stamp, never the address: scan cannot
accept a key the human has not acked through `register`, a different machine
squatting on the old IP is reported, not adopted, and a machine presenting
the right key but another nick's stamp is refused too.

## Statuses to relay

- `OK` -- fine where it is.
- `MOVED` (or `WOULD_MOVE` under `--dry-run`) -- address updated; the ssh alias
  still works, so `compute-top`, `dispatch`, `exec` need no change. Project
  overlays written by `enable` hold no host, so nothing to redo there.
- `NOT_FOUND` (exit 1) -- the box is off, on another network, or sshd is down.
  Tell the human which subnets were swept and how many ssh hosts answered;
  if they are on a different LAN now, re-run with `--subnet`.
- `NO_PINNED_KEY` (exit 1) -- nothing to identify the machine by. Re-run
  `register <nick> user@host` (it pins the key after the human's ack).
- `IDENTITY_MISMATCH` (exit 7) -- the host key matches but the stamp names a
  different nick. Usually one physical machine registered under two names.
  Ask the human which name is right, then `install-tools <that nick>`
  re-stamps it and `remove <the other>` retires the duplicate entry.
- `DUPLICATE_IDENTITY` (exit 7) -- two or more addresses present the key AND
  claim the same nick (a cloned disk or VM, or an old image). **Ask the human
  which address is really `<nick>`** -- never guess -- then apply their
  answer with `scan <nick> --pick <nick>=<host>`. Offer to give the other
  machine its own name with `register <newnick> user@<other host>`, which
  stamps it; until then every scan will keep flagging the pair.
- `OK ... (no identity file yet)` -- a box registered before stamping existed;
  `install-tools <nick>` stamps it.
- `NEEDS_KEY_AUTH` after `MOVED` -- the address converged but key login
  failed; relay the `ssh-copy-id` guidance from the remote-compute skill.

## Rules

- Prefer `scan` over hand-editing `~/.ssh/config`, `known_hosts` or the
  registry when an address changes -- it converges all three consistently.
- Never work around `KEY_MISMATCH` by deleting the known_hosts entry; that is
  exactly the case the pin exists for. Ask the human what is at that address.
- Sweeps larger than /22 are refused; pass a narrower `--subnet`.
- A duplicate identity is resolved by the human's answer, never by the first
  address that happened to reply.
