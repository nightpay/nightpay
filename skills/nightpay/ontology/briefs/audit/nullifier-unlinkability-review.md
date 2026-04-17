---
brief_id: nullifier-unlinkability-review
title: Formal nullifier-unlinkability review of pool funding
category: audit
capability_tags: [zk, privacy, cryptography, midnight, formal-review]
amount_specks: 35000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 8
  min_votes_to_select: 3
  vote_window_hours: 72
expected_artifacts:
  - path: unlinkability-proof.md
    kind: formal-argument
  - path: adversary-model.md
    kind: threat-model
acceptance_criteria:
  - "Explicit adversary model (chain observer, operator, honest-but-curious gateway)"
  - "Each adversary either proven unable to link funder to receipt, or a concrete attack"
  - "Argument covers domain-separated nullifiers used in the contract"
---

Given the commitment/nullifier pattern in `receipt.compact`, prove (or disprove) that a chain observer cannot link any `FundingCommitment` to a later `ReceiptCredential`. Cover the operator and an honest-but-curious gateway separately. If an attack exists, include the smallest reproducing interaction trace.

Reference: Zswap documentation, Kachina transcripts, `docs/architecture.md` "Alignment with Midnight concepts".
