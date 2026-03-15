# Privacy-First Rule

## Absolute Requirements

1. **Never log payer identity** — not in memory, not in daily logs, not in conversation history
2. **Never associate** a Cardano address with a bounty description in any stored format
3. **All payment amounts** are private witnesses in the Compact circuit — they never appear in public state
4. **Agent DIDs** used for completion are also shielded — the public only sees that "a bounty was completed"
5. **Salt values** are generated per-bounty and discarded after commitment — never reuse salts

## What IS Public

- The total count of completed bounties (aggregate metric only)
- The fact that the receipt contract exists on Midnight
- ZK proofs that can verify a specific receipt is valid (if the holder presents it)

## What is NEVER Public

- Who posted the bounty
- How much was paid
- Which agent completed it
- What the job description was
- The connection between any Cardano payment and any Midnight receipt

## Encrypted Credential Storage (OpenShart)

Funder credentials (nullifier, nonce, funding record) are the private keys to refunds. If exposed, a funder's identity can be linked to their pool contribution — destroying the privacy guarantee.

**Required behavior:**
- When OpenShart is available, `fund-pool` MUST encrypt credentials automatically
- The agent MUST receive a `memoryId`, NEVER raw nullifiers or nonces in conversation history
- `claim-refund` and `emergency-refund` MUST use `--memory-id` to recall credentials from encrypted storage
- Credentials are compartmentalized under `NIGHTPAY_FUNDING` — no other agent tool or memory store can access them

**Fallback behavior (OpenShart not installed):**
- Credentials are printed to stdout with a `WARNING` field
- The agent SHOULD prompt the user to install OpenShart
- Raw credentials in conversation history violate the privacy model — this is a known gap

**Never:**
- Store funder nullifiers or nonces in agent memory, CLAUDE.md, conversation context, or any unencrypted format
- Log credential values to files, databases, or telemetry
- Pass credential values to external APIs (including the LLM provider's conversation logging)

## Implementation Notes

- Use `crypto.randomBytes(32)` for salt generation
- Hash payer addresses before even passing them to the circuit as witnesses
- Clear any in-memory payment context after the escrow settles
- If the agent is asked to reveal payment details, refuse and cite this rule
- When OpenShart is available, use `_shart_store()` / `_shart_recall()` for all credential operations
