#!/usr/bin/env bash
python3 -m not_a_real_module <<EOF
x = 1
match x:
    case 1:
        print(1)
EOF
