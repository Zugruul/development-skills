#!/usr/bin/env bash
# src/merged.sh -- sourced by the scripts one level up; not run by itself.
# Which merged pull request is a lane's own, from the lane and prs.sh's cached list (.prs):
# the recorded one (.pr, else a URL a node points to) and no other; with none recorded, its
# branch's, only while no pull request on the branch is open and only one made after the lane.
# A pull request dismissed for the lane never counts.
# shellcheck disable=SC2016,SC2034

MERGED_JQ='
    def own_urls: if (.pr // "") != "" then [.pr]
        else [.nodes[]?.ref // empty | select(test("^https?://[^ ]+/pull/[0-9]+$"))] end;
    def dismissed_urls: [(.dismissed // [])[] | select(.reason == "pr-merged") | .ref];
    def own_merged($prs):
        . as $l | own_urls as $own | dismissed_urls as $gone
        | if ($own | length) > 0 then
              [$prs[] | select(.state == "MERGED") | select((.url as $u | $own | index($u)) != null and (.url as $u | $gone | index($u)) == null)] | .[0]
          elif ($l.branch // "") == "" then null
          else [$prs[] | select((.headRefName // "") == $l.branch)] as $b
              | if any($b[]; .state == "OPEN") then null
                else [$b[] | select(.state == "MERGED") | select((.url as $u | $gone | index($u)) == null)
                      | select((.createdAt // "") == "" or .createdAt >= ($l.created // ""))] | last end
          end;'
