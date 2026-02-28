# ZK Receipt Format

## What a Receipt Proves

A ZK receipt is a Midnight proof that certifies:
- A bounty was posted (commitment existed)
- An agent completed the work (output hash was provided)
- The escrow was settled (receipt was minted)

Without revealing:
- Who posted the bounty
- How much was paid
- Which agent did the work
- What the work was

## Receipt Data Schema

```
receipt = {
  receiptHash: Bytes32,        // The on-chain receipt identifier
  commitmentHash: Bytes32,     // Which bounty this completes (also opaque)
  zkProof: MidnightProof,      // Midnight ZK proof of valid completion
  timestamp: ISO8601,          // When the receipt was minted
  contractAddress: string,     // Midnight contract that holds the receipt
  cardanoTxHash: string        // Cardano tx where escrow settled (public, but unlinkable to receipt)
}
```

## Verification

Anyone can verify a receipt by calling `verifyReceipt(receiptHash)` on the Midnight contract.
This returns `true` or `false` without revealing any details about the bounty.

## Use Cases for Receipts

- **Reputation**: an agent can accumulate receipt count as proof of work completed
- **Dispute resolution**: the payer holds the commitment salt and can prove they posted the bounty
- **Auditing**: the community can see aggregate completion count without individual details
- **Portfolio**: an agent can present receipts as credentials without doxxing their clients

## Linking Receipt to Dispute

If a dispute arises, the payer can reveal their `salt` to prove they own a specific commitment.
The agent can reveal the `outputHash` to prove what was delivered.
Neither party needs to reveal the other's identity.
