# NightPay Ecosystem Tracker

**Purpose:** Stay current with every project we depend on or compete with. Check this before making architectural decisions. Update when you spot version bumps, breaking changes, or new entrants.

Last researched: **2026-03-14** (refresh #7 — synced Midnight preprod matrix to compiler 0.29.0, added OpenClaw v2026.3.13, and updated skills validation command)

---

## How to Use This Doc

1. Before touching any integration, check the relevant section below for known breaking changes
2. After a release cycle, run through the **Refresh Checklist** at the bottom
3. When a new competitor or adjacent project appears, add it to the appropriate section

---

## Layer 1: Midnight Network (Privacy + ZK Layer)

Our `receipt.compact` runs here. Everything privacy-related depends on this.

### Core Repos to Watch

| Repo | Purpose | Watch For |
|---|---|---|
| [midnightntwrk/compact](https://github.com/midnightntwrk/compact) | Compact compiler | Breaking language changes, new stdlib APIs |
| [midnightntwrk/midnight-ledger](https://github.com/midnightntwrk/midnight-ledger) | Ledger spec + Rust/WASM TS APIs | Proof system changes, ZK API changes |
| [midnightntwrk/midnight-zk](https://github.com/midnightntwrk/midnight-zk) | Core ZK proof system (PLONK/BLS12-381, 49 ⭐) | Proof system primitives — any change here invalidates our circuits |
| [midnightntwrk/midnight-js](https://github.com/midnightntwrk/midnight-js) | JS client library | SDK version bumps |
| [midnightntwrk/midnight-sdk](https://github.com/midnightntwrk/midnight-sdk) | Main SDK | New primitives, API changes |
| [midnightntwrk/example-counter](https://github.com/midnightntwrk/example-counter) | Minimal Compact template | Best-practice patterns to adopt |
| [midnightntwrk/example-bboard](https://github.com/midnightntwrk/example-bboard) | Bulletin board with React UI | Bulletin board patterns |
| [midnightntwrk/midnight-improvement-proposals](https://github.com/midnightntwrk/midnight-improvement-proposals) | MIPs | Protocol-level changes affecting our contract |
| [midnightntwrk/midnight-awesome-dapps](https://github.com/midnightntwrk/midnight-awesome-dapps) | Curated dApp showcase (74 ⭐ — most starred in org) | Submit NightPay here for ecosystem visibility; watch for competitor dApps |
| [Olanetsoft/midnight-mcp](https://github.com/Olanetsoft/midnight-mcp) | 29-tool MCP server for Midnight (compile, analyze, deploy Compact via Claude, 19 ⭐) | Complementary to our skill; use when Claude Code needs to touch `receipt.compact` directly |
| [OpenZeppelin/compact-security-detectors-sdk](https://github.com/OpenZeppelin/compact-security-detectors-sdk) | Static analysis / vulnerability scanner for Compact contracts (OpenZeppelin) | **Run on `receipt.compact` before every deployment** — AST-based, CLI, pre-built detectors |

### Current Versions (updated 2026-03-14)

| Component | Version | Notes |
|---|---|---|
| Compact Compiler | 0.29.0 | Inside developer tools package (preprod compatibility matrix) |
| **Compact Developer Tools** | **0.4.0** ⬆️ | Released Jan 21 2026 — `compact fixup --check` mode added |
| Wallet SDK | 1.0.0 | Preprod compatibility matrix |
| Wallet API | 1.0.0 | Preprod compatibility matrix |
| DApp Connector API | 3.0.0 | Chrome-only (Lace), providers exposed under `window.midnight.{walletId}` |
| Midnight.js | 3.1.0 | [midnight-js](https://github.com/midnightntwrk/midnight-js); see [MIDNIGHT_JS_INTEGRATION.md](MIDNIGHT_JS_INTEGRATION.md) for bridge adoption options |
| Midnight Node | 0.20.1 | GitHub release `node-0.20.1` (Feb 3, 2026) |
| Midnight Indexer | 2.1.4 | |
| ledger-v7 | 7.0.1 | Preprod compatibility matrix |
| compact-js | 2.4.0 | Preprod compatibility matrix |
| Proof Server | 4.0.0 | |
| Midnight Lace Wallet | 3.0.0 | |
| VS Code Extension | 0.2.13 | |

> ⚠️ **Action required:** Compact Developer Tools jumped from 0.3.0 → 0.4.0. Run `compact fixup --check` on `receipt.compact` before the next compile pass. The `fixup` subcommand interface changed — use `--check` to preview migrations before applying.

### Known Breaking Changes (History)

- **Compact tools 0.4.0 (Jan 21 2026)**: `fixup` subcommand interface changed — new `--check` mode; run `compact fixup --check` before `compact fixup`
- **ledger 6.2.0-rc.2**: broke `LedgerState::post_block_update`, `StorageBackend::pre_fetch`, `FeePrices` structure
- **ledger 7.0.0-alpha.1**: proof system migration Pluto-Eris → BLS12-381
- **Testnet-02 upgrade (May 12, 2025)**: Full chain reset + contract redeployment required after BLS12-381 migration
- **Feb 2026 known issue**: Browser-based dApps broken on Testnet-02 — Node.js dApps (our path) unaffected
- **Compact language updates**: Type annotations are mandatory on witness/circuit parameters; hexadecimal literals are supported; bytes -> vector casts are available

### Our Contract Compatibility Notes

- `MerkleTree<25>` — confirmed within Impact VM bounds (max depth 32)
- All proof system code must target BLS12-381 (not legacy Pluto-Eris)
- `compact fixup` can auto-migrate syntax between Compact versions — run before manual edits

### Network Status

| Phase | Status | ETA |
|---|---|---|
| Testnet-02 | Live and active | — |
| Hilo (NIGHT token distribution) | Active | Done (Dec 2025) |
| Kukolu (Federated mainnet, IOG + partners) | **Upcoming** | Last week of March 2026 |
| Mohalu (Incentivized testnet, SPO participation) | Planned | Q2 2026 |
| Hua (Cross-chain interop, full Zswap) | Planned | Q3 2026 |

Network naming note: Midnight node docker commonly uses `CHAIN=preview` with
`CFG_PRESET=testnet-02`; in this repo we expose that environment as
`MIDNIGHT_NETWORK=preprod` for app-level config.

**Midnight City Simulation opens Feb 26, 2026** — public-facing privacy simulation; good window to demo NightPay. Smart contract deployments on testnet up 1,617% — developer momentum strong heading into mainnet.

**Compact is now formally "Minokawa"** under LF Decentralized Trust project — docs still use "Compact", code unchanged.

### Key Docs

- Language reference: https://docs.midnight.network/develop/reference/compact/lang-ref
- Compact stdlib: https://docs.midnight.network/develop/reference/compact/compact-std-library/exports
- Ledger ADT (MerkleTree API): https://docs.midnight.network/develop/reference/compact/ledger-adt
- Release notes: https://docs.midnight.network/relnotes/overview
- Zswap paper: https://eprint.iacr.org/2022/1002.pdf
- Midnight MCP (AI-assisted Compact dev): https://docs.midnight.network/blog/midnight-mcp-ai-assisted-development

---

## Layer 2: Masumi Network (Agent Discovery + Escrow Layer)

Our gateway.sh and mip003-server.sh talk to these APIs.

### Core Repos to Watch

| Repo | Purpose | Watch For |
|---|---|---|
| [masumi-network/masumi-payment-service](https://github.com/masumi-network/masumi-payment-service) | Core payment infra (TxPipe-audited) | API version bumps, escrow endpoint changes |
| [masumi-network/masumi-docs](https://github.com/masumi-network/masumi-docs) | Tutorials + reference impls | MIP spec changes, new endpoint documentation |
| [masumi-network/agentic-service-wrapper](https://github.com/masumi-network/agentic-service-wrapper) | Minimal MIP-003-compliant wrapper template | New required endpoints, schema changes |
| [masumi-network/crewai-masumi-quickstart-template](https://github.com/masumi-network/crewai-masumi-quickstart-template) | CrewAI + FastAPI + MIP-003 starter | Integration patterns |
| [masumi-network/masumi-mcp-server](https://github.com/masumi-network/masumi-mcp-server) | MCP bridge: Claude Desktop → Masumi Registry | MCP protocol changes, new capabilities |
| [masumi-network/x402-cardano](https://github.com/masumi-network/x402-cardano) | HTTP 402 payment protocol on Cardano | New payment rails we should support |
| [masumi-network/sokosumi](https://github.com/masumi-network/sokosumi) | Sokosumi marketplace monorepo | Agent marketplace changes affecting discovery |

### MIP-003 Required Endpoints (Current)

Our `mip003-server.sh` must implement all of these:

```
POST /start_job           — initiate a job
GET  /status/<job_id>     — poll status (pending → awaiting_payment → running → completed/failed)
GET  /availability        — health/capacity probe
GET  /input_schema        — JSON schema for valid job inputs
POST /provide_input/<id>  — (some versions) interactive agent jobs
```

### Live API Endpoints

| Service | URL |
|---|---|
| Self-hosted Payment API | `http://localhost:3001/api/v1` |
| Self-hosted Registry API | `http://localhost:3000/api/v1` |
| Central Registry (public) | `http://registry.masumi.network` |
| Explorer (Preprod) | `https://explorer.masumi.network/?network=preprod` |
| API Reference | `https://docs.masumi.network/api-reference` |

### On-Chain Addresses

| Network | Contract | Address |
|---|---|---|
| Mainnet | Payment | `addr1wx7j4kmg2cs7yf92uat3ed4a3u97kr7axxr4avaz0lhwdsq87ujx7` |
| Preprod | Payment | `addr_test1wz7j4kmg2cs7yf92uat3ed4a3u97kr7axxr4avaz0lhwdsqukgwfm` |
| Mainnet | Registry Policy ID | `ad6424e3ce9e47bbd8364984bd731b41de591f1d11f6d7d43d0da9b9` |
| Preprod | Registry Policy ID | `7e8bdaf2b2b919a3a4b94002cafb50086c0c845fe535d07a77ab7f77` |

### Network Traction (Jan–Oct 2025 metrics)

- 16,900+ transactions (mainnet + testnet combined)
- $23,000+ USD mainnet volume
- 5,830+ total users; 2,158 paying (66% free-to-paid)
- 17+ open-source repos, 5,600+ dev commits

### Python SDK

Available on PyPI: `pip install masumi` — MIT, Python ≥ 3.8

### Key Docs

- Install guide: https://docs.masumi.network/documentation/get-started/installation
- API reference: https://docs.masumi.network/api-reference
- MIP-003 spec: https://github.com/masumi-network/masumi-docs/blob/main/technical-documentation/agentic-service-api.md
- Cardano dev portal: https://developers.cardano.org/docs/build/integrate/ai-agents/masumi/
- DeepWiki (auto-generated): https://deepwiki.com/masumi-network/masumi-docs

---

## Layer 3: OpenClaw + ClawHub (Agent Orchestration + Distribution)

Our `SKILL.md` and `openclaw-fragment.json` target this ecosystem.

### Core Repos to Watch

| Repo | Purpose | Watch For |
|---|---|---|
| [openclaw/openclaw](https://github.com/openclaw/openclaw) | Main agent runtime (205K+ stars; moving to foundation Q1 2026) | Skill manifest format changes, new activation mechanisms, foundation governance |
| [openclaw/clawhub](https://github.com/openclaw/clawhub) | Skill directory / registry | Submission requirements, metadata format |
| [openclaw/skills](https://github.com/openclaw/skills) | Archived skill versions | How other payment/blockchain skills are structured |
| [VoltAgent/awesome-openclaw-skills](https://github.com/VoltAgent/awesome-openclaw-skills) | Curated skills list (3,000+) | Where to submit nightpay for discovery |
| [BankrBot/openclaw-skills](https://github.com/BankrBot/openclaw-skills) | Crypto/DeFi skill library | Patterns for DeFi skill integration |
| [CharlesHoskinson/dancesWithClaws](https://github.com/CharlesHoskinson/dancesWithClaws) | Cardano-focused OpenClaw agent (Logan) | Masumi + OpenClaw integration patterns |
| [clawdeckio/clawdeck](https://github.com/clawdeckio/clawdeck) | Mission control dashboard for agents | Agent monitoring UI patterns |

### Current Skill Manifest Format

YAML frontmatter in `SKILL.md`:
```yaml
---
name: my-skill
description: What it does
metadata: {"openclaw":{"requires":{"bins":["curl"],"env":["API_KEY"]},"primaryEnv":"API_KEY"}}
---
```

Runtime config in `openclaw.json` under `skills.entries`:
```json
{
  "skills": {
    "entries": {
      "skill-name": {
        "enabled": true,
        "env": { "TOKEN": "value" },
        "config": {}
      }
    }
  }
}
```

### Governance Note (Feb 14, 2026)

Steinberger (OpenClaw creator) announced joining OpenAI — project moving to an open-source foundation. Governance transition in progress. **Monitor for any breaking changes to skill format or ClawHub submission process.**

### Recent OpenClaw Releases

- **v2026.3.13 (Mar 13, 2026):** latest stable release line (post-ACP hardening cycle)
- **v2026.2.26 (Feb 27, 2026):** External Secrets Management (`audit/configure/apply/reload` workflow); **ACP/Thread-bound agents as first-class runtimes**; agent routing CLI (`bind`/`unbind`/`bindings`); Android device capability additions
- **v2026.2.25 (Feb 26, 2026):** `agents.defaults.heartbeat.directPolicy` replaces heartbeat DM toggle — **DM delivery blocked by default**; gateway WebSocket auth hardening
- **v2026.2.24 (Feb 25, 2026):** Heartbeat delivery blocks DM targets by default; Docker namespace-join blocked by default; routing/session isolation hardening
- **v2026.2.6 (Feb 7, 2026):** Opus 4.6 + GPT-5.3-Codex support; safety scanner for skills; credential redaction; session history caps
- **v2026.1.30:** Download install support; OS filtering via `metadata.openclaw.install` arrays; new `config` field in entries
- **Security:** 230+ malicious skills detected on ClawHub since Jan 27, 2026 (droppers, infostealers). `skills-ref validate` now includes safety scanning — run before submitting to ClawHub

### NightPay ↔ ACP

OpenClaw v2026.2.26 makes ACP (thread-bound agents) a first-class runtime alongside OpenClaw sessions. NightPay skill compatibility now includes `acp` (v0.2.3+). ACP agents can invoke the skill via the same trigger phrases; the `openclaw-fragment.json` env binding pattern is unchanged — ACP runtimes pick it up through the External Secrets workflow.

### Skill Validation

```bash
npx skills-ref validate ./skills/nightpay
```

Run this before any ClawHub submission.

### Distribution Targets

1. `clawhub install nightpay` → [clawhub.com](https://clawhub.com/)
2. `npx nightpay init` → npm registry
3. awesome-openclaw-skills → PR to VoltAgent list
4. [openclaw/skills](https://github.com/openclaw/skills) → mirror submission

---

## Layer 4: Cardano (Settlement + Native Token Layer)

Masumi's smart contracts run here. NIGHT token lives here. ADA is the base settlement currency.

### Core Repos to Watch

| Repo | Purpose | Watch For |
|---|---|---|
| [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) | Core node software (v10.6.2) | Node version bumps, hard fork announcements |
| [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli) | Command-line interface | CLI breaking changes affecting scripts |
| [IntersectMBO/cardano-api](https://github.com/IntersectMBO/cardano-api) | Haskell API for building on Cardano | API changes that flow through Masumi |
| [IntersectMBO/cardano-node-emulator](https://github.com/IntersectMBO/cardano-node-emulator) | Local emulator for dev/testing | Useful for testing payment flows without testnet |
| [input-output-hk/essential-cardano](https://github.com/input-output-hk/essential-cardano) | Curated ecosystem map | New AI/agent projects to watch or integrate |
| [cardano-foundation](https://github.com/cardano-foundation) | Foundation repos (119+) | Governance, standards, ecosystem programs |
| [sidan-lab/cardano-open-bounty](https://github.com/sidan-lab/cardano-open-bounty) | Aiken bounty contracts + Next.js | Closest Cardano-native bounty competitor; zero privacy |

### Current Status

| Item | Status |
|---|---|
| Node version | 10.6.2 (stable) |
| Governance | Intersect MBO (community-governed via Chang hard fork) |
| NIGHT token | Live on mainnet since Dec 4, 2025; redemption until Dec 4, 2026 + 90-day grace |
| Masumi on-chain | 16,900+ transactions, $23K+ mainnet volume |
| NightPay settlement path | ADA/NIGHT via Masumi escrow contracts |

### Key Docs

- Developer Portal: https://developers.cardano.org/
- Masumi on Cardano: https://developers.cardano.org/docs/build/integrate/ai-agents/masumi/
- Essential Cardano list: https://github.com/input-output-hk/essential-cardano/blob/main/essential-cardano-list.md

### NIGHT Token Status

The NIGHT token (Midnight's native token) launched on Cardano mainnet December 4, 2025:
- Redemption period: Dec 10, 2025 → Dec 4, 2026 (+ 90-day grace period ending March 2027)
- Distribution prioritized community claims over VC/private sales
- Midnight mainnet (Kūkolu) launches last week of March 2026
- NIGHT will be used for Midnight network operations; currently tradeable on Cardano DEXs
- NightPay bounties are denominated in NIGHT (specks unit)

---

## Competitors and Adjacent Projects

### Direct Structural Analogues (AI Agent Bounty Boards)

| Project | Chain | Privacy | Multi-Funder | Status | Notes |
|---|---|---|---|---|---|
| **ClawTasks** | Base (EVM) | None | No | **Active beta** | Agent-to-agent bounty marketplace, USDC, 10% stake guarantee, OpenClaw-native |
| **cardano-open-bounty** | **Cardano** | None | No | Active | [sidan-lab/cardano-open-bounty](https://github.com/sidan-lab/cardano-open-bounty) — Aiken contracts + Next.js; closest structural analogue on Cardano itself; zero privacy features |
| **agent-bounty-board** | Base/Ethereum | None | No | Inactive (security issues) | [clawdbotatg/agent-bounty-board](https://github.com/clawdbotatg/agent-bounty-board) — original ERC-8004 reference |
| **BountyBoardFlow** | Linea | None | No | Active | [veithly/BountyBoardFlow](https://github.com/veithly/BountyBoardFlow) |
| **BanklessDAO bounty-board** | Ethereum (planned) | None | No | Active DAO | [BanklessDAO/bounty-board](https://github.com/BanklessDAO/bounty-board) |

**New competitor (Feb 2026): ClawTasks — most important to watch**
- Agent-to-agent bounty marketplace, OpenClaw-native (clawtasks.com)
- USDC on Base L2, 5% platform fee + 1% P2P, **10% agent stake** quality guarantee, 48h auto-approve
- Bounty types: Standard, Metric, Contest · Claim modes: Instant, Proposal, Race, Contest
- Full API: `GET /api/bounties`, `POST /api/bounties`, `/claim`, `/submit`, `/pending`
- Required social: agents must cross-post to Moltbook (m/clawtasks) to be discoverable
- No privacy, no ZK, no Cardano, no multi-funder pooling, no anonymous funding
- **What ClawTasks has that NightPay lacks:** agent staking, Contest/Race modes, leaderboard, referral loop (50% fee share)
- **What NightPay has that ClawTasks lacks:** ZK privacy, anonymous multi-funder pooling, Cardano, ZK receipts, M-of-N multisig approval, in-circuit fee enforcement
- ⚠️ **Watch:** if ClawTasks adds Masumi/Cardano integration, they become a direct existential threat

**ERC-8004 (Trustless Agents standard)**
- Live on mainnet Jan 29, 2026 — co-authored by MetaMask, EF, Google, Coinbase
- On-chain agent identity/reputation registry; payment via x402 HTTP protocol
- No privacy, no Cardano, no multi-funder pooling
- ERC-8004 standard repo: [erc-8004/erc-8004-contracts](https://github.com/erc-8004/erc-8004-contracts)
- **Watch:** if ERC-8004 gains adoption, consider a Masumi ↔ ERC-8004 agent bridge

### AI Agent Payment Protocols

| Protocol | Chain | Notes |
|---|---|---|
| **Masumi (MIP-003)** | Cardano | Our integration layer |
| **Fetch.ai / ASI Alliance** | Cosmos/multi | Dominant EVM alternative; Visa rail + USDC + FET; Agentverse = Sokosumi equivalent |
| **ERC-8004** | Ethereum | Standard for agent identity/reputation on EVM; institutional backing |
| **x402 (Coinbase/HTTP standard)** | Multi-chain | Masumi already integrated via [x402-cardano](https://github.com/masumi-network/x402-cardano); NightPay should add support (Phase 2) |
| **ACP (OpenAI + Stripe)** | Off-chain | Consumer commerce focus; Stripe payment tokens for agents |
| **NIGHT token** | Cardano | Midnight's native token; live on mainnet Dec 2025; NightPay's payment denomination |
| **SingularityNET (AGIX)** | Cardano + Ethereum | AI service marketplace on Cardano; potential agent source for NightPay bounties |

### Established Bounty Platforms (Human-Focused, No Privacy)

| Platform | Notes |
|---|---|
| **Gitcoin** | $4.29M in 2025 OSS rounds; quadratic funding; [github.com/gitcoinco](https://github.com/gitcoinco) |
| **Dework** | Best-in-class DAO bounty UX; 15K Discord members; $1.2M payouts YTD; multi-chain crypto payments |
| **Project Catalyst** | Cardano's primary innovation fund; 11,233 proposals, quadratic-style |

### ZK Bounty / Privacy Patterns

| Project | Notes |
|---|---|
| **Boundless (RISC Zero)** | ZK compute marketplace on Base; reverse Dutch auction for proof generation; potential future infra |
| **zkpoex** | Trustless bug bounties via ZK exploit proofs; same core insight as NightPay receipts |
| **W3F Security Marketplace** | Polkadot RFP for auditor marketplace; structurally analogous on ink! |

### Midnight-Adjacent Projects

| Project | Notes |
|---|---|
| **Midnight Logic (hackathon)** | ZK bridge: private Midnight reasoning → public Masumi commits; **closest potential competitor/collaborator** |
| **midnight-agent-skills** | [UvRoxx/midnight-agent-skills](https://github.com/UvRoxx/midnight-agent-skills) — Compact skill modules for AI agents |
| **LucentLabs** | Private overcollateralized stablecoin on Midnight (hackathon) |
| **Midnight Bank** | Confidential banking + multi-party auth (hackathon) |

---

## Layer 4: Frontend / UI (Planned)

Human-readable bounty board. Reference: `midnightntwrk/example-bboard` (React + TypeScript + Tailwind).

### Architecture Decision (confirmed)

**Phase 1: Read-only board, no wallet required for viewers.**

Reasoning:
- Our bridge (`server.ts`) handles all wallet operations server-side — browser never touches keys or proofs
- Proof generation stays on `localhost:6300` (Docker), never in browser
- Zero friction for funders and observers: no MetaMask, no Lace extension required to *read*
- Agents use `npx nightpay` CLI or MIP-003 API — not browser forms

### What the UI Shows

| Page | Content | Data Source |
|---|---|---|
| `/` — Bounty Feed | Active bounties, status badges (Open/Funded/Completed), reward amounts | SQLite bounty board (`bounty-board.sh`) |
| `/bounty/:id` — Detail | Description (classified, not raw), current funding, timeline | SQLite + bridge `/stats` |
| `/verify` — Receipt Check | Paste receipt hash → call `POST /verifyReceipt` → Valid ✓ / Invalid ✗ | Bridge endpoint |
| `/stats` — Dashboard | Completed count, active count, fee %, network (preprod/mainnet) | Bridge `GET /stats` |

### Tech Stack (planned)

- React + TypeScript (matches example-bboard)
- Tailwind CSS
- Fetch → bridge endpoints (`GET /stats`, `POST /verifyReceipt`)
- No wallet library in Phase 1
- Optional Phase 2: Lace wallet (`window.midnight.{walletId}`) for agent submission history

### DApp Connector Reference (for Phase 2)

```typescript
const laceWallet = Object.values(window.midnight ?? {}).find(
  (wallet) => /lace/i.test(wallet.name ?? wallet.rdns ?? ''),
);
if (!laceWallet) throw new Error('No Lace Midnight provider found');
const connected = await laceWallet.connect('preprod');
const { indexerUri, proverServerUri, substrateNodeUri } = await connected.getConfiguration();
```
- Chrome-only (Feb 2026) — also available in SubWallet, NuFi, Vespr, Gero, Tokeo Pay, Keystone, Yoroi, Begin Wallet
- RxJS Observables for wallet state — `firstValueFrom(wallet.state().pipe(filter(s => s.isSynced)))`

### Competitive Context

| Platform | Wallet required to view | Notes |
|---|---|---|
| Dework | No | Best-in-class read-only browse |
| Gitcoin | No | Filter/search first, wallet only to claim |
| agent-bounty-board | Yes (MetaMask) | EVM-native, no privacy |
| **NightPay (planned)** | **No** | Read-only feed + CLI for agents |

---

## Experiments

Technologies being tracked for potential future integration. Not on the current roadmap — added here to evaluate fit as the ecosystem matures.

| Project | What it does | Relevance to NightPay | Link |
|---|---|---|---|
| **Zama** | FHE (Fully Homomorphic Encryption) toolchain — TFHE-rs, fhEVM, Concrete ML | FHE as a complement or alternative to ZK for confidential computation. fhEVM enables encrypted smart contract state on EVM chains — potential future path for an Ethereum-side bridge where funders stay encrypted without ZK circuits | https://www.zama.org/ |
| **GitNexus** | GitHub bounty + contributor reward platform — repo owners post bounties on issues, contributors claim and get paid | Adjacent bounty board pattern on GitHub infrastructure. No privacy, no multi-funder, no ZK — but shows GitHub-native bounty UX that agents could interact with. Potential future adapter: expose NightPay bounties as GitNexus-style issues for broader contributor reach | https://github.com/abhigyanpatwari/GitNexus |

---

## Ecosystem Refresh Checklist

Run these checks periodically (suggest: before each release, or at minimum monthly).

### Midnight

- [x] **Compact tools 0.4.0 — run `compact fixup --check` on `receipt.compact` before next compile** (added 2026-02-18)
- [ ] Check [compact releases](https://github.com/midnightntwrk/compact/releases) — any new version? Run `compact fixup --check` then `compact fixup` on `receipt.compact`
- [ ] Check [midnight-ledger releases](https://github.com/midnightntwrk/midnight-ledger/releases) — any proof system changes?
- [ ] Check [midnight-zk releases](https://github.com/midnightntwrk/midnight-zk/releases) — BLS12-381 or PLONK primitive changes invalidate our circuits
- [ ] Check [relnotes overview](https://docs.midnight.network/relnotes/overview) — breaking changes?
- [ ] Verify Testnet-02 is still live: https://explorer.masumi.network/?network=preprod (swap to Midnight explorer when available)
- [ ] Check mainnet launch status — target late March 2026; update `midnightNetwork` default in `SKILL.md` when mainnet is live
- [ ] **Run `OpenZeppelin/compact-security-detectors-sdk` against `receipt.compact`** — CLI static analysis before any deployment
- [ ] Check [midnight-awesome-dapps](https://github.com/midnightntwrk/midnight-awesome-dapps) — submit NightPay PR once mainnet is live; watch for new competitor dApps listed there
- [ ] Check [Olanetsoft/midnight-mcp](https://github.com/Olanetsoft/midnight-mcp) — new tools or Compact compiler versions exposed via MCP?
- [ ] Check [sidan-lab/cardano-open-bounty](https://github.com/sidan-lab/cardano-open-bounty) — any new features (privacy, multi-funder) narrowing our gap?

### Masumi

- [ ] Check [masumi-payment-service releases](https://github.com/masumi-network/masumi-payment-service/releases) — API version bump? Update endpoints in `gateway.sh`
- [ ] Check [masumi-docs](https://github.com/masumi-network/masumi-docs) for MIP-003 spec changes — new required endpoints?
- [ ] Verify local Payment API (`localhost:3001/api/v1`) and Registry API (`localhost:3000/api/v1`) still match current spec
- [ ] Check [masumi-mcp-server](https://github.com/masumi-network/masumi-mcp-server) — new capabilities to expose via our MIP-003 server?
- [ ] Check if `x402-cardano` integration is stable — should we add HTTP 402 support to `mip003-server.sh`?
- [ ] Check Sokosumi marketplace — are nightpay-posted bounties discoverable there?

### OpenClaw / ClawHub

- [ ] Check [openclaw/openclaw releases](https://github.com/openclaw/openclaw/releases) — skill manifest format changes?
- [ ] Check governance transition status — is ClawHub still accepting new skill submissions under the foundation?
- [ ] Verify `clawhub install nightpay` still works (after submitting)
- [ ] Check [VoltAgent/awesome-openclaw-skills](https://github.com/VoltAgent/awesome-openclaw-skills) — submit PR to add nightpay if not listed
- [ ] Check [CharlesHoskinson/dancesWithClaws](https://github.com/CharlesHoskinson/dancesWithClaws) — any new Masumi integration patterns?

### Cardano

- [ ] Check [cardano-node releases](https://github.com/IntersectMBO/cardano-node/releases) — any hard fork or breaking node changes?
- [ ] Check [sidan-lab/cardano-open-bounty](https://github.com/sidan-lab/cardano-open-bounty) — any new features (privacy, multi-funder) narrowing our gap?
- [ ] Check NIGHT token status — redemption window, DEX liquidity, Lace wallet support
- [ ] Check [essential-cardano](https://github.com/input-output-hk/essential-cardano) for new AI/agent projects on Cardano
- [ ] Verify Masumi payment contracts still current on Cardano mainnet/preprod

### Competitors

- [ ] Check [clawdbotatg/agent-bounty-board](https://github.com/clawdbotatg/agent-bounty-board) — any new features narrowing the gap?
- [ ] Check ERC-8004 standard progress — institutional adoption? Consider agent bridge
- [ ] Check Midnight Logic hackathon project — gone public? Consider collaboration
- [ ] Check [UvRoxx/midnight-agent-skills](https://github.com/UvRoxx/midnight-agent-skills) — Compact patterns to adopt?
- [ ] Check SingularityNET Cardano activity — potential agent workers for NightPay bounties?

### Threat Intel Feeds (for update-blocklist.sh)

- [ ] Verify [stamparm/maltrail](https://github.com/stamparm/maltrail) feed URL still accessible
- [ ] Check if new threat intel feed sources are worth adding
- [ ] Review community complaint patterns — any new categories emerging?

---

## Quick Reference: What NightPay Does That Nothing Else Does

| Capability | NightPay | Closest Alternative |
|---|---|---|
| ZK-private multi-funder community bounty pooling | ✅ | None |
| Funder-to-bounty link destroyed (not just hidden) | ✅ | None |
| ZK receipt token as portable agent credential | ✅ | ERC-8004 reputation (public, not ZK) |
| Midnight + Masumi + Cardano three-layer stack | ✅ | Midnight Logic (hackathon, not public) |
| OpenClaw skill for bounty posting | ✅ | None (first in category) |
| Runs on Cardano ecosystem entirely | ✅ | SingularityNET (partial Cardano) |

---

### UI / Frontend

- [ ] Scaffold `ui/` directory with React + TypeScript + Tailwind (reference: example-bboard)
- [ ] Wire `GET /stats` and `POST /verifyReceipt` bridge endpoints to read-only board
- [ ] Test with `preprod` bridge in stub mode (works without compiler)
- [ ] Publish static build before Midnight mainnet launch for visibility during Midnight City

---

*Updated: 2026-03-14 (refresh #7). Next review: mainnet launch (~2026-03-24).*
