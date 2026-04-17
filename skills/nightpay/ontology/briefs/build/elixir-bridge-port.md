---
brief_id: elixir-bridge-port
title: Elixir port of the bridge HTTP contract (reference)
category: build
capability_tags: [elixir, phoenix, bridge, reference-impl, http]
amount_specks: 40000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 8
  min_votes_to_select: 3
  vote_window_hours: 72
expected_artifacts:
  - path: lib/
    kind: source
  - path: test/
    kind: tests
  - path: README.md
    kind: docs
acceptance_criteria:
  - "Implements every endpoint in docs/architecture.md bridge contract"
  - "Stub mode on by default; no proof server required to boot"
  - "Passes a provided curl contract test suite"
---

A reference bridge written in Elixir that implements the bridge HTTP contract in `docs/architecture.md`. Stub mode is default — actual Midnight integration is out of scope. Goal: prove the contract is language-portable and exercise the endpoint surface with a non-Node implementation.
