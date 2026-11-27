#!/usr/bin/env bash
python3 -c '
import json, sys
for f in json.load(sys.stdin)["fields"]:
    print(f'"'"'{f["id"]}  {f["name"]}'"'"')
'
