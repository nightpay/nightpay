# Content Safety Rule

## Principle: Classify-Then-Forget

The gateway sees the plaintext job description **in memory only** — long enough to
classify it, then immediately hashes it. The plaintext is never logged, persisted,
or transmitted. This preserves funder privacy while enforcing safety.

## How Classification Works

Content safety is delegated to the bridge's **private decision layer**
(`POST /decision/content-check`). The bridge evaluates the job description using
internal heuristics that are not exposed publicly, then returns a signed decision
receipt:

```json
{ "safe": false, "category": "violence", "decision_id": "...", "policy_version": "...", "sig": "..." }
```

The gateway acts on the `safe` boolean and logs only the `category`. The plaintext
description is never forwarded — only a hash is sent. The signed receipt is
auditable without revealing the rules used.

If the bridge is unreachable, the gateway proceeds with a warning (fail-open) and
the ZK contract enforces its own invariants as a final gate.

## What is Rejected

Any bounty whose job description matches one or more of these categories:

| Category | Examples |
|---|---|
| **Child sexual abuse material (CSAM)** | Any content sexualizing minors |
| **Violence / assassination** | "Kill", "harm", "attack [person]", physical threats |
| **Weapons of mass destruction** | Biological, chemical, nuclear, radiological |
| **Human trafficking / slavery** | Forced labor, organ harvesting, exploitation |
| **Terrorism / extremism** | Recruitment, planning, financing of terror acts |
| **Non-consensual intimate imagery** | Deepfakes, revenge content, sextortion |
| **Financial fraud** | Money laundering, counterfeiting, sanctions evasion |
| **Critical infrastructure attack** | Power grids, water systems, hospitals, elections |
| **Doxxing / stalking** | Identifying, tracking, or surveilling private individuals |
| **Drug manufacturing** | Synthesis of controlled substances (not research) |

This list is not exhaustive. The bridge may apply additional categories.

## Enforcement Points

Two gates, defense-in-depth:

1. **`post-bounty`** — before commitment hash is created. Rejected bounties never
   produce a commitment and no funds move.
2. **`hire-and-pay`** — before Masumi escrow is created. Catches descriptions that
   were committed outside the gateway (e.g. direct circuit call).

## What Happens on Rejection

- The gateway prints a `REJECTED` status with the matched category
- No commitment is created, no hash is emitted, no funds move
- The plaintext description is **not logged** — only the category name
- Exit code 2 (distinct from validation errors which use exit code 1)

## Community Complaint System

Anyone can report a bounty they believe is harmful:

```bash
# Report a bounty (REPORTER_ID is hashed for privacy-preserving dedup)
REPORTER_ID=alice ./bounty-board.sh report <commitment> <category> [reason]

# View complaints for a specific bounty
./bounty-board.sh reports <commitment>

# View all flagged bounties
./bounty-board.sh reports
```

### Valid Report Categories

`csam`, `violence`, `weapons_of_mass_destruction`, `human_trafficking`,
`terrorism`, `ncii`, `financial_fraud`, `infrastructure_attack`,
`doxxing`, `drug_manufacturing`, `other`

### Auto-Freeze

When a bounty reaches **3 complaints** (configurable via `COMPLAINT_FREEZE_THRESHOLD`):

1. Bounty status changes from `active` to `flagged`
2. Flagged bounties are hidden from `list` (no longer discoverable)
3. The complaint data is exported to `community-reports.json`

### Privacy Guarantees for Reporters

- Reporter identity is **SHA-256 hashed** before storage — only used for dedup
- The `REPORTER_ID` env var is never persisted in the database
- Complaint reasons are stored but the bounty description is not (it was never stored)
- Reporters cannot see other reporters' identities

## Privacy Guarantee

- Job descriptions are **never logged**, even rejected ones
- Only the rejection category name appears in output
- After classification, the plaintext variable is unset in the shell
- Reporter identities are hashed — complaints are pseudonymous
