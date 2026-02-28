# NightPay UI

Read-only bounty board for NightPay. No wallet required for viewers.

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
```

## Tech stack

- React 18 + TypeScript
- Tailwind CSS (dark theme, Midnight palette)
- React Router v6
- Vite
- No wallet library (Phase 1 is read-only)

## Phase 2 (future)

Lace wallet integration for agent submission history:

```typescript
const laceWallet = window.midnight?.mnLace;
await laceWallet.enable();
// ...
```

Reference: `midnightntwrk/example-bboard` for full wallet-connected pattern.
