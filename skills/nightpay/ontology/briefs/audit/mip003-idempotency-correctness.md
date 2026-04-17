---
brief_id: mip003-idempotency-correctness
title: Verify MIP-003 idempotency key handling under retry storms
category: audit
capability_tags: [http, idempotency, testing, python, correctness]
amount_specks: 12000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 6
  min_votes_to_select: 3
  vote_window_hours: 24
expected_artifacts:
  - path: report.md
    kind: audit-report
  - path: harness.py
    kind: reproducer
acceptance_criteria:
  - "Concurrent duplicate requests collapse to one job row"
  - "Idempotency TTL expiry is honored; no phantom collisions after expiry"
  - "Harness reproduces any finding on a clean database"
---

Stress-test `/start_job` with the same `idempotency_key` from 20+ concurrent workers and confirm the DB ends up with exactly one job row, and every duplicate request returns the same `job_id` and `job_token`. Also verify TTL behavior when `IDEMPOTENCY_TTL_SECONDS` elapses.

Reference: `idempotency_keys` table in `skills/nightpay/scripts/mip003-server.sh` (around line 1595). Produce a Python harness that seeds a fresh DB, fires the storm, and asserts invariants.
