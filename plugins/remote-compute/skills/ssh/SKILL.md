---
name: ssh
description: Lists every machine registered as a remote-compute resource and prints, in the chat, the ready-to-paste ssh commands for each -- a plain shell, the live job dashboard (`remote-compute top`), the one-shot job table and the GPU summary -- with whether each box is answering right now. Use for '/remote-compute:ssh', 'how do I connect to the GPU box', 'give me the ssh command for storm', 'which compute machines do I have', or when the human wants to go hands-on with a machine.
---

# ssh

Part of the remote-compute plugin. One verb of the same engine script:

```bash
python3 "../../scripts/remote-compute.py" connect            # every registered machine
python3 "../../scripts/remote-compute.py" connect gpubox     # just one
```

**Bare invocation** (`/remote-compute:ssh`): run `connect` and relay the output
as a fenced block per machine, so the human can copy a line straight into
their own terminal. Do not open the ssh session yourself -- the interactive
shell and the dashboard need the human's terminal (the `-t` allocates one).

For each machine the script prints one header line (nick, user@host,
platform, GPU, `up`/`down`, lock holder if locked) followed by:

```text
ssh gpubox                           # shell
ssh -t gpubox remote-compute top     # live job dashboard
ssh gpubox remote-compute jobs       # one-shot job table
ssh gpubox remote-compute gpu        # GPU summary
```

`remote-compute` is the on-machine command `register` installs on every
box (see the remote-compute skill, "The on-machine command"). If the header
says the command is not installed yet, offer `install-tools <nick>`. If a
machine is `down` and the human says it is on, suggest `/remote-compute:scan`
-- its DHCP address may have changed.
