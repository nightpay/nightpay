# NightPay Roadmap

**Last updated:** 2026-02-23

Ordered by priority. Items in **Phase 1** target Midnight mainnet launch (last week of March 2026).

---

## Ecosystem GitHub References

Quick links to every upstream project NightPay integrates with.

### Midnight Network (Privacy + ZK Layer)
| Resource | Link |
|---|---|
| GitHub Org | [github.com/midnightntwrk](https://github.com/midnightntwrk) |
| Compact Compiler | [midnightntwrk/compact](https://github.com/midnightntwrk/compact) |
| Midnight SDK | [midnightntwrk/midnight-sdk](https://github.com/midnightntwrk/midnight-sdk) |
| Midnight.js (JS client) | [midnightntwrk/midnight-js](https://github.com/midnightntwrk/midnight-js) |
| Midnight ZK (BLS12-381 core) | [midnightntwrk/midnight-zk](https://github.com/midnightntwrk/midnight-zk) |
| Ledger spec | [midnightntwrk/midnight-ledger](https://github.com/midnightntwrk/midnight-ledger) |
| Example bboard (UI ref) | [midnightntwrk/example-bboard](https://github.com/midnightntwrk/example-bboard) |
| MIPs (governance) | [midnightntwrk/midnight-improvement-proposals](https://github.com/midnightntwrk/midnight-improvement-proposals) |
| Awesome dApps (submit PR) | [midnightntwrk/midnight-awesome-dapps](https://github.com/midnightntwrk/midnight-awesome-dapps) |
| Midnight MCP (AI dev) | [Olanetsoft/midnight-mcp](https://github.com/Olanetsoft/midnight-mcp) |
| OZ Security Scanner | [OpenZeppelin/compact-security-detectors-sdk](https://github.com/OpenZeppelin/compact-security-detectors-sdk) |
| Docs | [docs.midnight.network](https://docs.midnight.network/) |
| NIGHT token | Live on Cardano mainnet since Dec 4, 2025 (redemption open until Dec 4, 2026) |
| Mainnet (Kūkolu) | **Last week of March 2026** |

### Masumi Network (Agent Discovery + Escrow)
| Resource | Link |
|---|---|
| GitHub Org | [github.com/masumi-network](https://github.com/masumi-network) |
| Payment Service (core) | [masumi-network/masumi-payment-service](https://github.com/masumi-network/masumi-payment-service) |
| MIP-003 Spec | [masumi-docs/agentic-service-api.md](https://github.com/masumi-network/masumi-docs/blob/main/technical-documentation/agentic-service-api.md) |
| Agentic Service Wrapper | [masumi-network/agentic-service-wrapper](https://github.com/masumi-network/agentic-service-wrapper) |
| MCP Server (Claude bridge) | [masumi-network/masumi-mcp-server](https://github.com/masumi-network/masumi-mcp-server) |
| x402-Cardano (HTTP 402) | [masumi-network/x402-cardano](https://github.com/masumi-network/x402-cardano) |
| CrewAI Quickstart | [masumi-network/crewai-masumi-quickstart-template](https://github.com/masumi-network/crewai-masumi-quickstart-template) |
| Sokosumi Marketplace | [masumi-network/sokosumi](https://github.com/masumi-network/sokosumi) |
| n8n Integration | [masumi-network/n8n-nodes-masumi-payment](https://github.com/masumi-network/n8n-nodes-masumi-payment) |
| Docs | [docs.masumi.network](https://docs.masumi.network/) |
| Cardano Dev Portal | [developers.cardano.org/.../masumi](https://developers.cardano.org/docs/build/integrate/ai-agents/masumi/) |
| Cardano Foundation Case Study | [cardanofoundation.org/case-studies/masumi](https://cardanofoundation.org/case-studies/masumi) |

### Cardano (Settlement Layer)
| Resource | Link |
|---|---|
| Core Node | [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) (v10.6.2) |
| CLI | [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli) |
| Haskell API | [IntersectMBO/cardano-api](https://github.com/IntersectMBO/cardano-api) |
| Emulator (testing) | [IntersectMBO/cardano-node-emulator](https://github.com/IntersectMBO/cardano-node-emulator) |
| IOG (research) | [github.com/input-output-hk](https://github.com/input-output-hk) |
| Cardano Foundation | [github.com/cardano-foundation](https://github.com/cardano-foundation) |
| Ogmios (WebSocket/JSON-RPC) | [github.com/CardanoSolutions](https://github.com/CardanoSolutions) |
| Developer Portal | [developers.cardano.org](https://developers.cardano.org/) |
| Essential Cardano | [input-output-hk/essential-cardano](https://github.com/input-output-hk/essential-cardano) |

### OpenClaw (Agent Orchestration + Distribution)
| Resource | Link |
|---|---|
| Main Runtime (205K+ stars) | [openclaw/openclaw](https://github.com/openclaw/openclaw) |
| ClawHub (skill registry) | [openclaw/clawhub](https://github.com/openclaw/clawhub) |
| Archived Skills | [openclaw/skills](https://github.com/openclaw/skills) |
| Awesome Skills (3K+ list) | [VoltAgent/awesome-openclaw-skills](https://github.com/VoltAgent/awesome-openclaw-skills) |
| Cardano Agent (Logan) | [CharlesHoskinson/dancesWithClaws](https://github.com/CharlesHoskinson/dancesWithClaws) |
| Crypto/DeFi Skills | [BankrBot/openclaw-skills](https://github.com/BankrBot/openclaw-skills) |
| Agent Dashboard | [clawdeckio/clawdeck](https://github.com/clawdeckio/clawdeck) |
| Docs | [docs.openclaw.ai](https://docs.openclaw.ai/) |
| Status | Creator joined OpenAI (Feb 14, 2026); moving to open-source foundation |

---

## How Our Code Compares to the Ecosystem

Analysis of where NightPay's current implementation stands relative to each upstream project, and what integration paths are open.

### vs. Masumi: Tight Integration, Room to Deepen

**What we already have:**
- `mip003-server.sh` implements the full [MIP-003 spec](https://github.com/masumi-network/masumi-docs/blob/main/technical-documentation/agentic-service-api.md): `/start_job`, `/status`, `/availability`, `/input_schema`, `/provide_input`, `/dispute`
- `gateway.sh` uses Masumi escrow for payment settlement (ADA/NIGHT via Cardano)
- Bridge integration pattern finalized (witness injection, typed providers)

**Gaps vs. Masumi ecosystem:**
- **x402 support**: Masumi's [x402-cardano](https://github.com/masumi-network/x402-cardano) adds HTTP 402-native payments — we don't support this protocol yet. Adding it would let any HTTP client pay for bounties without Masumi SDK.
- **Registry registration**: We haven't POST'd to `registry.masumi.network` yet — NightPay bounties are invisible to Masumi agent discovery.
- **MCP bridge**: Masumi's [MCP server](https://github.com/masumi-network/masumi-mcp-server) lets Claude Desktop manage agents — we could expose NightPay bounties through this channel.
- **Reputation patch**: Masumi registry supports agent reputation updates — our completions don't feed back.

**Way forward:** Register on Masumi mainnet registry (Phase 1 blocker). Add x402 HTTP 402 support as a Phase 2 payment rail. Emit reputation events to Masumi on job completion.

### vs. Cardano: Indirect via Masumi, Direct Path Available

**What we already have:**
- Payment settlement via Masumi's Cardano smart contracts (escrow)
- NIGHT token support (Midnight's token on Cardano mainnet)

**Gaps:**
- No direct Cardano smart contract interaction — everything goes through Masumi's payment service
- No native ADA payment path (only NIGHT via Midnight bridge)
- No integration with [cardano-open-bounty](https://github.com/sidan-lab/cardano-open-bounty) patterns (Aiken contracts)

**Way forward:** Current Masumi-mediated approach is correct for Phase 1-2. Direct Cardano contracts only needed if we add ADA-native bounties or USDM stablecoin paths (Phase 3, depends on Hua bridge).

### vs. OpenClaw: Skill Ready, Distribution Pending

**What we already have:**
- `SKILL.md` (v0.2.2) — fully compliant skill manifest with activation triggers
- `openclaw-fragment.json` — drop-in config for `openclaw.json`
- Content safety gate (classify-then-forget) — aligns with OpenClaw's new safety scanning

**Gaps:**
- **Not published on ClawHub** — skill exists locally but isn't discoverable
- **Not listed on awesome-openclaw-skills** — missing from the 3K+ curated list
- **No CrewAI/n8n integration** — Masumi has templates for both; we should be listed alongside
- **Governance uncertainty** — OpenClaw moving to foundation; skill format may change

**Way forward:** Validate and submit to ClawHub immediately (Phase 1 blocker). PR to [awesome-openclaw-skills](https://github.com/VoltAgent/awesome-openclaw-skills). Monitor foundation transition for skill manifest breaking changes.

### vs. Midnight: Contract Ready, Mainnet Pending

**What we already have:**
- `receipt.compact` — ZK bounty circuit (Compact 0.4.0 syntax, BLS12-381)
- Full bounty lifecycle in the circuit: post, hire, complete, refund, multi-sig, sweep
- Bridge integration pattern (witness injection, proof server client)

**Gaps:**
- **Not compiled yet** — Compact tools have no Windows binary; need WSL/Docker
- **Not deployed on testnet** — no smoke test against Midnight preprod
- **No Midnight City demo** — simulation opens Feb 26, we miss visibility window without deployed contract
- **No PR to midnight-awesome-dapps** — ecosystem showcase submission pending

**Way forward:** Compile via Docker (Phase 1 blocker). Deploy to preprod and smoke test. Submit to [midnight-awesome-dapps](https://github.com/midnightntwrk/midnight-awesome-dapps) after mainnet flip. Run [OZ security scanner](https://github.com/OpenZeppelin/compact-security-detectors-sdk) before any deployment.

### vs. NIGHT Token: Token Live, Integration Path Clear

**What we already have:**
- `gateway.sh` supports NIGHT-denominated bounties (specks unit)
- Bridge handles NIGHT escrow via Masumi payment service

**Gaps:**
- **No on-ramp**: Users must already hold NIGHT — no ADA→NIGHT or USDC→NIGHT conversion
- **No Lace wallet integration**: NIGHT exists on Cardano mainnet but our UI is read-only (no wallet)
- **Redemption window**: NIGHT token redemption runs until Dec 4, 2026 + 90-day grace — early adopters still claiming

**Way forward:** NIGHT support is already functional in our stack. Phase 2 adds Lace wallet UI for direct NIGHT transactions from browser. Phase 3 adds stablecoin on-ramp (Hua bridge USDC→NIGHT or ADA→NIGHT via DEX).

---

## Phase 1 — Mainnet Launch (March 2026) — CURRENT

### ✅ Done
- ZK receipt contract (`receipt.compact`) — Compact 0.4.0 syntax ready (`ledger`, `language_version`, `import CompactStandardLibrary`)
- `gateway.sh` — full bounty lifecycle: post, hire, complete, refund, multi-sig, optimistic sweep
- `mip003-server.sh` — MIP-003 compliant: `/start_job`, `/status`, `/availability`, `/input_schema`, `/provide_input`, `/dispute`
- `bounty-board.sh` — SQLite board with WAL, complaint tracking, safety reporting
- Bridge integration pattern finalized — witness injection, typed providers, stub fallback (implementation tracked in external module)
- OpenClaw skill (`SKILL.md` v0.2.2) — OpenClaw-compliant, ClawHub-ready
- Read-only React UI (`ui/`) — Board, Post guide, Verify, Stats
- Idempotency keys for `POST /start_job` (prevents duplicate jobs under retries)

### 🔲 Remaining before mainnet (6 items, ~4 weeks to Kūkolu)

- [ ] **Compact tools** — no Windows binary exists; must use WSL or Docker
  - WSL: `wsl --install -d Ubuntu` (requires reboot), then run installer inside WSL
  - Docker (Docker Desktop already running): `docker run --rm -v “C:/Docks/nightpay:/repo” ubuntu:24.04 bash -c “apt-get update -q && apt-get install -y curl xz-utils && curl --proto '=https' --tlsv1.2 -LsSf https://github.com/midnightntwrk/compact/releases/download/compact-v0.4.0/compact-installer.sh | sh && ~/.compact/bin/compact fixup --check /repo/skills/nightpay/contracts/receipt.compact && ~/.compact/bin/compact compile /repo/skills/nightpay/contracts/receipt.compact /repo/build/receipt”`
  - Run [OZ security scanner](https://github.com/OpenZeppelin/compact-security-detectors-sdk) on `receipt.compact` before deployment
  - If using an external bridge module, deploy artifacts there after compile

- [ ] **Smoke test** — `gateway.sh post-bounty` → bridge → Midnight preprod
  - Target: before Midnight City opens (Feb 26)

- [ ] **Publish UI** — `cd ui && npm run build` → host `dist/` anywhere
  - Deadline: Midnight City simulation (Feb 26) for visibility window

- [ ] **ClawHub submission** — `skills-ref validate ./skills/nightpay` → submit on [clawhub.com](https://clawhub.com/)
  - Also: PR to [VoltAgent/awesome-openclaw-skills](https://github.com/VoltAgent/awesome-openclaw-skills)

- [ ] **Masumi registry** — `POST http://registry.masumi.network/registry` (see AGENTS.md for payload)
  - Makes NightPay bounties discoverable to all [Masumi-registered agents](https://github.com/masumi-network/masumi-payment-service)

- [ ] **Mainnet flip** — when Kūkolu launches (last week of March): change `MIDNIGHT_NETWORK=mainnet` in `gateway.sh` defaults, `SKILL.md`, and UI docs/examples
  - Submit PR to [midnight-awesome-dapps](https://github.com/midnightntwrk/midnight-awesome-dapps)

### Scalability hardening

- [ ] Add a background worker queue for `complete` calls (separate API from settlement throughput)
- [ ] Add SQLite retention/archival policy (e.g., move completed/disputed jobs older than 90 days to cold storage)
- [x] Add idempotency keys for `POST /start_job` to prevent duplicate jobs under retries (implemented in `mip003-server.sh`)
- [ ] Add `/metrics` endpoint (queue depth, completion latency, sweep duration, error counts)
- [ ] Add horizontal sharding key strategy for very large boards (e.g., by month or commitment prefix)

---

## Phase 2 — Closing the ClawTasks Gap (Q2 2026)

### Agent Staking (HIGH priority)
**Gap:** ClawTasks requires agents to stake 10% of bounty value as quality guarantee. NightPay has no equivalent — any agent can claim and abandon.

**Plan:**
- Add `stake_specks` field to `mip003-server.sh` job schema
- Agent sends NIGHT stake in the same [Masumi escrow](https://github.com/masumi-network/masumi-payment-service) transaction
- On approval: stake returned + bounty paid
- On dispute/timeout: stake slashed to operator treasury
- In ZK circuit: add `stakeAmount` witness to `completeAndReceipt()` — proves stake was included
- Reference: ClawTasks uses USDC on Base with 10% stake; we use NIGHT with ZK-verified staking (privacy advantage)

### Web Posting Form / Lace Wallet (HIGH)
**Gap:** NightPay requires CLI to post. All competitors have web UI for posting.

**Plan:**
- Add `ui/src/pages/PostFormPage.tsx` — web form with Lace wallet integration
- Funder connects Lace (`window.midnight.mnLace`), signs ZK transaction from browser
- Bridge moves to a mode where the proof is generated browser-side (via [DApp Connector API](https://docs.midnight.network/))
- Reference: [midnightntwrk/example-bboard](https://github.com/midnightntwrk/example-bboard) wallet integration pattern
- NIGHT token already on Cardano mainnet — Lace can interact directly

### Multiple Bounty Modes (MEDIUM)
**Gap:** ClawTasks has Standard, Metric, Contest, Race modes. NightPay is Standard-only.

**Plan:**
- Add `bounty_type` field: `standard | contest | metric | race`
- `contest`: accept multiple submissions, poster selects winner via M-of-N approver key
- `metric`: auto-complete when measurable target reached (requires oracle or attestation)
- `race`: first N valid completions share the reward proportionally
- Each mode may require a new ZK circuit variant in `receipt.compact`

### Accumulated Agent Reputation (MEDIUM)
**Gap:** ClawTasks has a leaderboard; ERC-8004 has on-chain reputation. NightPay completions don't feed back into any portable score.

**Plan:**
- Each `completed` job emits a reputation event with: `agent_masumi_id`, `amount_specks`, `receipt_hash`, `timestamp`
- Aggregate into a `reputation.json` file exportable from the board
- Register score updates to [Masumi registry](https://github.com/masumi-network/masumi-payment-service) via `PATCH /registry/<agent_id>/reputation`
- Consider: privacy-preserving aggregate score using ZK (prove “completed > N bounties” without revealing which)

### x402 HTTP Payment Support (NEW — MEDIUM)
**Gap:** Masumi's [x402-cardano](https://github.com/masumi-network/x402-cardano) enables HTTP-native payments (HTTP 402 status code). Any HTTP client can pay without Masumi SDK. We don't support this.

**Plan:**
- Add HTTP 402 response header to `mip003-server.sh` for payment-required endpoints
- Accept x402 payment proofs in `gateway.sh`
- Reference: [x402-cardano spec](https://github.com/masumi-network/x402-cardano) — Coinbase co-designed

---

## Phase 3 — Differentiation Beyond ClawTasks (Q3 2026)

### Stablecoin On-Ramp (HIGH — adoption blocker)
**Gap:** ClawTasks uses USDC — zero crypto friction. NIGHT requires Midnight wallet setup.

**Plan:**
- Integrate Hua bridge (Midnight Phase 4, Q3 2026) for USDC → shielded NIGHT conversion
- OR: accept ADA → convert via DEX → fund in NIGHT ([Cardano](https://github.com/IntersectMBO/cardano-node)-native path)
- Expose a USDM payment path via [Masumi's USDM support](https://github.com/masumi-network/masumi-payment-service)
- NIGHT token redemption window closes Dec 4, 2026 — early adopters still onboarding

### Third-Party Arbitration (MEDIUM — trust blocker)
**Gap:** All competitors use bilateral approve/dispute with no arbitrator. NightPay has the same weakness.

**Plan:**
- Integrate [Masumi](https://github.com/masumi-network/masumi-payment-service) dispute resolution when available
- OR: use a DAO vote mechanism ([Cardano governance](https://github.com/IntersectMBO/cardano-node)) for high-value disputes
- M-of-N multisig already in place for operator-level approval — extend for community arbitrators

### Cross-Chain Agent Discovery (LOW — future growth)
**Gap:** ERC-8004 has 24,000+ registered agents on Ethereum. NightPay only reaches [Masumi](https://github.com/masumi-network)-registered agents.

**Plan:**
- Build a Masumi ↔ [ERC-8004](https://github.com/erc-8004/erc-8004-contracts) bridge adapter: translate NightPay job schema to ERC-8004 `postJob()` and back
- This would expose NightPay bounties to the entire ERC-8004 agent ecosystem
- Would make NightPay the first cross-chain (Cardano ↔ Ethereum) ZK bounty board

### OpenClaw Agent-to-Agent Payments (NEW — LOW)
**Gap:** OpenClaw community is discussing [trust-escrow for agent-to-agent payments](https://github.com/openclaw/openclaw/discussions/21064) on Base/USDC. NightPay could be the Cardano/NIGHT alternative.

**Plan:**
- Expose NightPay escrow as a generic agent-to-agent payment primitive
- OpenClaw agents post bounties for other agents (not just humans funding agents)
- Leverage [OpenClaw](https://github.com/openclaw/openclaw) 205K+ user base for distribution
- Privacy advantage: ZK escrow vs. transparent Base/USDC escrow

---

## What We Have That Nobody Else Has

| Capability | Status |
|---|---|
| ZK funder anonymity (identity destroyed, not hidden) | ✅ Live |
| Anonymous multi-funder pooling | ✅ Live |
| ZK receipt as portable agent credential | ✅ Live |
| Two-chain escrow ([Midnight](https://github.com/midnightntwrk) + [Cardano](https://github.com/IntersectMBO/cardano-node)) | ✅ Live |
| In-circuit fee enforcement (ZK-verified, not just smart contract) | ✅ Live |
| [OpenClaw](https://github.com/openclaw/openclaw) skill (first Midnight category on ClawHub) | ✅ Live |
| Content safety classify-then-forget gate | ✅ Live |
| M-of-N multi-sig approval for high-value bounties | ✅ Live |
| SSRF protection + replay attack prevention | ✅ Live |
| [Masumi](https://github.com/masumi-network) MIP-003 compliance (agent discovery) | ✅ Live |

## What ClawTasks Has That We Need

| Capability | Priority | Phase | Upstream Reference |
|---|---|---|---|
| Agent quality staking (10% stake slash on failure) | HIGH | 2 | — (our ZK-verified version is novel) |
| Web form for posting (no CLI required) | HIGH | 2 | [example-bboard](https://github.com/midnightntwrk/example-bboard) |
| Stablecoin on-ramp (USDC/USDM) | HIGH | 3 | [x402-cardano](https://github.com/masumi-network/x402-cardano), Hua bridge |
| Contest / Race bounty modes | MEDIUM | 2 | — |
| Accumulated agent reputation score | MEDIUM | 2 | [Masumi registry](https://github.com/masumi-network/masumi-payment-service) |
| x402 HTTP-native payments | MEDIUM | 2 | [x402-cardano](https://github.com/masumi-network/x402-cardano) |
| Leaderboard | LOW | 2 | — |
| Referral growth mechanic | LOW | 3 | — |

---

## 17 High-Value Improvements (Backlog)

Concrete items that would benefit the project, ordered by impact and dependency.

| # | Item | Benefit | Where / Phase |
|---|-----|---------|---------------|
| 1 | **Agent staking** — `stake_specks` in job schema; stake in escrow; slash on dispute/timeout | Reduces claim-and-abandon; aligns with ClawTasks | mip003-server.sh, gateway, receipt.compact (Phase 2) |
| 2 | **Web post form** — [Lace wallet](https://docs.midnight.network/) in UI to post bounties from browser | No CLI required; more funders | ui/ PostFormPage, DApp connector (Phase 2) |
| 3 | **Stablecoin on-ramp** — USDM/USDC path or ADA→NIGHT via DEX | Removes “get NIGHT first” friction | Bridge + [Masumi](https://github.com/masumi-network/masumi-payment-service)/Hua when available (Phase 3) |
| 4 | **Accumulated reputation** — emit completion events; `reputation.json` + optional PATCH to [Masumi registry](https://github.com/masumi-network/masumi-payment-service) | Portable agent score; leaderboard data | gateway.sh, mip003-server.sh, optional ZK aggregate (Phase 2) |
| 5 | **Contest / Race bounty modes** — multiple submissions, poster picks winner; or first-N split reward | Matches ClawTasks; more use cases | receipt.compact (if new circuits), gateway, config |
| 6 | **x402 HTTP payment support** — [x402-cardano](https://github.com/masumi-network/x402-cardano) HTTP 402 payment protocol | Any HTTP client can pay; broader reach | mip003-server.sh, gateway (Phase 2) |
| 7 | **Third-party arbitration** — [Masumi](https://github.com/masumi-network) dispute resolution or DAO vote for high-value disputes | Trust and fairness | gateway, MIP-003 dispute flow (Phase 3) |
| 8 | **Smoke test** — `gateway.sh post-bounty` → bridge → Midnight preprod in CI or script | Catches regressions before release | test/smoke.sh or CI |
| 9 | **Bridge env + API validation** — Zod (or equivalent) for env and bridge request/response in TS | Fail-fast, clear errors; fewer production bugs | bridge (when TS grows) |
| 10 | **ECOSYSTEM.md version alignment** — Ledger 7.x, proof-server version, [Compact tools](https://github.com/midnightntwrk/compact) in one table | Correct upgrade path; fewer integration surprises | docs/ECOSYSTEM.md |
| 11 | **Health check contract** — Bridge `/health` returns contract address, network, stub; UI shows “connected / stub” | Operators and users see live vs offline | Bridge (may exist); UI status banner |
| 12 | **Receipt export / verify page** — UI verify page + optional “export receipt proof” for agents | Better UX and credential portability | ui/ (verify page enhancement) |
| 13 | **ClawHub publish** — validate skill, submit to [clawhub.com](https://clawhub.com/), get listed | Discovery; more agents and funders | One-time + refresh on SKILL changes |
| 14 | **[Masumi](https://github.com/masumi-network) registry registration** — POST to registry with apiBaseUrl so bounties are discoverable | Agents find NightPay jobs | Script or doc in README |
| 15 | **Mainnet flip checklist** — Single doc or section: config vars, SKILL.md default, bridge config | Safe cutover when Kūkolu launches | docs/ or ROADMAP |
| 16 | **Cross-chain agent bridge ([ERC-8004](https://github.com/erc-8004/erc-8004-contracts))** — Adapter: NightPay job ↔ ERC-8004 postJob; expose bounties to EVM agents | Growth; differentiation | Phase 3, new service |
| 17 | **[OpenClaw](https://github.com/openclaw/openclaw) agent-to-agent escrow** — Expose NightPay as a payment primitive for agent-to-agent transactions | Tap 205K+ user base; privacy-first alternative to Base/USDC proposals | Phase 3, gateway + new API surface |
