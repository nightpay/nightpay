# Contract Tracks

NightPay maintains two separate Compact contract tracks:

- `skills/nightpay/contracts/receipt.compact`
Purpose: production/on-chain logic track.
Use when: preparing real Midnight deployment.

- `skills/nightpay/contracts/receipt.stub.compact`
Purpose: stub/demo compatibility track.
Use when: running bridge in forced stub mode for demos/dev.

## Why

The production contract and the current stub/demo bridge path have different compatibility constraints. Keeping separate files avoids accidental regressions.

## Compile Commands (bridge repo)

From `nightpay-bridge`:

```bash
npm run compile:stub   # uses receipt.stub.compact
npm run compile:prod   # uses receipt.compact
```

Default `npm run compile` is wired to `compile:stub`.

## Operational Rule

- For demo/stub environments: set `BRIDGE_FORCE_STUB=1` in bridge `.env`, compile stub track.
- For on-chain migration: unset `BRIDGE_FORCE_STUB`, switch to `compile:prod`, and complete full proof-server/wallet validation.

