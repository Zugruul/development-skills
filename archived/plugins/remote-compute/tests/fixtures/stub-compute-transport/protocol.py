"""Protocol adapter for the legacy shell fixtures. No commands are executed.

Real coordination/process behavior is tested independently in test_hardening.py.
Keep handler failures authoritative and log decoded requests for assertions.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

arguments = shlex.split(shlex.split(sys.argv[-1])[-1])
action, request = arguments[-2], json.loads(arguments[-1])
probe = subprocess.run(["bash", os.environ["FAKE_SSH_HANDLER"], *sys.argv[1:-1], "protocol " + action], capture_output=True)
if probe.returncode:
    sys.stderr.buffer.write(probe.stderr)
    sys.exit(probe.returncode)
with open(os.environ["FAKE_TRANSPORT_LOG"], "a") as log:
    log.write("protocol %s %s\n" % (action, json.dumps(request)))
    if action == "launch":
        log.write("command: %s%s\n" % ((request.get("activate") + " && ") if request.get("activate") else "", request["cmd"]))
state_file = Path(os.environ["FAKE_TRANSPORT_LOG"] + ".locks.json")
state = json.loads(state_file.read_text()) if state_file.exists() else {}
reply = {}
if action in ("lock", "unlock"):
    previous = state.get("lock")
    if previous and previous.get("holder") != request.get("holder") and not request.get("force"):
        print(json.dumps({"error": "LOCKED by " + previous["holder"]}))
        sys.exit(6)
    state["lock"] = request if action == "lock" else None
    state_file.write_text(json.dumps(state))
    reply = {"previous": previous}
elif action == "reserve":
    reply = {"reserved": True}
elif action == "launch":
    reply = {"launched": True}
elif action == "status":
    status = subprocess.run(["bash", os.environ["FAKE_SSH_HANDLER"], request["id"] + " exitcode"], capture_output=True, text=True)
    reply = {"state": "running" if "__RUNNING__" in status.stdout else "done", "exitcode": 0}
elif action == "cap-commit":
    reply = {"installed": True}
elif action == "cap-remove":
    reply = {"removed": True}
elif action == "abort":
    reply = {"aborted": True}
# Identity intentionally models an older target without a UUID. Dedicated
# real broker tests exercise UUID creation and cross-client stability.
print(json.dumps(reply))
