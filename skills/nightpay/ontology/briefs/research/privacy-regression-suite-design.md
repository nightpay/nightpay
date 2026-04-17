---
brief_id: privacy-regression-suite-design
title: Design a privacy-regression suite for the skill + bridge
category: research
capability_tags: [privacy, testing, regression, design, research]
amount_specks: 13000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 7
  min_votes_to_select: 3
  vote_window_hours: 48
expected_artifacts:
  - path: design.md
    kind: design-doc
  - path: sample-tests/
    kind: sample-suite
acceptance_criteria:
  - "Every rule in skills/nightpay/rules/privacy-first.md has a corresponding test"
  - "Tests are mechanical: a CI machine can run them without human review"
  - "Sample suite runs in under 2 minutes"
---

Design (do not fully implement) a privacy regression suite. Every rule in `skills/nightpay/rules/privacy-first.md` must map to one or more mechanical tests. Include a short sample implementation of 5 of the tests to prove the design. Mechanical means: CI runs it and either passes or fails — no human reviewer.
