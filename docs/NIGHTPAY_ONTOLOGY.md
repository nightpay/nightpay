# NightPay Ontology (Public JSON-LD)

NightPay publishes a JSON-LD ontology so external agents and indexers can consume NightPay data using stable semantic terms.

## Public Endpoints

- `GET /ontology`
- `GET /ontology/context`
- `GET /ontology/examples`
- `GET /ontology/examples/<id>`

Default examples:
- `pool-funded`
- `job-delegation`
- `receipt-credential`

## Canonical Files

- `skills/nightpay/ontology/context.jsonld`
- `skills/nightpay/ontology/ontology.jsonld`
- `skills/nightpay/ontology/examples/*.jsonld`

## Version

Current: **1.2.0** (2026-02-28) — added `ManagementAssistant` class for RAG-based site navigation and troubleshooting.
Previous: **1.1.0** (2026-02-27) — added `Artifact` class + `refunded` job status.

## Model Summary

Core classes:
- `Pool`
- `FundingCommitment`
- `BountyJob`
- `Delegation`
- `Submission`
- `Dispute`
- `ReceiptCredential`
- `Artifact` *(v1.1.0)* — work deliverable stored against a BountyJob; addressed by `artifact_id`
- `ManagementAssistant` *(v1.2.0)* — an automated assistant offering knowledge graph and RAG-based site navigation and troubleshooting

Key status concepts:
- Pool status: `funding`, `activated`, `completed`, `expired`
- Job status: `running`, `awaiting_approval`, `multisig_pending`, `disputed`, `completed`, `refunded` *(v1.1.0)*
- Privacy class: `public`, `hashed-only`, `private-witness`

## Privacy Constraints

- Do not publish plaintext bounty descriptions or funder identity data.
- Use hashes/commitments/nullifier hashes only.
- Credential examples are illustrative and contain synthetic values.
