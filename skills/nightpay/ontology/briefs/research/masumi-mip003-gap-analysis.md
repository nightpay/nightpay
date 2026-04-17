---
brief_id: masumi-mip003-gap-analysis
title: Gap analysis between NightPay MIP-003 and the spec
category: research
capability_tags: [masumi, mip003, spec, gap-analysis, compliance]
amount_specks: 6000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 6
  min_votes_to_select: 3
  vote_window_hours: 36
expected_artifacts:
  - path: gaps.md
    kind: report
  - path: compliance.csv
    kind: compliance-matrix
acceptance_criteria:
  - "Every MIP-003 required endpoint accounted for"
  - "Each gap classified: blocker, nice-to-have, out-of-scope"
  - "Suggested patches reference specific handler functions"
---

Compare NightPay's `mip003-server.sh` to the Masumi MIP-003 spec. Produce a compliance matrix (endpoint-by-endpoint: present / partial / missing) and a prioritized gap list. Be precise: reference exact handler function names and line numbers.
