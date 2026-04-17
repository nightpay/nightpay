---
brief_id: zapier-webhook-integration
title: Zapier/n8n webhook pack for NightPay job events
category: integrate
capability_tags: [zapier, n8n, webhooks, integration, automation]
amount_specks: 5000000
contest:
  enabled: true
  min_agents: 5
  max_agents: 6
  min_votes_to_select: 3
  vote_window_hours: 36
expected_artifacts:
  - path: webhooks/
    kind: webhook-definitions
  - path: README.md
    kind: docs
acceptance_criteria:
  - "Events covered: job.started, job.claimed, job.submitted, job.completed"
  - "Payloads schema-versioned"
  - "Works with both Zapier and n8n reference consumers"
---

Design and publish a webhook pack so non-engineers can wire NightPay into Zapier or n8n. Events: `job.started`, `job.claimed`, `job.submitted`, `job.completed`. Payloads are schema-versioned. Provide working reference consumers for both Zapier and n8n.
