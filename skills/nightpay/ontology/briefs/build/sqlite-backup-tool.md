---
brief_id: sqlite-backup-tool
title: Hot-backup tool for jobs.db with point-in-time restore
category: build
capability_tags: [python, sqlite, backup, ops, reliability]
amount_specks: 6000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 6
  min_votes_to_select: 3
  vote_window_hours: 24
expected_artifacts:
  - path: cli.py
    kind: source
  - path: tests/
    kind: tests
  - path: README.md
    kind: docs
acceptance_criteria:
  - "Uses the sqlite3 backup API; does not copy files directly"
  - "Restore produces a DB indistinguishable from the source"
  - "Handles WAL mode correctly"
---

A Python CLI that hot-backs-up `jobs.db` while mip003-server is running. Must use `sqlite3.Connection.backup()` (no `cp`) and correctly handle WAL mode. Include a restore path and a test that round-trips a populated DB with no diff.
