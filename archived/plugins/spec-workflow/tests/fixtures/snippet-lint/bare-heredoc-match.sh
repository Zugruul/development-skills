#!/usr/bin/env bash
V="1"
python3 <<EOF
match $V:
    case 1:
        print("one")
EOF
