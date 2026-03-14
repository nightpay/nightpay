# Content Safety Rule

## Principle: Classify-Then-Forget

The gateway sees the plaintext job description **in memory only** — long enough to
classify it, then immediately hashes it. The plaintext is never logged, persisted,
or transmitted. This preserves funder privacy while enforcing safety.

## Three-Layer Defense

```
Layer 1: Live rules file         (auto-updated by update-blocklist.sh)
  |
  v  if no rules file exists
Layer 2: Hardcoded fallback      (14 patterns baked into gateway.sh)
  |
  v  if local rules pass
Layer 3: External moderation API (AI-powered classification, optional)
```

Every bounty must pass **all available layers** before a commitment is created.

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

This list is not exhaustive. The live rules file and external API extend coverage.

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

## Auto-Updating Rules (update-blocklist.sh)

The static regex list goes stale. `update-blocklist.sh` keeps it current:

```bash
# Run every 6 hours via cron
0 */6 * * * /path/to/scripts/update-blocklist.sh
```

### Sources

| Source | What It Provides | Update Frequency |
|---|---|---|
| **Base rules** (hardcoded) | 14 core patterns for the 10 categories | Static — code changes only |
| **stamparm/maltrail** | Malicious campaign names, known-bad keywords | Daily (GitHub raw) |
| **Community complaints** | Patterns derived from user reports that hit freeze threshold | Real-time (on flag) |
| **Operator custom rules** | `~/.nightpay/safety/custom-rules.json` | Operator-managed |

### Custom Rules Format

Operators can add domain-specific patterns in `~/.nightpay/safety/custom-rules.json`:

```json
{
  "rules": [
    {"category": "scam", "pattern": "\\b(ponzi|pyramid)\\b.*\\b(scheme|invest)\\b"},
    {"category": "gambling", "pattern": "\\b(casino|betting|slots)\\b"}
  ]
}
```

Invalid regex patterns are skipped with a warning, not fatal.

### Output

Rules are merged, deduplicated, and written atomically to:
```
~/.nightpay/safety/safety-rules.json
```

The gateway hot-loads this file on every `safety_check()` call — no restart required.

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
4. On next `update-blocklist.sh` run, complaint patterns feed back into rules

### Privacy Guarantees for Reporters

- Reporter identity is **SHA-256 hashed** before storage — only used for dedup
- The `REPORTER_ID` env var is never persisted in the database
- Complaint reasons are stored but the bounty description is not (it was never stored)
- Reporters cannot see other reporters' identities

### Feedback Loop

```
User reports bounty → complaint stored in SQLite
  → threshold hit → bounty auto-frozen
  → complaint categories exported to community-reports.json
  → update-blocklist.sh reads community-reports.json
  → trending complaint categories become new regex rules
  → gateway.sh loads updated safety-rules.json
  → future similar bounties blocked at post-bounty gate
```

## External Moderation API (Optional)

Set `CONTENT_SAFETY_URL` to enable AI-powered classification:

```
CONTENT_SAFETY_URL=http://localhost:8080/v1/classify
```

The gateway sends a POST with `{"text": "<job_description>"}` and expects:
```json
{"safe": false, "category": "violence", "confidence": 0.97}
```

If the API is unavailable, layers 1-2 still protect. The API is additive.
The API response is **not logged** — only the boolean decision.

### Recommended External APIs

- **Anthropic content classification** — context-aware, low false positive rate
- **OpenAI moderation endpoint** — free tier available, 11 categories
- **Self-hosted models** — full control, no data leaves your infrastructure

## Privacy Guarantee

- Job descriptions are **never logged**, even rejected ones
- Only the rejection category name appears in output
- The external API call uses `--max-time 5` — no hanging on moderation
- After classification, the plaintext variable is unset in the shell
- Reporter identities are hashed — complaints are pseudonymous

## Configuration

| Env Var | Default | Purpose |
|---|---|---|
| `CONTENT_SAFETY_URL` | (empty) | External moderation API endpoint |
| `SAFETY_RULES_FILE` | `~/.nightpay/safety/safety-rules.json` | Live rules file path |
| `COMPLAINT_FREEZE_THRESHOLD` | `3` | Complaints before auto-freeze |
| `REPORTER_ID` | `anonymous` | Reporter identity (hashed for dedup) |
| `BOARD_HMAC_KEY` | (required) | Board integrity HMAC key |
