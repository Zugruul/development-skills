#!/usr/bin/env bash
python3 -c '
import json
d = json.loads("{}")
print(f"{d["id"]}")
'
