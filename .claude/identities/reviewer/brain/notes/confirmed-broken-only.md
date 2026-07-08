---
tags: [review, claims, grep]
paths: ["**"]
strength: 1
source: "#96 retro (listed guard-pr-create as dependent despite observing it pass)"
graduated: false
created: 2026-07-08
---

Never file a dependency/consumer claim from grep alone: (a) substring grep false-positives on shared prefixes (`hookjson` matched `hookjson_pr`) — symbol claims need word-boundary/call-site matches; (b) when driven behavior CONTRADICTS a static inference, the observation wins — confirm each listed consumer by driving it in isolation and seeing it actually fail. Confirmed-broken belongs in the finding; grep-matched-but-passes does not.

Related: [[reports-are-not-the-code]]
