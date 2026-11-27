#!/usr/bin/env bash
F="/tmp/whatever"
out="$(python3 -c "
d = {'path': '$F'}
print(d['path'])
")"
