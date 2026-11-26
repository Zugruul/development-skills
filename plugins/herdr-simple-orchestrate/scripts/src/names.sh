#!/usr/bin/env bash
# src/names.sh -- sourced after src/herdr.sh; not run by itself.
# The rules for agent names and workspace labels.
#   name_problem NAME   -> NAME_PROBLEM (empty when the name is valid and unused)
#   label_from TEXT     -> LABEL_TEXT (hyphen-separated letters and digits)
#   label_problem TEXT  -> LABEL_PROBLEM (empty when the label is valid)

# The variables are read by the scripts that source this file.
# shellcheck disable=SC2034
LABEL_MAX=80
NAME_PROBLEM=""
LABEL_TEXT=""
LABEL_PROBLEM=""

name_problem() { # name
    local LC_ALL=C name="$1" re='^[a-z][a-z0-9_-]{0,31}$' taken base n
    NAME_PROBLEM=""
    if ! [[ "$name" =~ $re ]]; then
        NAME_PROBLEM="NAME INVALID: '$name' must match [a-z][a-z0-9_-]{0,31} (lowercase letter first, then lowercase letters, digits, _ or -, 32 characters at most)."
        return 0
    fi
    agents_load
    taken="$(printf '%s' "$AGENTS_JSON" | jq -r '.[] | .name | strings')"
    if printf '%s\n' "$taken" | grep -qxF -- "$name"; then
        base="${name:0:29}"
        n=2
        while printf '%s\n' "$taken" | grep -qxF -- "$base-$n"; do
            n=$((n + 1))
        done
        NAME_PROBLEM="NAME TAKEN: a live agent is already named '$name'. Free alternative: $base-$n"
    fi
    return 0
}

label_from() { # text
    LABEL_TEXT="$(printf '%s' "$1" | LC_ALL=C tr '\n' ' ' | LC_ALL=C sed -e 's/[^A-Za-z0-9][^A-Za-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//')"
}

label_problem() { # text
    local LC_ALL=C text="$1" re='^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$'
    LABEL_PROBLEM=""
    if ! [[ "$text" =~ $re ]]; then
        label_from "$text"
        LABEL_PROBLEM="label '$text' is not hyphen-separated letters and digits without spaces"
        [ -n "$LABEL_TEXT" ] && LABEL_PROBLEM="$LABEL_PROBLEM -- use $LABEL_TEXT"
        return 0
    fi
    if [ "${#text}" -gt "$LABEL_MAX" ]; then
        LABEL_PROBLEM="label '$text' is longer than $LABEL_MAX characters"
    fi
    return 0
}
