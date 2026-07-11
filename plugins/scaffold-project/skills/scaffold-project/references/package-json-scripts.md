# package.json wiring

Every scaffolded script must be runnable via `pnpm <name>` / `npm run <name>`,
not just by knowing its path under `scripts/`. Merge these into the new
project's `package.json` `scripts` block (adjust the runner — `bash` shown —
if the project's scripts end up in a different language):

```json
{
    "scripts": {
        "dev": "bash scripts/dev.sh",
        "start": "bash scripts/start.sh",
        "stop": "bash scripts/stop.sh",
        "build:images": "bash scripts/build.sh",
        "port-forward": "bash scripts/port-forward.sh",
        "port-forward:stop": "bash scripts/port-forward-stop.sh",
        "clean:docker": "bash scripts/clean-docker.sh",
        "k8s:bootstrap": "bash scripts/bootstrap-minikube.sh",
        "k8s:delete": "bash scripts/delete-minikube.sh"
    }
}
```

Don't silently drop an entry because the project's `package.json` already has
a same-named script for something else — rename to a `k8s:`-prefixed variant
instead of overwriting (e.g. `k8s:start` if `start` already means something
else, like a Next.js prod server).
