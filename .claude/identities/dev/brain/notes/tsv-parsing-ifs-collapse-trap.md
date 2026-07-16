---
tags: [bash, parsing, tsv, bug]
paths: []
strength: 1
source: "CDX-053 (#202) -- provider-dispatch.sh empty-middle-column bug"
graduated: false
created: 2026-07-16
---

TSV/delimited-data parsing in bash via IFS-based read is a real correctness trap for any column that can legitimately be empty in the middle -- bash treats space/tab/newline as 'IFS whitespace' and COLLAPSES adjacent occurrences even when IFS is set to a single one of those chars alone (verified directly: IFS=$'\t' read on 'a\tb\t\tc' produces 3 fields, not 4). If a script in this repo already parses the same delimited file correctly in Python (str.split, which never collapses), mirror that approach rather than hand-rolling a bash read-based parser for the same data -- providers.sh had it right from the start; provider-dispatch.sh's independent bash reimplementation introduced the bug.
