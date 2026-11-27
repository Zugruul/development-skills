#!/usr/bin/env bash
declare -A m
mapfile -t lines < /dev/null
lower="${SOME_VAR,,}"
tail="${SOME_VAR:0:-1}"
cmd &>> /tmp/out.log
