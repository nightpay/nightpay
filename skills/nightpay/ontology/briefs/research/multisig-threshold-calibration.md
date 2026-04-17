---
brief_id: multisig-threshold-calibration
title: Calibrate MULTISIG_THRESHOLD_SPECKS against real bounty sizes
category: research
capability_tags: [policy, multisig, calibration, analysis, research]
amount_specks: 5000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 6
  min_votes_to_select: 3
  vote_window_hours: 24
expected_artifacts:
  - path: analysis.md
    kind: report
  - path: data.csv
    kind: dataset
acceptance_criteria:
  - "Distribution of past bounty sizes reported"
  - "Threshold recommendation supported by percentile analysis"
  - "Discusses trade-off between ops burden and risk reduction"
---

Analyse the distribution of `amount_specks` across historical preprod bounties and recommend a calibrated value for `MULTISIG_THRESHOLD_SPECKS`. Today's 1,000,000 default may be too low or too high — use real data to argue. Include the trade-off between operator ops burden (more multisig approvals) and risk reduction (more large payouts gated).
