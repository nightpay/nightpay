---
name: nightpay
description: Anonymous community bounty pools for AI agents — create a pool, crowdfund anonymously via Midnight ZK proofs, hire agents via Masumi, settle on Cardano. Funders contribute equal shares; if the funding goal isn't met, everyone gets a full refund. Trigger with /nightpay <instruction> to create or fund a bounty pool.
license: Apache-2.0
compatibility: "openclaw, acp, claude-code, cursor, copilot"
always: true
allowed-tools: Bash
metadata: {"openclaw":{"requires":{"bins":["bash","curl","openssl","sqlite3","sha256sum"],"env":["MASUMI_API_KEY","OPERATOR_ADDRESS","NIGHTPAY_API_URL","BRIDGE_URL"]},"primaryEnv":"MASUMI_API_KEY","os":["darwin","linux"]},"category":"payments","blockchain":"midnight, cardano","agent-layer":"masumi","version":"0.2.4"}
---

# nightpay

> Anonymous community bounty pools for AI agents — Midnight ZK proofs + Masumi settlement + Cardano finality.


## Install

```bash
npx nightpay init
```

Installs the full skill into `./skills/nightpay/` (SKILL.md, scripts, ontology, rules, contracts). One command, no git clone needed.

## What This Does

This skill turns an OpenClaw agent into a **community bounty pool operator**:

1. **An agent or human creates a bounty pool** — sets a funding goal, fixed contribution amount, and max funders
2. **Funders back the pool anonymously** — shielded NIGHT via Midnight's Zswap (identity destroyed by nullifier model)
3. **If the funding goal is met, the pool activates** — an AI agent is hired via Masumi to do the work
4. **If the goal isn't met by the deadline, funders reclaim their NIGHT** — funder-initiated refund, no fee charged
5. **A ZK receipt proves completion** — shielded token minted on Midnight, verifiable by anyone, reveals nothing about funders
6. **The operator collects an infrastructure fee** — configurable basis points (default 2%) on successful pools only

## Activation

This skill activates when the agent encounters:
- "bounty", "community bounty", "anonymous bounty", "crowdfund"
- "nightpay", "bounty board", "bounty pool", "create a pool"
- "fund this privately", "anonymous tip", "fund pool"
- Any request to create, fund, or manage bounty pools with privacy

## Ledger Compatibility

Built against `midnightntwrk/midnight-ledger` spec:

| Ledger Concept | How Pools Use It |
|---|---|
| **Zswap** (commitment/nullifier) | Funders send shielded NIGHT — identity destroyed by nullifier unlinkability |
| **ContractState.balance** | Contract pools funds + operator fees |
| **Effects.shielded_mints** | Mints a receipt token when bounty is completed |
| **Bounded Merkle trees** (depth 25) | Pool tree, funding tree, bounty tree, receipt tree |
| **Nullifier set** | Prevents double-funding, double-completion, double-refund |
| **DUST** | Network fees only — never deducted from pool funds |

## Pool Parameters

| Parameter | Set By | Enforced | Description |
|---|---|---|---|
| `fundingGoal` | Pool creator | On-chain | Minimum total NIGHT to activate |
| `contributionAmount` | Pool creator | On-chain | Fixed per-funder contribution (equal shares) |
| `maxFunders` | Pool creator | On-chain | Maximum number of backers |
| Deadline | Gateway | Off-chain | Funding window — expired pools become refundable |

## Infrastructure Fee

```
Pool activates with 100 NIGHT total
  +-- 2 NIGHT  -> infrastructure fee (held in contract)
  +-- 98 NIGHT -> released to agent on completion

No fee on expired/refunded pools. Fee rate is public on-chain.
```

## Configuration

```json
{
  "nightpay": {
    "midnightNetwork": "preprod",
    "masumiPaymentUrl": "http://localhost:3001/api/v1",
    "masumiRegistryUrl": "http://localhost:3000/api/v1",
    "receiptContractAddress": null,
    "operatorAddress": "your-night-address-hash",
    "operatorFeeBps": 200,
    "maxBountySpecks": 500000000,
    "escrowTimeoutMinutes": 60,
    "defaultPoolDeadlineHours": 72,
    "minContributionSpecks": 1000
  }
}
```

## Flow

```
Pool Creator                   NightPay Contract              Masumi/Cardano
      |                              |                              |
      |-- createPool --------------->|                              |
      |   (goal, amount, maxFunders) |                              |
      |                              |                              |
Funders (anonymous)                  |                              |
      |-- fundPool (× N) ---------->|                              |
      |   (equal contributions)      |                              |
      |                              |                              |
      |              goal met? ------+                              |
      |              /        \                                     |
      |           yes          no (deadline passed)                 |
      |            |                  \                              |
      |     activatePool         expirePool                         |
      |            |                  |                              |
      |            |           claimRefund (× N)                    |
      |            |           (100% returned)                      |
      |            |                                                |
      |            |-- find agent --------------------------------->|
      |            |-- hire + escrow ------------------------------>|
      |            |                                                |
      |            |<-- agent delivers work ------------------------|
      |            |                                                |
      |            |-- completeAndReceipt ------------------------->|
      |            |   (nullify bounty, mint receipt,               |
      |            |    release funds to agent)                     |
      |            |                                                |
      |<-- ZK receipt (verifiable, reveals nothing) ----------------|
```

## Agent Command Interface

Use `/nightpay <instruction>` to dispatch a bounty pool. The skill will:
1. Create a pool with appropriate parameters
2. Wait for funding (or fund from the agent's own balance)
3. When activated, find and hire an agent via Masumi
4. Return a job_id and job_token for tracking

### Tools available to agents

**create_pool** — Create a new bounty pool.
Required params: `description` (string), `contributionAmountSpecks` (number), `fundingGoalSpecks` (number), `maxFunders` (number)
Returns: `{ poolCommitment, contributionAmount, fundingGoal, maxFunders }`
Bridge endpoint: `POST /createPool`

**fund_pool** — Contribute to an existing pool (exactly contributionAmount NIGHT).
Required params: `poolCommitment` (64-char hex), `funderNullifier` (64-char hex)
Returns: `{ fundingRecord, currentFunding, fundersCount, goalMet }`
Bridge endpoint: `POST /fundPool`

**claim_refund** — Reclaim contribution from an expired pool.
Required params: `poolCommitment` (64-char hex), `funderNullifier` (64-char hex)
Returns: `{ refunded, amountSpecks }`
Bridge endpoint: `POST /claimRefund`

**emergency_refund** — Failsafe: reclaim contribution without the gateway. Use only if the gateway is unresponsive and enough contract interactions have passed (500+ txCounter delta). Does not require `expirePool`.
Required params: `poolCommitment` (64-char hex), `funderNullifier` (64-char hex), `contributionAmountSpecks` (number), `fundedAtTx` (number), `nonce` (64-char hex), `funderAddress` (64-char hex)
Returns: `{ refunded, amountSpecks, emergencyPath: true }`
Bridge endpoint: N/A — submitted directly to Midnight contract (no bridge needed)

**submit_work** — Call this when you have completed the bounty work.
Required params: `jobId` (string), `workOutput` (string, min 100 chars), `bountyCommitment` (64-char hex), `outputHash` (64-char hex)
Optional params: `artifactPaths` (list of file paths)
Returns: `{ receiptHash, txId, payment, feeBps, verifyUrl, stub }`
Bridge endpoint: `POST /submitWork`

**get_job_economics** — Check payment breakdown for a job.
Required params: `jobId` (string)
Returns: `{ amountSpecks, netToAgent, fee, feeBps, status, survivalStatus }`
Bridge endpoint: `GET /jobEconomics/<jobId>`

**verify_receipt** — Verify a ZK receipt is valid on-chain.
Required params: `receiptHash` (64-char hex)
Returns: `{ valid, stub }`
Bridge endpoint: `POST /verifyReceipt`

**upload_artifact** — Store work deliverables (code, reports, proofs) against a job. Max 5 MB per artifact; 5 MB total per job.
Required params: `jobId` (string), `filename` (string)
One of: `content_text` (string) for UTF-8 text, or `content_b64` (string) for binary (base64-encoded)
Optional params: `content_type` (MIME type, default `application/octet-stream`), `description` (string), `uploaded_by` (agent_id)
Returns: `{ artifact_id, job_id, filename, content_type, size_bytes, url, uploaded_at }`
Endpoint: `POST /api/v1/jobs/<job_id>/artifacts`

**list_artifacts** — List all artifacts stored for a job.
Required params: `jobId` (string)
Returns: `{ artifacts: [...], count, total_bytes, remaining_bytes }`
Endpoint: `GET /api/v1/jobs/<job_id>/artifacts`

**get_artifact** — Retrieve artifact content by ID.
Required params: `jobId` (string), `artifactId` (string)
Returns: `{ artifact_id, filename, content_type, size_bytes, content_b64, content_text? }`
Endpoint: `GET /api/v1/jobs/<job_id>/artifacts/<artifact_id>`

### Economics

```
Fee formula:  fee = poolTotal × feeBps / 10000
Net to agent: netToAgent = poolTotal - fee
Default fee:  200 bps (2%)
```

Fee is only charged when a pool activates and the work is completed. Expired pools return 100% to funders.

## Trust Model

Before participating in a nightpay pool, verify trust using on-chain state. Every check below can be performed without trusting the gateway.

### Pre-flight checks (run these before funding or accepting work)

```
1. GET  getStats()
   → Read operatorFeeBps    — is the fee acceptable? (max 500 = 5%)
   → Read poolCount         — is the contract active?
   → Read txCounter         — is the emergency exit viable? (higher = safer)

2. READ gatewayAddress      — does it match the operator you expect?
   READ operatorAddress     — who can withdraw fees?
   READ initialized         — must be 1 (contract is set up)

3. POST verifyReceipt(hash) — pick any past receipt hash, verify it returns true
   → Proves the ZK proof system is working end-to-end

4. GET  /availability       — Masumi endpoint, confirms the operator is online
   GET  /status/<job_id>    — Masumi endpoint, confirms escrow is locked
```

### Trust boundaries

| Layer | What it guarantees | Verifiable by agent? |
|---|---|---|
| **Midnight contract** | Fee cap (≤5%), immutable fee rate, no double-fund/refund, locked gateway address, emergency exit after 500 tx | ✓ On-chain, ZK-proven |
| **Credential memory** | Funder credentials encrypted locally, never in plaintext logs (if supported by environment) | ✓ Local, optional |
| **Masumi escrow** | Agent payment locked in escrow, auto-refund on timeout, registered via Cardano NFT | ✓ Queryable via Masumi API |
| **Cardano settlement** | Payment finality, Midnight proof anchoring | ✓ Public L1 |
| **Gateway operator** | Deadline enforcement, activation trigger, agent selection, relay availability | ⚠ Off-chain trust |

### Gateway trust mitigations

The gateway is the only trusted component. Here's what limits its power:

- **Cannot steal funds** — contract releases only to the address locked at `initialize()`
- **Cannot change fees** — `operatorFeeBps` is write-once, frozen forever
- **Cannot fake receipts** — `completeAndReceipt` requires valid Merkle proof
- **Cannot double-activate** — nullifier set rejects second `activatePool` call
- **Cannot block emergency refund** — `emergencyRefund` bypasses gateway entirely
- **Goes offline** — funders self-rescue via `emergencyRefund` after ~500 contract interactions

### Credential storage

When you call `fund-pool`, the gateway returns credentials needed for refunds. These are **private keys to your money** — if they're exposed, your funding identity is deanonymized.

**With encrypted memory available** (recommended):
- If the gateway environment supports encrypted storage, credentials are automatically encrypted locally.
- The agent receives a `memoryId` instead of raw secrets.
- To refund: `claim-refund --memory-id <memoryId>` — the environment automatically reconstructs credentials.
- Credentials never appear in conversation history, agent logs, or LLM provider telemetry.

**Without encrypted memory** (fallback):
- Credentials are printed to stdout in plaintext.
- The agent must save them somewhere — but they end up in conversation history.
- Any LLM provider logging conversations can see your funderNullifier and nonce.
- **This breaks the privacy model** — secure credential handling is strongly recommended.

```
# fund-pool will auto-detect if the environment supports encrypted storage
./gateway.sh fund-pool <pool_commitment>
# Returns either plaintext credentials, OR: { memoryId: "abc123", credentialStorage: "encrypted" }

# If a memoryId was returned, claim-refund can auto-recall it:
./gateway.sh claim-refund --memory-id abc123
```

### Credential values (for manual storage or emergency refund)

If you need to store credentials manually, these are the values:

```
fundingRecord       — your unique funding proof
funderNullifier     — your private key to the funding record
fundedAtTx          — txCounter at the time you funded (baked into the hash)
nonce               — random nonce from your funding call
contributionAmount  — how much you put in
poolCommitment      — which pool you funded
```

Without these values, `emergencyRefund` cannot recompute your funding record hash and will reject the proof. The gateway does not store them — only you have them.

## Rules

- `privacy-first.md` — never log or expose funder identity
- `escrow-safety.md` — timeout, refund, pool safety, off-chain deadline trust model
- `receipt-format.md` — ZK receipt schema and verification
- `content-safety.md` — classify-then-forget gate rejecting harmful bounties (CSAM, violence, trafficking, etc.)
