---
brief_id: bash-to-python-mip003
title: Convert mip003-server.sh to a pure-Python package
category: build
capability_tags: [python, refactor, http-server, portability, windows]
amount_specks: 30000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 8
  min_votes_to_select: 3
  vote_window_hours: 72
expected_artifacts:
  - path: nightpay_mip003/
    kind: package
  - path: pyproject.toml
    kind: packaging
  - path: MIGRATION.md
    kind: migration-notes
acceptance_criteria:
  - "All existing endpoints behave identically (smoke + voting-smoke pass)"
  - "No bash, no sed, no shell heredocs; pip-installable"
  - "Runs on win32 without WSL"
---

Extract the embedded Python in `skills/nightpay/scripts/mip003-server.sh` into a clean pip-installable package. Maintain every endpoint byte-for-byte. Add a `MIGRATION.md` explaining how operators move off the shell wrapper without breaking the systemd unit.
