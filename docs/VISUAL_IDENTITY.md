# NightPay Visual Identity

**Purpose:** Single reference for brand assets — pixel-art, neon, retro-cyberpunk. Use across UI, docs, and marketing. Update when adding or changing assets.

Last updated: 2026-02-19

---

## Overview

NightPay’s visual identity is **pixel-art + neon**, dark background, with a **gold coin + crescent moon** (pay + night) and **blue–purple gradient** wordmark. It supports:

- **Logo & wordmark** — Header, README, favicon
- **ZK verification badge** — Verify page success state, receipt export
- **Agent figure** — Marketing, agent-facing pages, staking/reputation UI

---

## Assets (Canonical Locations)

| Asset | File | Use |
|-------|------|-----|
| **Logo + wordmark** | `ui/public/assets/logo.png` | Nav, footer, README, social |
| **ZK badge** | `ui/public/assets/zk-badge.png` | Verify page “valid” state, receipt export card |
| **Agent figure** | `ui/public/assets/agent.png` | Post/agent flows, reputation, “how agents work” |

**Style:** Pixel art, neon blue/gold/cyan, scanlines optional. Dark background (#0a0a0f or similar). ZK badge shows golden checkmark + “ZK-HASH: 0x…” truncated hash.

---

## Where They’re Used in the App

| Component | Asset | Notes |
|-----------|--------|------|
| **Nav** | Logo | Replaces emoji + “NightPay” when `logo.png` exists |
| **Verify page** | ZK badge | Shown when receipt is valid; display truncated hash (e.g. `ZK-HASH: 0x{first2}…{last2}`) |
| **Post / agent flows** | Agent (optional) | Future: Lace post form, agent staking, reputation |
| **README / docs** | Logo | Optional: embed or link in README |
| **Receipt export** | ZK badge | Roadmap: “Receipt export / verify page improvements” — badge as shareable credential card |

---

## Roadmap Alignment

These assets support high-value roadmap items:

- **Receipt export / verify page** — ZK badge is the “verified” credential card; improve UX and portability.
- **Agent staking & reputation** — Agent figure for agent-facing screens and trust/slash states.
- **Web post form (Lace)** — Logo and agent in onboarding and success states.
- **Contest / Race modes** — Same palette and pixel style for new flows.
- **Cross-chain (ERC-8004)** — Consistent brand when exposing bounties to EVM agents.

---

## Adding or Replacing Assets

1. Place PNGs in `ui/public/assets/` with the names above (or update this doc and UI references).
   - **Logo/wordmark** → `logo.png`
   - **ZK badge (checkmark + ZK-HASH)** → `zk-badge.png`
   - **Agent figure** → `agent.png`
2. If your assets are in Cursor workspace storage, copy them into `ui/public/assets/` and rename to match.
3. Prefer PNG with transparency for logo and badge; dark BG for agent if needed.
4. Keep pixel-art and neon palette for consistency.
