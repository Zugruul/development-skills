#!/usr/bin/env bash
# src/pattern.sh -- sourced after src/common.sh; not run by itself.
# The pattern language, frozen: four node types (agent, gate, human, pr: draft) and three edge
# kinds (needs, when, retry with max). No expressions.
#   pattern_problems JSON REPO -> one problem per line on stdout, nothing when valid

# shellcheck disable=SC2016  # $p and $n are jq variables
# jq: every problem of a pattern, one string each. Roles are checked by the caller.
# Inside: a cycle check over needs (Kahn), and every {placeholder} must be an input, idea, gate or output_path.
PATTERN_JQ='
. as $p
| def nodes: ($p.nodes // {});
  def names: (nodes | if type == "object" then keys else [] end);
[
  (if (.when | type) != "string" or (.when | length) == 0 then "when: required, one sentence saying when the router picks this pattern" else empty end),
  (if has("inputs") and ((.inputs | type) != "array" or any(.inputs[]; type != "string")) then "inputs: must be a list of names" else empty end),
  (keys - ["when", "inputs", "nodes", "done"] | .[] | "unknown top-level key: \(.)"),
  (if (nodes | type) != "object" or (nodes | length) == 0 then "nodes: at least one node" else empty end),
  (nodes | to_entries[] | .key as $n | .value as $v |
    (if ($n | test("^[a-z][a-z0-9-]{0,15}$") | not) then "node \($n): name must match [a-z][a-z0-9-]{0,15}" else empty end),
    (if ($v | type) != "object" then "node \($n): must be a map" else
      ([("agent", "gate", "human", "pr")] | map(select(. as $k | $v | has($k))) | length) as $types |
      (if $types != 1 then "node \($n): needs exactly one of agent, gate, human, pr" else empty end),
      (if $v | has("pr") and $v.pr != "draft" then "node \($n): pr must be draft (the orchestrator only opens draft pull requests)" else empty end),
      (if $v | has("access") and ($v | has("agent") | not) then "node \($n): access is only for agent nodes" else empty end),
      ($v | keys - ["agent", "gate", "human", "pr", "kind", "brief", "needs", "when", "retry", "access"] | .[] | "node \($n): unknown key \(.)"),
      (($v.needs // []) | if type != "array" then "node \($n): needs must be a list" else .[] | select(IN(names[]) | not) | "node \($n): needs unknown node \(.)" end),
      (if $v | has("when") then (if ($v.when | IN("pass", "changes", "fail")) then empty else "node \($n): when must be pass, changes or fail" end) else empty end),
      (if $v | has("when") and (($v.needs // []) | length) == 0 then "node \($n): when needs a needs list" else empty end),
      (if $v | has("access") and ($v.access | IN("read", "write") | not) then "node \($n): access must be read or write" else empty end),
      (if $v | has("retry") then
        ($v.retry | if type != "object" then "node \($n): retry must be a map" else
          (if (.to | IN(names[])) then empty else "node \($n): retry.to must name a node" end),
          (if (.max | type) == "number" and .max >= 1 and .max <= 10 and (.max | floor) == .max then empty else "node \($n): retry needs max, a whole number from 1 to 10" end),
          (if has("on") and (.on | IN("fail", "changes") | not) then "node \($n): retry.on must be fail or changes" else empty end),
          (keys - ["to", "max", "on"] | .[] | "node \($n): retry: unknown key \(.)")
        end)
      else empty end)
    end)),
  (nodes | to_entries | map({k: .key, n: ((.value | objects | .needs | arrays) // [])}) as $e
   | (reduce range(0; $e | length) as $_ ([]; . as $d | (. + [$e[] | select((.k | IN($d[])) | not) | select(all(.n[]; IN($d[]))) | .k]) | unique)) as $placed
   | if ($placed | length) < ($e | length) then "nodes: the needs form a cycle among \([$e[].k] - $placed | join(", "))" else empty end),
  (if has("done") and ((.done | type) != "array") then "done: must be a list" else empty end),
  ((.done // [])[]? | if type == "string" then (if IN("draft-pr", "report", "posted-review") then empty else "done: unknown check \(.)" end)
     elif type == "object" and has("gate") then (if (.gate | IN(names[])) then empty else "done: gate \(.gate) is not a node" end)
     elif type == "object" and has("human") then empty
     else "done: each check is draft-pr, report, posted-review, {gate: node} or {human: question}" end),
  (([$p | .. | strings | scan("\\{([a-z_]+)\\}") | .[0]] | unique - ((($p.inputs // []) | if type == "array" then . else [] end) + ["idea", "gate", "output_path"])) as $missing
   | if ($missing | length) > 0 then "placeholders not declared in inputs: \($missing | join(", "))" else empty end)
] | .[]'

pattern_problems() { # pattern JSON, repo dir
    local json="$1" repo="$2" role out
    out="$(printf '%s' "$json" | jq -r "$PATTERN_JQ" 2>&1)" || { printf 'the pattern could not be read: %s\n' "$out"; return 0; }
    [ -n "$out" ] && printf '%s\n' "$out"
    for role in $(printf '%s' "$json" | jq -r '.nodes // {} | .[] | objects | .agent // empty | strings'); do
        resolve roles "$role" "$repo" >/dev/null || printf 'unknown role: %s (no roles/%s.md in the repository, ~/.config/herdr-graph or the plugin)\n' "$role" "$role"
    done
}
