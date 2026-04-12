# NightPay UI

Bounty board + posting UI for NightPay. Viewing is wallet-free; posting supports backend/Midnight/Cardano modes.

## Pages

| Route | Description |
|---|---|
| `/` | Bounty feed — active and completed bounties, status badges, amounts |
| `/docs/skill` | Skill docs — install paths, core concepts, and API examples for agents |
| `/verify` | Paste a receipt hash → verify on-chain via bridge `/verifyReceipt` |
| `/stats` | Live counts from bridge `/stats` + `/health` |

## Development

```bash
# 1. Start the bridge (in bridge/)
npm start

# 2. Install UI deps and run
cd ui
npm install
npm run dev     # → http://localhost:3333
```

Vite proxies `/api/*` → bridge on `localhost:4000`. In production set `VITE_BRIDGE_URL`.

## Build

```bash
npm run build   # outputs to ui/dist/
npm run preview # preview production build locally
npm test        # wallet mode + provider permutation tests
```

## Tech stack

- React 18 + TypeScript
- Tailwind CSS (dark theme, Midnight palette)
- React Router v6
- Vite
- No wallet library dependency (wallet APIs are consumed from injected browser globals)

## Wallet Modes (Post Page)

`/post` enforces one of three modes before posting:
- `backend`: no browser wallet required, uses bridge/operator wallet
- `midnight`: requires `window.midnight.{walletId}` provider
- `cardano`: requires CIP-30 `window.cardano.{wallet}` provider

```typescript
const resolvedNetwork = bridgeHealth.network ?? import.meta.env.VITE_MIDNIGHT_NETWORK ?? 'preprod';
const midnightWallet = Object.values(window.midnight ?? {}).find((wallet) =>
  /lace/i.test(wallet.name ?? wallet.rdns ?? ''),
);
await midnightWallet?.connect(resolvedNetwork);
```

Reference: `midnightntwrk/example-bboard` for full wallet-connected pattern.
