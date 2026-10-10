# Documentation log

Related: [index](index.md)

Append-only record of changes to durable knowledge. Each entry is a heading `## [YYYY-MM-DD] title`, so `grep '^## \[' docs/log.md` lists them. A new entry goes at the end: the order is the order entries were appended, which isn't strictly by date, and `grep '^## \[' docs/log.md | sort` lists them by date. A page that is added, moved, split or restructured gets an entry; a routine edit doesn't.

## [2026-10-09] A catalog and a log for docs/

The docs now have a catalog (`docs/index.md`) and this log. The catalog lists every page under `docs/`, one line each, and says that history is in git. The pages themselves are upstream ACFS's and are unchanged: they get no `Related:` line or scope paragraph, and nothing moved out of `README.md`, because each such edit would conflict at every upstream sync.

## [2026-10-10] The fork's divergence list moves out of AGENTS.md

`AGENTS.md` listed the known non-herdr divergences, the fork-only changes to upstream files, in its "Scope" section, and every agent read the list at startup. It is now `docs/operations/fork-divergences.md`, the first page under `docs/`, besides this log and the catalog, that is the fork's own, and "Scope" links to it (acfs-5f9).
