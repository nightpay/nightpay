# Escrow Safety Rule

## Two-Chain Escrow Model

This skill operates across two chains simultaneously:

| Chain | What's Held | Token | Purpose |
|---|---|---|---|
| **Midnight** | Bounty NIGHT + operator fee | NIGHT (shielded) | Privacy layer — contract balance |
| **Cardano** | Masumi escrow | ADA or USDM | Settlement layer — agent payment |

The gateway operator bridges between chains by maintaining liquidity on both sides.

## Contract Security Guarantees (Enforced On-Chain)

| Guarantee | How It's Enforced |
|---|---|
| **One-time init** | `assert initialized == 0` — contract cannot be reinitialized or taken over |
| **Immutable fee rate** | `operatorFeeBps` and `operatorAddress` are write-once — set at init, frozen forever |
| **Fee cap** | `assert feeBps <= 500` — hard 5% cap in-circuit, cannot be exceeded |
| **Fee split on-chain** | `effects.retainInContract(fee)` + `effects.releaseToGateway(net)` — constrained in-circuit, not trust-based |
| **No rounding theft** | `assert fee + netAmount == amount` — every speck accounted for |
| **Operator-only withdrawal** | `assert caller == operatorAddress` — only the init-time address can withdraw fees |
| **No overdraft** | Ledger's `apply()` rejects withdrawals exceeding contract balance |
| **Double-claim prevention** | Nullifier set — each bounty can only be completed once |
| **Underflow guard** | `assert activeCount > 0` before decrement — counter cannot go negative |
| **Domain-separated hashes** | Bounty, receipt, and job hashes use different prefixes — cross-namespace collisions impossible |
| **Zero-value guard** | `assert amount > 0` — no zero-value bounty exploits |

## Fee Safety

- Fee split is **enforced in-circuit** via Midnight's Zswap effects API
- `effects.retainInContract(fee)` — operator cannot take more than `feeBps` basis points
- `effects.releaseToGateway(netAmount)` — agent payment is constrained on-chain
- Fee cap enforced by `assert feeBps <= 500` (max 5%) — immutable after init
- Fee percentage is public state — payers can verify before posting
- Operator can only withdraw to the address set at contract initialization

## Gateway Security Guarantees (Enforced Off-Chain)

| Guarantee | How It's Enforced |
|---|---|
| **Contract address required** | `RECEIPT_CONTRACT_ADDRESS` is a required env var — fails loudly if unset |
| **Operator auth for withdrawals** | `OPERATOR_SECRET_KEY` required — HMAC-signed withdrawal payloads only |
| **No replay on withdraw** | Signature includes timestamp + random nonce — every signature is unique, cannot be replayed |
| **SSRF blocked** | `MASUMI_*_URL` validated at startup — private IPs (RFC-1918, loopback, link-local) rejected |
| **Job ID injection blocked** | Job IDs validated as `[a-zA-Z0-9_-]{1,128}` — no path traversal or shell chars |
| **Rate limiting** | `post-bounty` limited to 1 call per `RATE_LIMIT_SECONDS` — prevents spam and stat inflation |
| **Input validation** | Amount bounds (min + max) and commitment format checked before any network call |
| **Domain-separated hashes** | `nightpay-bounty-v1`, `nightpay-receipt-v1`, `nightpay-job-v1` prefixes |
| **Refund emits on-chain intent** | Refund path generates a `refundHash` for Midnight node, not just a Masumi cancel |
| **Canonical JSON hashing** | `sort_keys=True, separators=(',',':')` prevents hash manipulation via key reordering |
| **Network timeout** | All `curl` calls use `--max-time 30` — no hung connections |

## Contract Capacity Limits (DoS Protection)

| Guarantee | How It's Enforced |
|---|---|
| **Merkle tree overflow blocked** | `assert activeCount < MAX_TREE_ENTRIES` (90% of 2²⁵ = ~30M) — rejects bounties before tree fills |
| **Field overflow blocked** | `assert amount <= MAX_AMOUNT` (2⁵³-1) — `amount × feeBps` stays within safe range |
| **Receipt deduplication** | Nullifier insertion before `receiptTree.insert` — double-completion impossible regardless of proof reuse |

## Board Security Guarantees

| Guarantee | How It's Enforced |
|---|---|
| **Persistent storage** | `~/.nightpay/board.db` — SQLite with WAL, survives reboots, not `/tmp/` |
| **Directory permissions** | `chmod 700` — only the operator user can read/write |
| **No duplicate entries** | `PRIMARY KEY` on commitment — database rejects duplicates atomically |
| **Input validation** | All commitments validated as 64-char hex before board operations |
| **Known status values only** | `remove` only accepts `completed`, `refunded`, `expired` |
| **Search DoS blocked** | `search` prefix validated as `[0-9a-f]{0,64}` — no wildcards, no full-table scans |
| **Integer DoS blocked** | `list` clamps `limit ≤ 200`, `offset ≤ 10,000,000` — no memory exhaustion |

## Network Fees (DUST)

- DUST is non-transferable — generated over time from NIGHT holdings
- DUST is used ONLY for Midnight network fees, never for bounty payments
- Whoever submits the intent pays the DUST fee (payer for postBounty, gateway for complete)
- Use `transaction.feesWithMargin(params, 1.2)` to estimate with 20% safety margin
- DUST generation rate: ~1 week to reach full capacity from a NIGHT UTXO
- 3-hour grace period on DUST timestamps

## Pool Safety Guarantees (Enforced On-Chain)

| Guarantee | How It's Enforced |
|---|---|
| **Exact contribution amounts** | `contributionAmount * maxFunders == fundingGoal` — no rounding dust, every funder pays the same |
| **No double-funding** | Funding record is inserted into nullifier set — same funder + same pool + same nullifier rejected |
| **No double-activation** | `activatePool` nullifies the pool commitment — second call reverts |
| **No double-refund** | `claimRefund` inserts a refund nullifier — same funding record can only be refunded once |
| **Refund only after expiry** | `claimRefund` checks for `hash(DOMAIN_REFUND, poolCommitment)` in nullifier set — only present after `expirePool` |
| **No fee on expired pools** | `claimRefund` returns full contribution amount — fee is only deducted during `activatePool` |
| **Pool funder cap** | `maxFunders <= MAX_POOL_FUNDERS (1000)` — prevents gas griefing on large pools |
| **Activate-or-expire, never both** | `activatePool` and `expirePool` both check `!nullifiers.contains(poolCommitment)` — whichever runs first wins |

## Off-Chain Deadline Trust Model

Compact has no time primitives. Deadlines are enforced by the gateway:

1. Pool creator specifies a deadline (e.g., 72 hours from now)
2. Gateway tracks the deadline off-chain
3. When the deadline passes without the goal being met, gateway calls `expirePool`
4. `expirePool` inserts a refund marker — funders can now call `claimRefund`

**Trust assumption:** The gateway can expire a pool early or refuse to expire it. This is the same trust model as the existing escrow timeout — the gateway is a trusted operator. Funders trust the operator to honour deadlines, same as they trust the operator to relay payments.

**Mitigation:** The gateway address is locked at `initialize()` and the fee rate is public on-chain. A malicious gateway cannot steal funds (only delay expiry), because:
- Funds in a non-expired pool are locked in the contract — nobody can withdraw them
- Activating the pool releases funds to the locked gateway address only
- Expiring the pool lets funders (not the gateway) reclaim their contributions

## Emergency Refund Failsafe (Gateway-Free)

If the gateway disappears or refuses to act, funders are NOT permanently locked out. The `emergencyRefund` circuit bypasses the gateway entirely:

1. A monotonic `txCounter` increments on every state-changing circuit call
2. At `fundPool` time, the current `txCounter` is baked into the funding record hash
3. After `EMERGENCY_TX_THRESHOLD` (500) additional contract interactions have occurred, any funder can call `emergencyRefund` directly — no `expirePool` needed
4. The circuit verifies the funding record exists in the tree, checks the txCounter gap, and returns the full contribution

**Why txCounter and not real time?** Compact has no block height or timestamp primitives. The txCounter is the only on-chain monotonic value we can use. 500 transactions represents days-to-weeks of normal contract usage — long enough for the gateway to act under normal conditions, short enough that funds aren't locked forever.

**Safety invariants:**
- `emergencyRefund` checks `!nullifiers.contains(poolCommitment)` — if the pool was already activated, funds were released to the gateway and cannot be double-claimed
- Same refund nullifier as `claimRefund` — prevents double-refund regardless of which path is used
- No fee charged on emergency refunds

## Timeout Handling

- Every bounty escrow has a configurable timeout (default: 60 minutes)
- If the hired agent does not return a result within the timeout:
  1. Masumi escrow is cancelled on Cardano (funds return to gateway)
  2. Gateway emits a signed NIGHT refund intent for the Midnight contract
  3. No receipt token is minted
  4. Bounty commitment stays in the Merkle tree — nullifier set prevents re-claim

## Refund Conditions

### Pool-level refunds (funding goal not met)

- Gateway marks pool as expired after deadline passes
- Each funder calls `claimRefund` with their funding record and nullifier
- Full contribution returned — no fee charged
- Funder-initiated (most private — funder proves their contribution, contract returns funds)

### Bounty-level refunds (agent fails after pool activated)

Automatic refund triggers:
- Agent returns an error or refuses the job
- Agent is unreachable (Masumi `/status` returns unavailable)
- Job result fails validation (output hash mismatch)
- Escrow timeout exceeded

On refund: the operator fee for that bounty is also returned (fee is only collected on success).

## Amount Limits

- `maxBountySpecks` caps the maximum single bounty (default: 500M specks)
- `minBountySpecks` enforces a minimum (default: 1,000 specks) — rejects dust attacks
- Both limits enforced in gateway before any network call

## Dark Energy Threat Model (Sophisticated Attacker Mitigations)

These are attacks that pass all basic validation but exploit deeper system properties.

| Attack | Vector | Mitigation |
|---|---|---|
| **Gateway address injection** | Caller supplies their own address in tx metadata → all bounty NIGHT routes to them | `gatewayAddress` locked in contract state at `initialize()` — `effects.releaseToAddress(gatewayAddress, net)` uses only the immutable on-chain value |
| **completedCount overflow griefing** | Attacker posts + completes millions of dust bounties → counter wraps → contract corrupted | `assert completedCount < MAX_COMPLETED` in-circuit before every increment |
| **DNS rebinding SSRF** | Attacker controls DNS → startup URL check passes (public IP) → A-record flips to 169.254.169.254 → all curl calls hit cloud metadata | `_ssrf_safe_curl()` re-resolves and re-validates every hostname on every request, not just at startup |
| **Shell word splitting** | `openssl rand` or `sha256sum` output contains whitespace → variable splits into multiple tokens → hash computation silently corrupted | `generate_nonce()` pipes through `tr -d '[:space:]'`; `domain_hash()` uses `printf` instead of `echo -n` and strips whitespace from output |
| **reporter_hash rainbow table** | `sha256(username)` is reversible for low-entropy inputs → reporters de-anonymised | `sha256(REPORTER_PEPPER + ":" + reporter_id)` — server-side pepper makes preimage attacks infeasible |
| **Fake work submission** | Anyone knowing a `job_id` calls `POST /provide_input/<id>` with fabricated results | `job_token = HMAC-SHA256("nightpay-job-token-v1:{job_id}", JOB_TOKEN_SECRET)` — only the agent that called `start_job` holds the token; 401/403 on missing/invalid token |
| **Result-swap after commit** | Agent waits to see funder's expected output, then constructs a matching `work_nonce` to pass reveal check | `work_commit = sha256("nightpay-work-reveal-v1:{work}:{nonce}")` committed at `start_job` before work begins — SHA-256 preimage resistance makes post-hoc matching infeasible |
| **Multisig double-counting** | One approver submits two signatures with different nonces → counted as two votes | `used_keys` set in verifier tracks which key index already matched — each entry in `APPROVER_KEYS` counts at most once regardless of how many valid blobs it signs |
| **Arbitrator keys in M-of-N** | `APPROVER_KEYS` may include community arbitrators; key compromise could approve completion | Same HMAC verification as operator keys; no separate role or endpoint — arbitrators use `approve-multisig`; key custody is per-approver responsibility |
| **Stale approval replay** | Attacker captures a valid M-of-N approval blob and reuses it months later on a different job | Approval payload includes `job_id + output_hash + ts + nonce`; verifier rejects if `age > 86400s`; `job_id` binding makes blobs non-transferable |
| **Clock skew abuse** | Approver pre-signs with a timestamp 25h in the future to extend the 24h expiry window | `age < -300s` check rejects approvals more than 5 minutes in the future |
| **Optimistic double-complete** | `optimistic-sweep` cron and operator manually run `complete` concurrently on same job | Midnight nullifier set is canonical — second `completeAndReceipt` circuit call is rejected on-chain regardless of race condition off-chain |
| **Job status filter injection** | `GET /jobs?status='; DROP TABLE jobs--` sent to MIP-003 server | `KNOWN_STATUSES` whitelist check before any DB query — unknown values return 400, never reach SQLite |
| **Auto-freeze weaponisation** | Attacker creates N cheap reporter IDs → files N reports → any legitimate bounty silently frozen | Rate limit per reporter: max `REPORT_RATE_LIMIT` distinct bounties per `REPORT_WINDOW_HOURS`; freeze counts DISTINCT reporter hashes, not total complaint rows |
| **Atomic write race (Windows)** | Two concurrent freeze events both write `.tmp` then `os.rename()` → second rename raises `FileExistsError` on Windows → report file corrupted | `os.replace()` instead of `os.rename()` — atomic on both POSIX and Windows; tmp file uses `secrets.token_hex(8)` suffix to prevent collision |

## Never Do

- Never release Masumi escrow before the completeAndReceipt circuit succeeds on Midnight
- Never hold funds beyond the timeout period
- Never charge fees on refunded bounties
- Never split a single bounty across multiple agents without explicit requester consent
- Never submit intents without sufficient DUST balance (check with `feesWithMargin`)
- Never run withdraw-fees without OPERATOR_SECRET_KEY set
- Never store the board in /tmp or any world-readable location
- Never accept unvalidated commitment hashes — always check 64-char hex format first
