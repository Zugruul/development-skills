#!/usr/bin/env bash
# src/result.sh -- sourced by the scripts one level up; not run by itself.
# What an agent finished with, read strictly, as a claim: {kind: result|step|none, result, ref,
# name, line}. A claim is never proof; the orchestrator checks the evidence before it records.
# Only a line that IS the protocol line counts: it starts with NODE (after spaces, a known
# bullet, or one pair of backticks around the whole line), so a quote, an example in prose or
# the brief's template never matches. Text after two or more spaces is screen decoration.
# The variables are read by the scripts that source this file.
# shellcheck disable=SC2016,SC2034

CLAIM_JQ='
    def nothing: {kind: "none", result: "", ref: "", name: "", line: ""};
    def lineclaim($node):
        . as $raw
        | (sub("^\\s+"; "") | sub("^[⏺●•◦▪⬤]\\s*"; "") | sub("\\s+$"; "")
           | (if test("^`[^`]*`$") then .[1:-1] else . end) | sub("\\s{2,}.*$"; "")) as $l
        | ( [$l | capture("^NODE " + $node + " RESULT: (?<result>pass|question)( (?<ref>[^\\s<>\"`]+))?$") | . + {kind: "result"}]
          + [$l | capture("^NODE " + $node + " RESULT: (?<result>fail)( (?<ref>[^<>\"`]+))?$") | . + {kind: "result"}]
          + [$l | capture("^NODE " + $node + " STEP: (?<name>[A-Za-z0-9_.-]+) (?<result>pass|fail|question)( (?<ref>[^\\s<>\"`]+))?$") | . + {kind: "step"}] )
        | if length == 0 then empty else (nothing + (.[0] | with_entries(.value //= "")) + {line: $l}) end;'

# The last protocol line anywhere in a screen.
screen_claim() { # node, text
    printf '%s' "$2" | jq -Rsc --arg n "$1" "$CLAIM_JQ"' [split("\n")[] | lineclaim($n)] | last // nothing'
}

# Only the last non-empty line of an agent's final message (a Stop hook has it).
last_line_claim() { # node, message
    printf '%s' "$2" | jq -Rsc --arg n "$1" "$CLAIM_JQ"' ([split("\n")[] | select(test("\\S"))] | last // "") as $l | [$l | lineclaim($n)] | .[0] // nothing'
}

# The result file an agent writes last, <output path>.result.json: {node, run, result, ref,
# final}. Nothing unless it parses and names this node and this run.
file_claim() { # node, run, output path
    [ -n "$2" ] && [ -n "$3" ] && [ -f "$3.result.json" ] || return 0
    jq -c --arg n "$1" --arg r "$2" "$CLAIM_JQ"'
        select(type == "object" and .node == $n and (.run | tostring) == $r and (.result | IN("pass", "fail", "question")))
        | nothing + {kind: (if .final == false then "step" else "result" end), result: .result,
                     ref: (.ref // "" | tostring), name: (.name // (if .final == false then "step" else "" end)),
                     line: (. | tojson)}' "$3.result.json" 2>/dev/null
}

# Where a hook keeps its claim about a node.
claim_file() { # lane folder, lane, node
    printf '%s/claims/%s/%s.json\n' "$1" "$2" "$3"
}
