# Remote compute

Use another computer as compute. You register a machine once, then send work to
it from wherever you happen to be working.

The typical case: you work on a laptop, but a second machine has the GPU. This
lets you drive that machine without logging into it by hand every time.

- **Key-based SSH only.** You are never asked for a password, and none is ever
  stored.
- **Jobs run detached.** They keep going if you close your laptop, and you can
  check on them later.
- **Tools are data, not code.** Adding support for a new tool means adding a
  small description file, never changing the software.

---

## The mental model

Five ideas. Once these click, everything else follows.

**A machine** is a computer you own that can accept work. You give it a short
nickname when you register it. Everything afterwards refers to that nickname.

**The registry** is a file on *your* computer listing the machines you know
about, what hardware each has, and what work each can do. It is the only thing
the tool reads to decide where work goes.

**A capability** is support for a particular tool — an image generator, a model
trainer. It arrives as a small folder holding a description file and any
scripts that need to run on the machine. You install it onto a machine once.

**A job** is a named, reusable recipe: "run this command, with these
parameters, on that machine." You declare it once, then run it as often as you
like with different values.

**A dispatch** is one run of a job. It gets its own directory on the machine,
its own log, and its own exit code, so you can check on it long after the fact.

---

## Part 1 — Preparing a machine

This is the only part you do by hand, and only once per machine.

The machine needs to accept SSH connections, and you need to be able to reach
it on your network.

- **Turn on SSH.** On Linux (including Windows/WSL): install an SSH server and
  enable it. On macOS: System Settings → General → Sharing → Remote Login.
- **Give it a stable address.** A DHCP reservation on your router is the
  simplest way, so the address stops changing.
- **Stop it sleeping.** A machine that suspends mid-job loses the job.
- **Keep tools on loopback.** If the machine runs a service (an image
  generator, for example), leave it bound to its own local address. It does not
  need to be exposed to your network — the connection travels inside SSH.

If you forget the details, the tool prints them:

```bash
remote-compute setup-sheet linux     # or wsl2, or macos
```

It also prints the right sheet automatically when a check fails during
registration, so you rarely need to ask.

---

## Part 2 — Registering the machine

```bash
remote-compute register <nickname> <your-user>@<machine-address>
```

`<nickname>` is yours to choose. It becomes the SSH alias you use from then on.

**This command is safe to run again at any time.** It does not "set up once and
forget" — every run re-checks the whole picture: that the SSH alias exists and
points at the right place, that key access works, that the machine's identity
is still the one you approved, what hardware it has, and that its working
directories exist. Run it whenever you think something drifted.

It may stop and ask you for something. That is by design — it tells you exactly
what to do instead of failing vaguely:

- **Keys not set up yet.** It prints the one command you need to run to install
  your key, waits for you to do it, and then works on the next run.
- **Unknown machine identity.** It shows you the machine's fingerprint and asks
  you to confirm it before trusting it. Approve it and re-run with the flag it
  suggests.
- **Cannot reach it.** It tells you the machine is off, asleep, or not
  listening, and prints the setup sheet.

When it succeeds, it prints what it actually measured:

```
REGISTERED <nickname> (<user>@<address>)
  os:     linux
  gpu:    <GPU model>   vramMB: 24463   cuda: 13.3   driver: 610.62
  ramGB:  94
  disk:   /            freeGB: 876
  disk:   /mnt/data    freeGB: 720     (slow)
```

**Nothing here is assumed.** Every value comes from a real command run on the
machine. Anything that cannot be read is recorded as an error, never guessed.
If it says the machine has no GPU, that is because asking produced no GPU.

Two details worth understanding when you see them:

*Marked "slow"* means that disk is a network or cross-operating-system mount.
They are much slower for the many-small-files work that software tends to do.
Keep datasets and working directories off them.

*RAM may be smaller than you expect* on a machine running Linux inside Windows,
because that environment gets a share of the machine's memory rather than all
of it. The tool records which of the two the number refers to, so it is not
mistaken for a wrong reading.

---

## Part 3 — Telling the machine what it can do

### Environments

If work needs a particular software environment — a Python virtual environment,
say — declare it once:

```bash
remote-compute add-env <nickname> <env-name> \
  --activate 'source ~/<path-to-env>/bin/activate' \
  --verify 'import <library>; print(<library>.__version__)'
```

The environment is checked **immediately**, on the real machine, and whatever it
prints is recorded word for word. If the library is missing, you find out now
rather than when a long job fails.

Jobs can then say which environment they need, and it is activated before the
command runs.

### Capabilities

Support for a specific tool comes as a folder — a *bundle* — containing a
description file and any scripts that must exist on the machine. Install it:

```bash
remote-compute install-capability <nickname> <path-to-bundle-folder>
```

This copies the scripts over and registers the jobs the bundle describes. See
what a machine has:

```bash
remote-compute capabilities <nickname>
```

The important property: **installing support for a new tool never requires
changing the software.** A bundle is data. This is why one machine can serve
completely unrelated purposes — generating images for one project and training
a model for another — without either side knowing the other exists.

---

## Part 4 — Declaring a job

A job is a named recipe with named parameters. Here is the pattern, using an
imaginary image-generation setup as the example.

Say you have built a workflow in an image tool and exported it. The workflow
has several inputs you want to change per run: the description of what to draw,
the things to avoid, a number that controls randomness, and which model to use.

First, look at what the workflow actually exposes:

```bash
remote-compute run <nickname> <tool>:list-nodes \
  --param 'workflow=<path-to-workflow-file-on-the-machine>'
```

This prints every part of the workflow you can change, with its address and
current value. Some are marked as *linked* — those are fed by another part of
the workflow, and cannot be set directly.

Now declare the job:

```bash
remote-compute add-job <nickname> creature-portrait \
  --workdir '<a-working-directory-on-the-machine>' \
  --description 'Draws a single creature from a description' \
  --cmd "<the command to run> \
         --workflow '<path-to-workflow-file>' \
         --set 40.text={describe} \
         --set 39.text={avoid} \
         --set 36.value={variation} \
         --set 37.model_name={model}" \
  --param 'describe:[^`$;|&<>]+' \
  --param 'avoid:[^`$;|&<>]+' \
  --param 'variation:[0-9]+' \
  --param 'model:[^`$;|&<>]+' \
  --param-default 'model=<your-usual-model>'
```

### Understanding the two sides

This is the part that confuses people, so it is worth being explicit.

```
--set 40.text={describe}
      └────┬───┘ └───┬──┘
           │         └─ a name YOU invented
           └─ the workflow's real address
```

The **left side** is the workflow's own addressing: part number 40, input named
`text`. Those names come from the tool. You cannot change them.

The **right side** is a label you made up for your own convenience. `describe`
is friendlier than `40.text`, and it is what you will type on every run.

The `--cmd` line is the only place these two meet, and it *is* the mapping.
There is no separate mapping file. If you would rather the parameter be called
`text`, write `--set 40.text={text}` and declare `--param 'text:...'`.

### Why numbers instead of names

You can address a part of the workflow by its name instead of its number — but
only if that name is unique. Workflows often contain two parts of the same kind
(one for what to draw, one for what to avoid) sharing an identical name. When
that happens, name lookup deliberately refuses rather than guessing, and you use
the number. Renaming those parts in your workflow tool and re-exporting is the
fix if you prefer names.

### Required and optional parameters

Every declared parameter is required by default. `--param-default NAME=VALUE`
makes one optional with a fallback. The default is checked against the
parameter's own rules when you declare it, so a default can never be a trap
that only fails later.

**One subtlety that surprises people.** An optional parameter still *fills in*
its default. It does not skip the setting. So if a job sets the output location
and you omit that parameter, the default location wins — the workflow's own
setting is still overwritten. If you want a setting left exactly as the
workflow has it, use the value `@workflow`, which means "do not touch this".

### The patterns

Each `--param` carries a rule describing which values are allowed. This is not
decoration. Values are checked against the rule before they are used, and are
then quoted so they cannot be interpreted as commands. A number-only rule for
something that must be a number will catch a typo before any work starts.

---

## Part 5 — Running work

```bash
remote-compute run <nickname> creature-portrait \
  --param 'describe=a small round yellow creature, red cheeks, in a grassy field' \
  --param 'avoid=blurry, text, watermark, human' \
  --param 'variation=884213770156422'
```

That is the whole thing. To make ten variations, run it ten times with a
different `variation` value. To try a different model, add
`--param 'model=<other-model>'`.

The job starts on the machine and returns immediately. It keeps running whether
or not you stay connected.

### Naming runs

Each run gets an identifier. You can supply one with `--job-id`, or let the
capability name it for you.

Bundles that produce files (images, video, trained models) can describe how runs
should be named — typically a fixed prefix, then which model was used, then the
variation number last. That way a batch sorts together, and any single output
can be traced back to exactly what made it. The rule lives in the bundle, so
every run of that kind is named consistently without you thinking about it.

### Checking on a run

```bash
remote-compute job-status <run-id>     # running, done, or failed
remote-compute job-logs   <run-id>     # what it printed
remote-compute job-pull   <run-id> --dest ./out     # bring results back
```

**These work even if your computer restarted.** The state lives in files on the
machine — the log, the process id, the exit code — so nothing depends on the
session that started the work still being alive.

---

## Part 6 — Watching a machine

There is a dashboard you run **on the machine** — the one receiving the work,
not the one sending it:

```bash
ssh -t <nickname> 'python3 ~/.remote-compute/tools/compute-top.py'
```

The `-t` matters: it gives the dashboard a screen to draw on. Without one it
prints a plain snapshot instead, which is what you want when piping it
somewhere.

It shows every run: whether it is going, how long it has taken, whether it
succeeded, and how much it printed. Arrow keys move, `L` opens a run's log
(scroll with arrows and page keys), `f` filters to just the running or just the
failed ones, `d` removes a run from the history, `D` clears all finished ones.
It refuses to delete something still running.

Each machine shows its own work. If you have two machines, you look at two
dashboards.

---

## Part 7 — Sharing a machine

If more than one person or project uses a machine, two things prevent
collisions.

**A lock.** Take one when you need the machine to yourself:

```bash
remote-compute lock   <nickname> --reason 'running an experiment'
remote-compute unlock <nickname>
```

Work sent while someone else holds the lock is refused, and told who holds it
and why. Jobs also take the lock automatically for their duration.

**A concurrency limit.** By default a machine runs one job at a time. Anything
sent while it is busy is refused with a message naming what is running. This is
deliberately strict: two heavy jobs on one graphics card is usually worse than
waiting. Raise the limit in the registry if your machine can genuinely handle
more.

If the machine cannot be reached to check, the request is refused rather than
allowed. A machine too busy to answer is exactly when you least want to pile on.

---

## Part 8 — Cleaning up

```bash
remote-compute remove-job        <nickname> <job-name>
remote-compute remove-capability <nickname> <name> [--purge-remote]
remote-compute remove            <nickname>
```

`remove-job` retires one recipe. `remove-capability` uninstalls support for a
tool and everything it declared — but leaves its files on the machine unless you
add `--purge-remote`, because deciding to stop using something here should not
silently delete files over there. `remove` forgets the machine entirely and
never touches it.

None of these delete run history or results. Use the dashboard on the machine
for that.

---

## Where everything lives

**On your computer**, one folder holds it all:

```
~/.remote-compute/
  resources.yaml     the machines, what they have, what they can do
  jobs/              one small file per run you started
```

**On each machine**, one folder mirrors it:

```
~/.remote-compute/
  jobs/<run-id>/     the log, process id, exit code and results of one run
  caps/<name>/       scripts belonging to an installed capability
  tools/             shared helpers, like the dashboard
```

Two things are worth knowing about this.

**It is never committed to a repository.** Which machines you can reach is a
fact about your hardware, not about a project. A colleague cloning the same
project gets their own registry describing their own machines.

**Job recipes live only in the registry.** A job you declare by hand exists on
the computer where you declared it. If you want it to survive moving to another
computer, either keep the declaring command in a script, or package it as a
bundle — bundles are files you can keep alongside your project.

---

## The rules it will not break

These are enforced by the software, not just documented.

**No passwords, ever.** Only key-based access, and always in a mode that fails
rather than prompting.

**Never administrator commands.** Not on your computer, not on the machine.
Anything needing elevated rights is printed for you to run yourself, deliberately.

**Values are checked, then quoted.** Every value you pass is matched against its
declared rule and then quoted, so it is treated as text rather than as a
command. This holds even for values coming from a description file.

**Your workflow is never rewritten.** Only the values of settings that already
exist are changed. The structure of what you built is left exactly as you built
it, and anything that would require rewiring is refused.

**Measurements are real or absent.** Anything that cannot be measured is
recorded as an error, never guessed. A machine's description is either true or
visibly unknown.

---

## When something goes wrong

**"Cannot reach the machine."** It is off, asleep, or not accepting connections.
Note that a machine can be perfectly reachable while ignoring the usual "are you
there" ping — Windows does this by default — so reachability is tested the same
way an actual connection would be made.

**It asks you to install a key.** Expected on a new machine. Run the command it
prints, then register again.

**It asks you to confirm the machine's identity.** Also expected the first time.
Check the fingerprint and re-run with the suggested flag. If this appears on a
machine you have used before, stop and find out why its identity changed.

**"That value is not offered."** Some settings only accept a fixed list — the
names of installed models, for example. Those are checked against the machine
before any work starts, so you get the valid list back immediately rather than
after a wasted run.

**"The machine is busy."** Something else is running and the limit is one at a
time. Wait, or raise the limit if the machine can handle it.

**A run finished instantly with an error.** Read its log. The most common causes
are a file that does not exist *on the machine* (paths are always resolved
there, not where you typed the command), or a file in the wrong format.

**A value with spaces was split apart.** When passing several settings inside a
single parameter, quote any value containing spaces. The error message says so.

---

## Adding support for a new tool

A capability bundle is a folder with a description file and whatever scripts
must exist on the machine:

```yaml
version: 1
name: <tool-name>
description: >-
    What this does, and any rule someone using it must respect.
payload:
-   <script-that-runs-on-the-machine>
jobs:
    <job-name>:
        description: What this job does and what each parameter means.
        cmd: <command> {capdir}/<script> --input {something}
        params:
            something: "<rule describing allowed values>"
```

Two placeholders are provided for you: `{capdir}` is where the scripts landed on
the machine, and `{jobdir}` is the directory belonging to the current run.
Everything else in the command must be a declared parameter. Use both
placeholders bare — they already expand to a safely quoted path.

**Write results into the run's own directory.** That is what gets brought back.

That is the whole contract. There is no code to change, no list to add yourself
to. Support for a tool is a folder, which means it can live next to the project
that needs it and be installed onto any machine you own.
