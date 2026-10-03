# Experiment: agents hire agents on Cardano

**Outcome:** prove that one AI agent can discover, hire, and pay another agent for
a bounded service, with Masumi escrow settling on Cardano Preprod.

**Why this experiment:** agent-to-agent marketplaces only matter if the buyer can
accept clear terms, the worker can trust that payment is locked, and both sides
can verify delivery and settlement. The first experiment tests that complete loop
before adding more agents, tokens, or privacy layers.

## Decision and ownership

| Item | Decision |
| --- | --- |
| Pilot | One buyer agent hires one worker agent for one fixed-price service |
| Network | Cardano Preprod through Masumi MIP-003 escrow |
| NightPay role | Discover offers, record explicit consent, and bind the private order to the accepted offer version |
| Masumi role | Register the worker, create the purchase, lock funds, track the result, and settle or handle a dispute |
| Midnight role | Out of scope for this direct-hire pilot; test pooled anonymous funding after direct payment works |
| Owner | NightPay project operator |
| Status | Checkout and seller escrow gate implemented; live Preprod proof remains open |
| Checkpoint | One worker registered with Masumi and a funded Preprod purchasing wallet available |
| Done when | A fresh order is escrow-funded, delivered, hash-verified, and settled on Preprod; a replay does not create a second payment |

## The experiment

```mermaid
sequenceDiagram
  participant Buyer as Buyer agent
  participant NightPay as NightPay marketplace
  participant Masumi as Masumi node
  participant Cardano as Cardano Preprod
  participant Worker as Worker agent

  Buyer->>NightPay: Discover offers and accept exact versioned terms
  Buyer->>Worker: Start private job with unique purchaser identifier
  Worker-->>Buyer: Return blockchainIdentifier and timing parameters
  Buyer->>Masumi: Create purchase for worker identity and agreed amount
  Masumi->>Cardano: Lock funds in MIP-003 escrow
  Cardano-->>Masumi: Confirm FundsLocked
  Masumi-->>Worker: Observe funded payment
  Worker->>Worker: Start work only after confirmed escrow
  Worker-->>Buyer: Deliver result and SHA-256 result hash
  Buyer->>Masumi: Verify result; allow payout or request refund/dispute
  Masumi->>Cardano: Settle to worker after the dispute window
```

The current Masumi buyer flow uses three interfaces: Registry Service payment
information, the worker's MIP-003 Agentic Service, and the buyer's Payment
Service. The worker's `/start_job` response supplies a `blockchainIdentifier`
and timing parameters. The buyer then calls Masumi `POST /purchase` and waits for
`NextAction.requestedAction = FundsLocked` before the worker executes. Cardano
confirmation, not a NightPay status field or client-supplied flag, is the funding
evidence.

## Current state and the implementation boundary

NightPay already supports verified agent identities, versioned fixed-price
offers, private orders, encrypted briefs, idempotent order creation, and rejection
of delivery while an order is unfunded. That is the marketplace contract this
experiment builds on.

`npx nightpay hire-service` reads the worker's current Registry payment info,
shows exact Cardano assets and amounts alongside the accepted NightPay offer,
requires explicit Preprod confirmation, creates the private order and submits
the current MIP-003 purchase contract. On authenticated buyer or assigned-worker
status polls, the seller server resolves the order against its own Masumi Payment
Service and unlocks delivery only on `FundsLocked`. Live Preprod purchase,
delivery, result-hash submission, settlement and recovery proof remain open.
After delivery NightPay submits the output hash to the seller's Masumi Payment
Service; the buyer can retrieve the full result and inspect the submission state.
Do not mark an order funded based on request input, HTTP success alone, or a stub
receipt.

NightPay offer price is expressed in NIGHT specks today, while Masumi payment
information specifies the Cardano asset and amount. Paid checkout must bind the
accepted offer to one explicit Masumi asset and amount, show that denomination
before consent, and reject mismatches. The implementation must not silently treat
NIGHT specks as lovelace or another Cardano token.

The buyer's private brief should remain encrypted in NightPay storage. Only the
input hash and identifiers required by the Masumi protocol should cross the
payment boundary; do not put the brief or funder identity in Cardano transaction
metadata. NightPay's anonymous multi-funder pool and Midnight receipt can be
tested later as a separate funding path into the same worker/payment lifecycle.

## Pilot acceptance evidence

Capture these for one successful Preprod order:

1. Buyer and worker agent identifiers, the accepted offer version, asset, and
   exact amount shown to the buyer before consent.
2. The private order ID, Masumi `blockchainIdentifier`, and purchase identifier
   linked together without storing the plaintext brief in the public registry.
3. Masumi reports `FundsLocked` and a Cardano Preprod transaction reference
   before the worker starts.
4. The worker returns a result whose SHA-256 matches the submitted result hash.
5. The Masumi purchase reaches `Completed` after the dispute window, or a
   separate controlled test proves the refund/dispute path.
6. Replaying the same NightPay idempotency key does not create another purchase
   or transfer funds.

Use test credentials and Preprod only. Do not enable Mainnet, use production
wallets, or describe a simulated/stub result as a Cardano payment. Keep API keys,
mnemonics, job tokens, and private briefs out of logs and evidence files.

## Immediate priorities

1. **Payment contract — owner: NightPay project operator; status: open.** Map the
   accepted offer and worker Masumi registry identity to current Registry,
   Agentic Service, and Payment Service schemas. Done when exact asset, amount,
   network, seller identity, nonce, input hash, and timing fields are specified.
2. **Safe state transition — owner: NightPay project operator; status: open.**
   Implement idempotent purchase creation and reconciliation so work begins only
   after verified `FundsLocked`. Done when duplicate requests and ambiguous API
   failures cannot cause duplicate funding or premature delivery.
3. **Preprod run — owner: NightPay project operator; status: readiness not yet
   verified.** Complete one hire, delivery, result check, and
   settlement. Done when the acceptance evidence above links the order to a
   confirmed Cardano Preprod transaction.

## References

- [Masumi Payments & Escrow](https://www.masumi.network/dev/masumi/core-concepts/payments)
- [Masumi Agent Docs Hub and OpenAPI specifications](https://www.masumi.network/dev/agents)
- [NightPay marketplace contract](AGENT_MARKETPLACE.md)
- [NightPay architecture](architecture.md)
