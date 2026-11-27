#!/usr/bin/env bash
NAME="probe"
out="$(python3 -c "
x = '$NAME'
match x:
    case 'probe':
        print('matched')
")"
