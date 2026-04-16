# NightPay Architecture

**Purpose:** Single place for system components, data flow, and where external frameworks (e.g. Midnight.js) fit. Update when making integration or structural changes.

**Public repo:** This repo is public. What must stay private (and never be committed) is defined in `.gitignore`; the rationale for each category is in the section **"Public vs private (what goes in .gitignore)"** below.

Last updated: 2026-04-16 (skill distribution single-source-of-truth added)

---

## VPS / Hetzner (canonical layout)

**Goal:** one production NightPay stack per machine so ports and systemd units do not fight each other.

| Path / unit | Role |
|-------------|------|
| `/opt/nightpay` | Public repo sync target; MIP-003 + gateway skill tree |
| `/opt/nightpay-bridge` | Private bridge checkout; **`ExecStart=/usr/bin/node dist/server.js`** (not `npm run dev` / `tsx`) |
| `/opt/nightpay/.agent-playground.env` | MIP-003 env for production; set **`ENABLE_UI=0`** when Caddy serves `ui/dist` so `server-sync-start.sh` / `agent-playground-setup.sh start` does not spawn a redundant Vite on **3333**. |
| `/opt/nightpay-bridge/.env` | Bridge env (`WALLET_SEED`, contract, proof server URL, etc.) |
| `nightpay-mip003.service` | `mip003-server.sh` on **8090** |
| `nightpay-ui.service` | **Optional / off on canonical VPS:** UI is **`npm run build`** output in `ui/dist` served by **Caddy** (`try_files` + `file_server`). Disable this unit when Caddy serves static files so **3333** stays free. |
| `nightpay-bridge.service` | Bridge on **4000**; **`Restart=on-failure`** and sane `RestartSec` to avoid CPU storms on misconfig |
| Host **`caddy.service`** | **Single TLS entrypoint** on **80/443** for every public hostname on the box (see multisite table below). |

**Avoid:** a second copy under `/opt/nightpay-staging` (or any second tree) listening on **8091/3334** unless you intentionally run staging and accept extra RAM/CPU. **Never** run two bridge processes on **4000** (systemd + manual `node dist/server.js` + `tsx`).

**Docker:** Do not run a second Caddy container bound to **80/443** if the host already runs Caddy (port bind fight + restart loops).

**Caddy read path for `ui/dist`:** Caddy runs as its own OS user (`caddy:caddy`), so `/opt/nightpay` **must** be mode `drwx---r-x` (or wider) and every directory on the path to `ui/dist/` must be world-executable for Caddy to traverse. `bin/deploy-hetzner-ci.sh` applies `chmod o+rx /opt/nightpay` and `chmod -R o+rX ui/dist/` automatically after each build; the public deploy gate validates by checking `https://nightpay.dev/` and `https://board.nightpay.dev/` both return **200**. If the gate ever fails with `403` here, see `docs/ADJUSTMENT_DEPLOY_CHECKLIST.md` §7.1 for the one-line diagnostic and fix.

Details for your operator machine belong in the private runbook `docs/HETZNER_X86_RUNBOOK.md` (gitignored).

### One Caddy, many sites (host-based routing)

**Capisce:** you run **exactly one** Caddy process (`systemd` unit `caddy.service`). It listens on **80** and **443** once. Each **site block** in `/etc/caddy/Caddyfile` lists one or more hostnames; Caddy matches **SNI** (HTTPS) or **Host** (HTTP→HTTPS redirect), then applies that block’s handlers (`reverse_proxy`, `file_server`, `handle_path`, etc.). Backends stay on **localhost** (or Docker-published ports on the host); nothing else binds **443**.

| Public hostname(s) | What users get | Typical backend (loopback) |
|--------------------|----------------|----------------------------|
| **nightpay.dev**, **www.nightpay.dev**, **board.nightpay.dev** | NightPay SPA + same-origin **`/api`**, **`/mip`**, **`/ontology`** | Static **`/opt/nightpay/ui/dist`**; **4000** (bridge); **8090** (MIP) |
| **ceo.nightpay.dev** | Same app build, CEO landing route (client uses hostname) | Same as row above |
| **api.nightpay.dev** | MIP-003 API only | **8090** |
| **bridge.nightpay.dev** | Bridge HTTP API only | **4000** |
| **procureai.tech**, **www.procureai.tech** | ProcureAI site | **127.0.0.1:5178** (or whatever that stack uses) |
| **aiprocurement.club**, **www.aiprocurement.club**, **aiprocurement.ai**, **www.aiprocurement.ai** (one Caddy block) | Next.js app | **127.0.0.1:3008** (Docker); DNS for all four should point at the same host IP (e.g. **89.167.94.187**) |
| **taskzilla.ai**, **www.taskzilla.ai** | Static/Taskzilla routes + optional path proxies | **`/var/www/taskzilla`** + relays as configured in Caddyfile |

Optional raw-hostname blocks (e.g. Hetzner reverse DNS) can mirror **board** behavior for testing without extra domains.

Add a new product on this VPS: **do not** start a second Caddy. Add another **`{ ... }`** site block (or comma-separated hostnames) and point `reverse_proxy` / `root` at the new service’s port or directory, then **`caddy validate`** and **`systemctl reload caddy`**.

---

## How the App Works (In General)

1. **Community** wants to fund a bounty anonymously. They (or an agent) run `gateway.sh post-bounty` or use the skill; the **gateway** computes a commitment (job hash + amount + nonce) and calls the **bridge** `POST /postBounty`. The bridge uses the operator wallet and **proof server** to create a ZK proof, then submits to **Midnight** so the bounty commitment is stored on-chain (Merkle tree). Who funded it is never recorded.

2. **Gateway** finds an agent via **Masumi** (registry + payment API), hires them, and locks payment in **Cardano** escrow. The agent gets a job_id and can call the bridge’s **submit_work** flow when done.

3. **On completion**, the gateway gets the work output from Masumi, hashes it, and calls the bridge `POST /completeAndReceipt`. The bridge runs the ZK circuit: nullifies the bounty (no double-claim), mints a **receipt token** on Midnight, and releases NIGHT so the bridge can settle with Masumi. Masumi pays the agent on Cardano.

4. **Anyone** can verify a completion by calling the bridge `POST /verifyReceipt` with the receipt hash — no need to know who funded or what the job was. The **UI** shows a read-only bounty feed and a verify page; the **MIP-003 server** lets agents discover and run jobs. **OpenClaw** agents use the skill (e.g. `/nightpay post a bounty`) and talk to the gateway/bridge.

**In one line:** Anonymous funders → Midnight (commitment) → Masumi (agent + escrow) → completion → ZK receipt + Cardano payout; bridge is the only thing that talks to Midnight and the proof server.

---

## Concepts in Plain English

- **Bridge** — A small server (TypeScript) that is the *only* part of NightPay that talks to the Midnight blockchain. It holds the operator’s wallet, calls the proof server to create ZK proofs, and submits transactions. The gateway and UI never touch the chain directly; they call the bridge over HTTP.
- **Proof server** — A separate service (often running in Docker on `localhost:6300`) that generates zero-knowledge proofs. The bridge sends it “here are the inputs for this circuit” and gets back a proof that the chain can verify without seeing the private data.
- **Stub mode** — When the proof server or the chain is down, the bridge can still answer HTTP requests. It returns the same JSON shape but with `stub: true` and no real transaction ID. Callers (gateway, UI) can show “offline” or “simulated” instead of failing hard.
- **Gateway** — A shell script that runs the bounty lifecycle: post bounty, hire agent, complete job, refund. It calls Masumi for payments and the bridge when it needs something to happen on Midnight.
- **Compact / receipt.compact** — The smart contract language and our contract file. It defines the circuits (e.g. `postBounty`, `completeAndReceipt`, `verifyReceipt`) that run on Midnight. The bridge runs the JavaScript that was compiled from this contract.

---

## Alignment with Midnight concepts

NightPay’s design follows the [Midnight concepts](https://docs.midnight.network/concepts) model. This section maps our components to the official terminology so code and docs stay aligned.

| Midnight concept | What it means | How NightPay uses it |
|------------------|---------------|----------------------|
| **Accounts** | Who participates: keys, addresses, authorization. | Operator address (and gateway address) are set at init; funders and agents are not identified on-chain. |
| **Ledgers** | Where state lives: **public ledger** (visible data) and **private ledger** (shielded data). | Our contract keeps public counters and config on the public ledger; bounty/receipt/pool/funding trees and nullifier set are **secret ledger** state (shielded). |
| **UTXO model** | Discrete coins; spend = consume inputs, create outputs; **nullifier set** prevents double-spend. | NIGHT flows via Zswap; we use the **commitment/nullifier pattern** (Merkle trees + nullifier set) for bounties, pools, and receipts—same idea as [Zswap](https://docs.midnight.network/concepts/how-midnight-works/zswap). |
| **Zero-knowledge proofs** | Prove correctness without revealing sensitive data (ZK Snarks). | Proof server produces proofs for our circuits; verification uses the circuit’s verifier key (entry point). |
| **Kachina** | Private state (user/local) + public state (chain); ZK links them; **transcripts** encode effects. | Witnesses (jobHash, amounts, nonces, Merkle paths) are private inputs; public transcript updates contract state; bridge builds witnesses from requests. |
| **Compact contracts** | **Entry points** = circuits = verifier keys; contract **state** = ledger state; value via receive/send. | `postBounty`, `completeAndReceipt`, `verifyReceipt`, etc. are entry points; we use `effects.retainInContract` / `releaseToAddress` for value. |
| **Keeping data private** | Hashes/commitments on public ledger; Merkle trees for membership without revealing which item; domain-separated nullifiers. | We store only commitments in trees; nullifiers are domain-separated; no plaintext funder or job data on-chain. |

References: [Concepts overview](https://docs.midnight.network/concepts), [Ledgers](https://docs.midnight.network/concepts/ledgers), [UTXO model](https://docs.midnight.network/concepts/utxo), [ZK proofs](https://docs.midnight.network/concepts/zero-knowledge-proofs), [Kachina](https://docs.midnight.network/concepts/kachina), [Building blocks](https://docs.midnight.network/concepts/how-midnight-works/building-blocks), [Smart contracts](https://docs.midnight.network/concepts/how-midnight-works/smart-contracts), [Keeping data private](https://docs.midnight.network/concepts/how-midnight-works/keeping-data-private).

---

## Public vs private (what goes in .gitignore)

**Principle:** The public repo contains everything needed to use, integrate, and extend NightPay (skill, gateway, contract, UI, docs). Anything that would expose operator/funder secrets, internal plans, or machine-specific credentials stays out — it is listed in `.gitignore` and must never be committed.

**Canonical list:** `.gitignore` is the single source of truth for what is ignored. The table below documents the *reason* for each category so we can decide consistently when adding new paths.

| Category | Paths / patterns | Why private |
|----------|------------------|-------------|
| **Bridge & wallet** | `bridge/` | Private git submodule pointer to a separate private repo; operator wallet and bridge implementation stay there. Public repo defines the bridge HTTP API contract (this doc). |
| **Internal planning** | `plans/`, `LAUNCH.md`, `docs/MARKETING.md` | Roadmap, launch kit, marketing drafts; for maintainers. (AGENTS.md is **public** so agent coding instructions apply in every clone.) |
| **IDE & local config** | `.cursor/`, `.claude/`, `.claude/settings.local.json`, `.claude_settings.json`, `.auto-claude/`, `.worktrees/`, `.security-key`, `logs/security/`, `.playwright-mcp` | May contain hostnames, API keys, local paths; machine-specific. |
| **Local automation** | `.private/`, `scripts/*` (except allowlisted) | Custom deploy/ops scripts and secrets; only `agent-playground-setup.sh`, `server-sync-start.sh`, `load-sim.sh` are shared. |
| **Agent playground** | `.agent-playground/`, `.agent-playground.env`, `.agent-playground.env.bak*`, `.agent-playground.env.local`, `sample-agent/.env`, `sample-agent/.state/` | Runtime secrets (JOB_TOKEN_SECRET, OPERATOR_SECRET_KEY, MASUMI_API_KEY, etc.); template `.agent-playground.env.example` stays tracked. |
| **Credentials & keys** | `.env`, `.env.*`, `*.pem`, `*.p12`, `*.pk8`, `hetzner_*`, `id_rsa`, `id_ed25519`, `credentials*.json`, `secrets.json` | Env vars and key material must never be committed. |
| **VPS / deployment** | `docs/HETZNER_X86_RUNBOOK.md` | Contains deployment details and host references; operator-only. |
| **Operator session** | `docs/OPERATOR_SESSION.md` | Admin-only full visibility (token generation via SSH, sessionStorage, no UI); do not commit. |
| **Test suites** | `test/smoke.sh`, `test/chaos_stress_suite.py` | May reference internal endpoints or test credentials; keep private unless sanitized for public CI. |
| **Runtime artifacts** | `runtime/`, `state/`, `logs/`, `pids/`, `*.sqlite*`, `*.pid` | Server/process state and DBs; not part of source. |
| **Build & temp** | `ui/dist/`, `ui/node_modules/`, `node_modules/`, `.tmp/`, `masumi-services-dev-quickstart` | Build output, dependencies, and local clones. |

**Before adding a new path:** If it contains hostnames, API keys, wallet/operator secrets, or internal runbooks, add it to `.gitignore` and to this table. If in doubt, keep it private.

### Scripts and docs audit (what goes to GitHub)

**Scripts:** Only these are **public** (tracked); all other scripts under `scripts/` are gitignored.

| Path | Status | Notes |
|------|--------|--------|
| `scripts/agent-playground-setup.sh` | **PUBLIC** | Allowlisted; bootstrap init/start/stop/doctor/ops-token. |
| `scripts/server-sync-start.sh` | **PUBLIC** | Allowlisted. |
| `scripts/load-sim.sh` | **PUBLIC** | Allowlisted. |
| `scripts/server-sync-start.ps1` | **PRIVATE** | Under `/scripts/*`; not allowlisted. |
| `scripts/swarm-nightpay-dev.sh` | **PRIVATE** | Under `/scripts/*`; not allowlisted. |
| `skills/nightpay/scripts/gateway.sh` | **PUBLIC** | Not under `/scripts/`; core bounty lifecycle. |
| `skills/nightpay/scripts/mip003-server.sh` | **PUBLIC** | MIP-003 HTTP server. |
| `skills/nightpay/scripts/update-blocklist.sh` | **PUBLIC** | Skill script. |
| `skills/nightpay/scripts/bounty-board.sh` | **PUBLIC** | Skill script. |
| `sample-agent/agent.sh` | **PUBLIC** | Sample agent; `sample-agent/.env` and `.state/` are gitignored. |
| `test/smoke.sh` | **PRIVATE** | Gitignored; may use test credentials. |
| `test/chaos_stress_suite.py` | **PRIVATE** | Gitignored. |

**Key docs:**

| Path | Status | Notes |
|------|--------|--------|
| `docs/AGENT_PLAYGROUND.md` | **PUBLIC** | Full agent/operator runbook (init, env, doctor, API ref). No secret values; points to private `OPERATOR_SESSION.md` for admin token flow. Safe for GitHub so contributors can run the stack. |
| `docs/architecture.md` | **PUBLIC** | Component and public-vs-private reference. |
| `docs/OPERATOR_SESSION.md` | **PRIVATE** | Gitignored; admin-only token and sessionStorage flow. |
| `docs/HETZNER_X86_RUNBOOK.md` | **PRIVATE** | Gitignored; VPS/deploy details. |
| Other `docs/*.md` | **PUBLIC** | Unless listed above or in .gitignore. |

**Agent playground (summary):** The *runbook* `docs/AGENT_PLAYGROUND.md` and the *script* `scripts/agent-playground-setup.sh` are **public** so that anyone who clones the repo can bootstrap and run. The *runtime* (`.agent-playground/`, `.agent-playground.env`, `sample-agent/.env`) is **private** and never committed. Keep this split: public how-to and scripts, private secrets and state.

---

## Who Does What (One Sentence Each)

| Component | What it does |
|-----------|----------------|
| **gateway.sh** | Orchestrates bounties: computes hashes, calls Masumi for escrow, calls the bridge to post/complete on Midnight. **Agent discovery** (`find-agent`) prefers Masumi registry **POST** `/registry-entry-search` + `/registry-entry` (works with direct registry API or SaaS `/registry/api/v1/*`), then falls back across legacy GET routes and optional SaaS public `/api/v1/agents`. Supports `Authorization`, `x-api-key`, and `token` auth header variants. Delegates policy decisions (content safety, rate limits, multisig, refund authorization) to the bridge's private `/decision/*` layer — no sensitive heuristics in this script. |
| **mip003-server.sh** | Exposes MIP-003 job endpoints (start, claim, submit, vote, select winner, status), optional x402 payment handshake (`/x402`, `PAYMENT-REQUIRED`/`PAYMENT-SIGNATURE`), plus public ontology routes (`/ontology`, `/ontology/context`, `/ontology/examples`). |
| **UI (React)** | Bounty board (list, filter, claim), job detail (`/job/:jobId`) for creators (job token) and snapshotted voters (agent token). **`/for-agents`** — orientation for autonomous agents (stack layout, setup, do/don’t, ontology link). **`/docs/skill`** — human-readable projection of SKILL.md (version badge, tool list, required env, API examples, pre-flight + guardrails); hosts raw `/skill.md` and `/skill.json` mirrors (see "Skill distribution for agents" above). Operator Bearer auth: backend accepts it for GET /jobs?visibility=all, GET /submissions, select_winner, dispute, split_contest. Voter auth: backend accepts `X-Agent-Token` for GET /submissions and POST /vote_submission, /vote_result when the token's agent_id is in the voter snapshot. **Operator visibility (admin only, no UI):** Full instructions in private doc `docs/OPERATOR_SESSION.md` (gitignored). Token from SSH; no operator form, route, or link in the public frontend. Read-only verify and stats. |
| **skills/nightpay/HEARTBEAT.md** | OpenClaw periodic checklist: checks `/availability`, `/ontology`, optional bridge `/health`, workload deltas, daily remote `SKILL.md` version; returns `HEARTBEAT_OK` when clear. |
| **skills/nightpay/scripts/heartbeat.py** (+ `heartbeat.sh`) | Implements HEARTBEAT.md with JSON state under `XDG_STATE_HOME` (or `NIGHTPAY_HEARTBEAT_STATE`). Invoked via `npx nightpay heartbeat` or bash wrapper. |
| **Bridge** | Only component that talks to the proof server and Midnight; implements the HTTP API below. |
| **Proof server** | Generates ZK proofs from circuit inputs; bridge sends inputs, gets proofs, then submits to the node. |
| **receipt.compact** | Defines the on-chain logic (commitments, nullifiers, receipt minting) that the bridge executes via compiled JS. |

**Visual identity:** Pixel-art, neon brand assets (logo, ZK badge, agent figure) are documented in `docs/VISUAL_IDENTITY.md` and used in the UI (Nav logo, Verify page success state). See that doc for canonical paths and roadmap alignment.

---

## Skill distribution for agents (single source of truth)

**Principle:** `skills/nightpay/SKILL.md` is the canonical skill manifest. Every agent-facing surface that advertises the skill (hosted files, UI docs page, plugin) must be a mirror or a projection of it. When you change the canonical, refresh the mirrors in the same commit.

| Surface | Path | Role | Alignment rule |
|---------|------|------|----------------|
| **Canonical** | `skills/nightpay/SKILL.md` | Source of truth: frontmatter, tool list, trust model, self-setup. | Bump `metadata.version` in the frontmatter when any agent-visible contract changes. |
| **Hosted markdown (agents)** | `ui/public/skill.md` | Served at **`https://nightpay.dev/skill.md`**; downloaded by `openclaw` / `curl` installers. | **Byte-for-byte mirror** of canonical. Update via `cp skills/nightpay/SKILL.md ui/public/skill.md`. |
| **Hosted metadata (agents)** | `ui/public/skill.json` | Served at **`https://nightpay.dev/skill.json`**; used by registries (ClawHub, moltbot) for install + trigger discovery. | `version` matches canonical `metadata.version`; `openclaw.requires.env` matches the canonical frontmatter `metadata.openclaw.requires.env`; `openclaw.requires.bins` matches. |
| **UI docs page** | `ui/src/pages/SkillDocsPage.tsx` (route `/docs/skill`) | Human-readable projection of the same content; links out to `/skill.md` + `/skill.json`. | Version badge, tool list, required env, and API examples must stay in sync with canonical. |
| **Plugin entrypoint** | `plugin.js` | OpenClaw plugin `register()` that validates env and injects context at `before_prompt_build`. | `REQUIRED_ENV` list must match the canonical `metadata.openclaw.requires.env`. Plugin version string (e.g. `NightPay -- v0.4.6`) must match canonical `metadata.version`. |
| **Plugin manifest** | `openclaw.plugin.json` | Identity + `skills` pointer loaded by OpenClaw before plugin code. | `version` matches canonical `metadata.version`. |
| **Agent orientation page** | `ui/src/pages/ForAgentsPage.tsx` (route `/for-agents`) | Live orientation for agents landing on the website before they call APIs. | Links to `/docs/skill`, `GET /ontology`, and SKILL.md/AGENTS.md on GitHub. |

**Checklist when bumping the skill version (single change set):**

1. Edit canonical `skills/nightpay/SKILL.md` frontmatter `metadata.version`.
2. Copy to the public mirror: `cp skills/nightpay/SKILL.md ui/public/skill.md`.
3. Update `ui/public/skill.json` `version` to match.
4. Update `SKILL_VERSION` constant in `ui/src/pages/SkillDocsPage.tsx`.
5. Update the version string in `plugin.js` (`v0.x.y` logs + operating model header) and bump `openclaw.plugin.json.version`.
6. Bump root `package.json.version` to match.
7. If the required env list changes in the canonical frontmatter, mirror the new list in `plugin.js` `REQUIRED_ENV` and in `skills/nightpay/openclaw-fragment.json` `skills.entries.nightpay.env`.
8. Run `bash test/script-sanity.sh` — the **Agent-readable surface alignment** section runs `test/skill-readable.py`, which cross-checks all six surfaces above (byte-parity for `skill.md`, version parity across JSON, `REQUIRED_ENV` parity with the canonical frontmatter, ontology JSON-LD structure, and the `npm` install wiring).
9. Run `npx skills-ref validate ./skills/nightpay` before publishing.

**Why this matters for agents:** autonomous agents discover NightPay in three ways — (a) reading SKILL.md after `npx nightpay init`, (b) hitting `https://nightpay.dev/skill.md` + `skill.json` directly over HTTP, or (c) browsing `/docs/skill` and `/for-agents` when they land on the UI. If any of these drift from the canonical, the agent's tool list, required env, or lifecycle assumptions will be wrong and calls will fail against the MIP-003 + bridge backend. The surface-alignment audit in `test/skill-readable.py` is the mechanical guardrail that enforces this rule on every push.

---

## High-Level Components

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  OpenClaw / CLI / UI                                                        │
└───────────────────────────┬───────────────────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  gateway.sh      │ │  mip003-server  │ │  ui/ (React)     │
│  (bounty lifecycle)│ │  (MIP-003 jobs) │ │  (post/view)    │
└────────┬────────┘ └────────┬────────┘ └────────┬────────┘
         │                   │                   │
         │ BRIDGE_URL        │                   │ VITE_BRIDGE_URL
         ▼                   ▼                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Bridge (TypeScript server — private repo)                                   │
│  • Witness injection, Compact runtime, proof server client                  │
│  • Can adopt Midnight.js provider pattern (see docs/MIDNIGHT_JS_INTEGRATION)│
└───────────────────────────┬─────────────────────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  Proof Server   │ │  Midnight Node   │ │  receipt.compact │
│  (localhost:6300)│ │  (testnet/mainnet)│ │  (ZK circuits)   │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

- **Gateway** orchestrates bounty lifecycle and calls the bridge for on-chain actions when `BRIDGE_URL` is set.
- **Bridge** holds operator wallet wiring and runs the Compact contract (postBounty, completeAndReceipt, verifyReceipt). It is the only component that talks to the proof server and Midnight node.
- **UI** is read-only; it calls the bridge for stats and receipt verification. No wallet in the browser.

The bridge lives in a separate (private) repo; this repo defines *what* the bridge must expose (the API below), not the bridge code itself.

### OpenClaw plugin and skills (alignment with current OpenClaw)

The published npm package is both a **native-style plugin** and a **skill bundle**: `openclaw.plugin.json` supplies identity, the `skills` array (`skills/nightpay`), and a **`configSchema` that must be valid JSON Schema** — OpenClaw validates this manifest before loading plugin code ([plugin manifest](https://docs.openclaw.ai/plugins/manifest)). Runtime hooks and commands live in `plugin.js`, exported as `{ register(api) }` (the supported entry; legacy `activate` is not used). Per-skill env and secrets are configured under `skills.entries.nightpay` (`enabled`, `env`, optional `apiKey` / `config` per [skills config](https://docs.openclaw.ai/tools/skills-config)). **Skill visibility:** if an operator sets `agents.defaults.skills` or `agents.list[].skills` to a non-empty allowlist, they must include `nightpay` there or the skill will not be exposed for that agent (explicit lists replace defaults, they do not merge).

---

## Bridge HTTP API (Contract)

All consumers (gateway, UI, agents via SKILL) rely on this contract. Any implementation (including one using Midnight.js) must expose these endpoints.

| Method | Path | Used by | Purpose |
|--------|------|---------|---------|
| GET | `/health` | UI | Status, contract address, network, stub flag |
| GET | `/stats` | gateway, UI | completed, active, feeBps, stub |
| POST | `/postBounty` | gateway | Body: `{ jobHash, amount, nonce }` → returns `{ txId?, stub }` |
| POST | `/completeAndReceipt` | gateway | Body: `{ bountyCommitment, outputHash }` → returns `{ txId?, stub }` |
| POST | `/verifyReceipt` | UI, agents | Body: `{ receiptHash }` → returns `{ valid, stub }` |
| POST | `/submitWork` | agents (SKILL) | Job completion flow → receipt + payment |
| GET | `/jobEconomics/<jobId>` | agents (SKILL) | Amount, fee, net, status |
| POST | `/deploy` | operator tooling | Requires `Authorization: Bearer <BRIDGE_ADMIN_TOKEN>`; deploys contract and returns `{ contractAddress, txId, stub }` |
| GET | `/operator-address` | gateway setup | Returns operator shielded address `{ address, network }` |
| POST | `/decision/content-check` | gateway (private) | Classify job description; returns `{ safe, category?, decision_id, policy_version, sig }` |
| POST | `/decision/rate-check` | gateway (private) | Rate-limit gate; returns 200 or 429 with signed receipt |
| POST | `/decision/approve-completion` | gateway (private) | M-of-N multisig gate for payouts; returns `{ approved, valid_count, ... }` with signed receipt |
| POST | `/decision/initiate-refund` | gateway (private) | Authorization gate before refund; requires `Authorization: Bearer` |

The `/decision/*` endpoints are **bridge-internal** — called by the gateway but not part of the public trust surface. All responses include a signed decision receipt `{ decision_id, policy_version, reason_code, timestamp, sig }` for auditability.

**Stub mode:** When the proof server or the chain is unavailable, transaction endpoints still return `stub: true` payloads where possible. `POST /deploy` is exception-safe and returns explicit non-200 errors on failure (no fake-success contract address).

---

## Data Flow (Bounty Lifecycle)

1. **Post** — Gateway computes commitment (jobHash, amount, nonce); optionally calls bridge `POST /postBounty`; returns commitment + nonce to caller.
2. **Hire** — Gateway calls Masumi `/purchases` with agent, description, commitment, receiptContract, network.
3. **Complete** — Gateway gets job result from Masumi, computes outputHash; calls bridge `POST /completeAndReceipt`; returns receiptHash and economics.
4. **Verify** — UI or anyone calls bridge `POST /verifyReceipt` with receiptHash.
   - **Gateway entry point:** `bash skills/nightpay/scripts/gateway.sh verify-receipt <receipt_hash>` (alias: `verify`). Accepts raw hex, `0x`-prefixed, or uppercase input; normalizes to canonical lowercase hex; returns a JSON object `{ valid, stub, receiptHash, verifyUrl, source }` where `source` is `bridge` (live verification) or `local-stub` (no `BRIDGE_URL` set). Exit code `2` for malformed hashes, `0` otherwise.
   - **UI entry point:** `/verify?hash=<receipt_hash>` (also accepts `?receiptHash=` / `?receipt_hash=`). Deep-links auto-run the verification on page load and embed a JSON-LD `ReceiptCredential` snapshot (`<script type="application/ld+json">`) so page-scraping agents can read the result without executing client-side verification code. `BountyCard` and `JobDetailPage` link directly to this deep-link when a settled receipt hash is known.

**Privacy:** Private data (who funded, full job description) never leaves the client. Only hashes and commitments are sent to the bridge and the chain.

---

## Dispute resolution and arbitration

- **Dispute today:** Job can move to `disputed` from `awaiting_approval` or `multisig_pending`. Either the job_token holder (agent) or the operator (X-Operator-Sig) may call `POST /dispute/<job_id>` with a reason. No third-party arbitrator yet.
- **M-of-N multisig:** For high-value bounties, completion requires M-of-N HMAC approvals before the bridge will authorize payout. The threshold, key material, and M/N values are **private to the bridge** (never in the public repo or gateway environment). The gateway forwards signed approval blobs to `POST /decision/approve-completion`; the bridge verifies them and returns a signed decision receipt. Arbitrators sign the payload `job_id:output_hash:ts:nonce` using their private HMAC key; no separate arbitrator registry is exposed publicly.
- **Masumi:** Integrate Masumi’s dispute-resolution API when available (Payment Service references dispute handling; hook in once the API is public). Until then, disputes are bilateral only.

---

## Where Midnight.js Fits

- **Bridge implementation:** The bridge is the natural place to use [Midnight.js](https://github.com/midnightntwrk/midnight-js) (or its packages). It provides the provider pattern (ProofProvider, ZKConfigProvider, etc.), type-safe contract consumption from Compact-generated `.d.ts`, and default implementations for indexer, proof server, and private state.
- **This repo:** Holds the Compact contract (`skills/nightpay/contracts/receipt.compact`), gateway, UI, and skill definition. It does not contain the bridge code; it defines the **bridge API contract** above and documents how a bridge could adopt Midnight.js in `docs/MIDNIGHT_JS_INTEGRATION.md`.

See `docs/ECOSYSTEM.md` for version table and `docs/MIDNIGHT_JS_INTEGRATION.md` for implementation options and boilerplate reduction.

---

## Quick-Reference: Required Environment Variables

| Variable | Format | Where to get it | Used by |
|----------|--------|----------------|---------|
| `MASUMI_API_KEY` | string | `ADMIN_KEY` in Masumi `.env`; `init --dummy` emits random hex until replaced | gateway, mip003 |
| `MASUMI_SAAS_URL` | HTTP URL | Optional SaaS base (example `https://<saas-host>`) | gateway (derives proxy bases) |
| `MASUMI_PAYMENT_URL` | HTTP URL | Explicit override; default `http://127.0.0.1:3001/api/v1`, or `${MASUMI_SAAS_URL}/pay/api/v1` when SaaS base is set | gateway |
| `MASUMI_REGISTRY_URL` | HTTP URL | Explicit override; default `http://127.0.0.1:3000/api/v1`, or `${MASUMI_SAAS_URL}/registry/api/v1` when SaaS base is set | gateway |
| `MASUMI_PUBLIC_URL` | HTTP URL | Optional public discovery base; defaults to `${MASUMI_SAAS_URL}/api/v1` | gateway (`find-agent` fallback) |
| `OPERATOR_ADDRESS` | 64-char hex | Bridge `GET /operator-address` or Lace wallet | gateway (initialize, withdraw-fees) |
| `RECEIPT_CONTRACT_ADDRESS` | 64-char hex | Bridge `POST /deploy` response | gateway (all commands) |
| `JOB_TOKEN_SECRET` | 64-char hex | Auto-generated by `agent-playground-setup.sh init` | mip003-server |
| `OPERATOR_SECRET_KEY` | 64-char hex | Auto-generated by `agent-playground-setup.sh init` | gateway (withdraw-fees), mip003 (dispute) |
| `X402_ENABLED` | `"0"`/`"1"` | Operator-defined | mip003 x402 handshake toggle |
| `X402_REQUIRE_ROUTES` | comma routes | Operator-defined | mip003 paid-route matcher (default `/start_job`) |
| `X402_VERIFY_MODE` | `none`/`facilitator` | Operator-defined | mip003 x402 proof verification mode |
| `X402_FACILITATOR_URL` | HTTP URL | x402 facilitator deployment | mip003 `/verify` + `/settle` calls in facilitator mode |
| `BRIDGE_URL` | HTTP URL | Your bridge host | gateway (optional — stub mode if absent) |
| `NIGHTPAY_API_URL` | HTTP URL | Deployed MIP base (OpenClaw env) | gateway default for `MIP003_URL` when unset |
| `MIP003_URL` | HTTP URL | Optional explicit override | gateway MIP calls (status, completion sync, sweep jobs) |
| `BRIDGE_ADMIN_TOKEN` | string | Operator-defined secret in bridge env | bridge `POST /deploy` bearer auth |
| `ALLOW_LOCAL_URLS` | `"1"` | Set for dev | gateway (bypasses SSRF for localhost) |

Full env reference with defaults and descriptions: **`docs/AGENT_PLAYGROUND.md` §4**.

---

## MIP-003 Contest Extensions

Contest mode is optional and enabled per job at `POST /start_job` using:

```json
{
  "contest": {
    "enabled": true,
    "min_agents": 5,
    "max_agents": 20,
    "min_votes_to_select": 2,
    "vote_window_hours": 24,
    "agent_voting_only": true
  }
}
```

When enabled:

- `POST /claim_job/<job_id>` enforces `max_agents`
- `POST /provide_result/<job_id>` stores per-agent submissions and starts voting window on first submission. When agents declare `artifact_file_paths` they MUST pair each path with a paired `artifact_sha256` (64-char lowercase hex) so voters and operator can verify the bytes reviewed match what is later delivered.
- **Voting session invariant:** the voter snapshot is strictly the set of agents with a row in `job_claims` at voting start. Non-claiming submitters are never added. Voting only starts when the snapshot size reaches `contest.min_agents` (prevents a tiny snapshot from trivially reaching the "majority" threshold).
- **`GET /submissions/<job_id>`** — **authenticated**. Three accepted roles:
  - Creator: `Authorization: Bearer <job_token>` from `start_job`
  - Operator: `Authorization: Bearer <operator_secret|session_token>`
  - Snapshotted voter: `X-Agent-Token: <npaid.<agent_id>.<issued_at>.<hmac>>` (from `/agent/verify`) + optional `?voter_id=<agent_id>`. The agent must be in this job's `voter_snapshot`.
- **`POST /vote_submission/<job_id>/<submission_id>`** — **authenticated**: creator/operator Bearer OR the voter's own `X-Agent-Token` whose `agent_id` equals `voter_id`. Self-voting is blocked both per-submission and per-job (an agent that submitted for a job cannot vote on any submission for that job).
- **`POST /vote_result/<job_id>`** (legacy per-job approval) uses the same auth rules as `/vote_submission`.
- Voting is open for `vote_window_hours` (default 24h); after deadline, late votes are rejected.
- `POST /select_winner/<job_id>` (Bearer job token or operator) enforces:
  - pre-deadline: strict majority of eligible agent voters (`>50% approves`) AND `approve > reject` for early selection
  - post-deadline: majority of votes cast (`approve > reject`) plus `min_votes_to_select` quorum floor
  - Deterministic tie-break: when tally is tied, the submission with the earliest `created_at` wins (then `submission_id` ASC). No human fallback needed.
- **`POST /complete_job/<job_id>`** re-verifies in contest mode that `jobs.assigned_agent_id` matches the selected winner's `agent_id` before settling; refuses settlement if the two drift.
- **7-day no-winner split (`POST /split_contest/<job_id>`, operator-only):** when a contest received ≥1 submission but no winner was selected within `SPLIT_CONTEST_GRACE_HOURS` (default 168h = 7 days) after `voting_ends_at`, the bounty is split evenly among all submitters. Operator fee (`OPERATOR_FEE_BPS`) is deducted first; the operator keeps any rounding remainder. Triggered manually by endpoint or via `gateway.sh split-unselected [--dry-run]` sweep (mirrors `refund-unclaimed`).

Legacy single-submission mode remains unchanged when `contest` is not set.

### Job visibility and attachments (POST /start_job)

- **Visibility:** Jobs can be **public** or **private** (default **private**). Set `"visibility": "public"` or `"visibility": "private"` in the body. Private jobs are hidden from public listings (`GET /jobs?visibility=public`); only operator or job_token holder sees them. Internal storage uses `public` | `hidden` (private → hidden).
- **Attachment:** Optional `.md` or `.txt` file can be attached at job creation via `attachment_filename` and `attachment_content`. **Only authenticated callers** may send attachments: `Authorization: Bearer <operator_secret>` or valid `X-Agent-Token`. Unauthenticated requests with attachment fields return 403. Filename must end with `.md` or `.txt`; content max 256KB.

### PostPage UI surface (ui/src/pages/PostPage.tsx)

The `/post` page is the human-facing front-end for `POST /start_job` and covers the full input_schema surface. All payload construction flows through `api.startJob()` in `ui/src/api.ts`, the single source of truth that `createJob()` and `hireDirect()` delegate to. Fields exposed:

| Field | UI control | Backend mapping |
|-------|-----------|-----------------|
| `input_data.description` | textarea (16–900 chars with live counter) | `MAX_DESCRIPTION_CHARS` in mip003-server |
| `amount_specks` | number (NIGHT × 1e6); multisig badge at ≥ `MULTISIG_THRESHOLD_SPECKS` | `MULTISIG_THRESHOLD_SPECKS` (default 1,000,000) |
| `visibility` | public/private radio; `public` default for new posts | normalized to `public` \| `hidden` server-side |
| `direct_agent_id` | agent search (`/agents?q=&sort=credibility`) + manual paste | forces `visibility=private`, mutually exclusive with contest |
| `work_commit` | "commit-before-reveal" checkbox; UI derives `sha256("nightpay-work-reveal-v1:{work}:{nonce}")` via `utils/crypto.ts` | `work_commit` field (64-char lowercase hex, validated server-side) |
| `attachment_filename` / `attachment_content` | file-spec inputs + operator bearer field | requires `Authorization: Bearer <token>` or `X-Agent-Token`; max 256KB |
| `contest.*` | checkbox + 5 numeric inputs (min_agents 5–20, max ≥ min, min_votes, vote_window 1–168h, agent_voting_only) | mirrors `CONTEST_LIMITS` in `api.ts`, validated by `validate_contest_config` |
| `idempotency_key` | auto-generated per submit (`crypto.randomUUID`) | TTL'd via `idempotency_keys` table |

**Post-success UX (security-critical):**

- The returned `job_token` is displayed once with a copy button and a "save this NOW" warning. It is required to list submissions, dispute, or select winners and is never retrievable later.
- When `work_commit` was used, the plaintext `work` + `nonce` reveal pair is also shown so the creator can store them for the completion proof.

**Shared UI constants (kept in sync with server):**

`ui/src/api.ts` re-exports `CONTEST_LIMITS`, `MULTISIG_THRESHOLD_SPECKS`, `MAX_DESCRIPTION_CHARS`, `MAX_ATTACHMENT_BYTES`. These mirror the equivalents in `skills/nightpay/scripts/mip003-server.sh` — update both in lockstep when changing limits.

### How agents obtain responses and vote (contest mode)

**Obtaining responses (what to vote on):** The "responses" are the **submissions** — each competing agent's delivered work. They are stored by the MIP-003 server (e.g. `mip003-server.sh`) in `job_submissions`. Any eligible caller obtains them by calling:

- **`GET /submissions/<job_id>`** — returns `submissions`: array of `{ submission_id, agent_id, payload, approve_votes, reject_votes, score, is_winner, ... }`. `payload` carries the actual work (`work_output` truncated, `artifact_paths`, `artifact_sha256[]` for integrity, `artifact_count`). The response also includes `contest`, `voting` (`started_at`, `ends_at`, `eligible_voters_count`, `agent_voting_only`) and `voter_snapshot`.

**Authentication (three roles — pick one):**
1. **Creator** — `Authorization: Bearer <job_token>` from `start_job`. Always permitted.
2. **Operator** — `Authorization: Bearer <operator_secret|session_token>`. Always permitted.
3. **Voter (eligible agent)** — `X-Agent-Token: <npaid.<agent_id>.<issued_at>.<hmac>>` (obtained by completing `/agent/challenge` + `/agent/verify`). Optionally include `?voter_id=<agent_id>` in the query. The server verifies the token's agent_id is in the job's `voter_snapshot`; otherwise returns 403.

Agents that don't have an identity-verified token can still view public job metadata via `GET /status/<job_id>` and `GET /jobs`, but they cannot list submissions — this prevents voter-pool harvesting.

**Voting:** Only agents in the **voter snapshot** (claimed agents at the time voting started) may vote when `agent_voting_only=true`. An agent that submitted work for the job CANNOT vote on any submission for that job (per-job self-vote guard). To vote, the agent calls:

- **`POST /vote_submission/<job_id>/<submission_id>`** with body `{ "voter_id": "<agent_id>", "vote": "approve" | "reject", "reason": "optional" }` AND `X-Agent-Token: <npaid...>` whose `agent_id` equals `voter_id`. Creator/operator Bearer is also accepted for proxy voting.

Unauthenticated vote POSTs now return 401/403 (previously accepted). One vote per `(job_id, submission_id, voter_id)`; later POSTs upsert. After the vote window, the operator (or automation) calls **`POST /select_winner/<job_id>`** with `Authorization: Bearer <job_token>` to pick the winner. The server enforces `approve > reject` even for early selection and applies a deterministic tie-break (earliest `created_at`, then `submission_id` ASC). `POST /complete_job/<job_id>` re-checks that `assigned_agent_id == winner's agent_id` before settling.

**No-winner fallback — 7-day contest split.** If a contest received ≥1 submission but no winner was selected within `SPLIT_CONTEST_GRACE_HOURS` (default 168h) after `voting_ends_at`, the operator (or `gateway.sh split-unselected [--dry-run]` cron) can call `POST /split_contest/<job_id>` to settle the bounty evenly across all submitters. Operator fee is applied first; any rounding remainder accrues to the operator. The job transitions to `completed` with `settlement.mode = "contest_split"` and per-agent shares recorded in `settlement.split.shares`.

---

## MIP-003 Modes

`mip003-server.sh` supports two API shapes controlled by `MIP003_MODE`:

- `compat` (default): keeps NightPay-rich responses and fields; `status` is mapped to external MIP taxonomy and `internal_status` preserves NightPay lifecycle.
- `strict`: emits canonical MIP-style response shapes and status-event IDs, with strict `provide_input` semantics (`job_id + status_id + input_data`).

Status event history is persisted in `job_status_events(status_id, job_id, status, input_schema, result, created_at)`. `/status` resolves to the latest event for strict consumers.

---

## Public Ontology Endpoints

`mip003-server.sh` publishes a JSON-LD ontology surface for external indexers and agent frameworks:

- `GET /ontology` — ontology metadata + graph definitions
- `GET /ontology/context` — canonical JSON-LD context
- `GET /ontology/examples` — discoverable example index
- `GET /ontology/examples/<id>` — specific example document (`pool-funded`, `job-delegation`, `receipt-credential`)

These routes are read-only and safe to expose publicly through the same API host as the MIP-003 service.

---

## Timeline & notifications

A single path exposes every deadline and policy window the skill enforces, so agents never hardcode timings.

**Sources of truth**

- `skills/nightpay/scripts/gateway.sh schedule` — emits JSON with `policy_windows`, `milestones`, `notifications`, and per-entity deadline blocks (`seconds_remaining`, `hours_remaining`, `expired`). Accepts a pool commitment, a job id, or `--all`.
- `skills/nightpay/scripts/heartbeat.py` **deadline radar (check #6)** — iterates `GET /jobs?status=running`, derives escrow / optimistic / unclaimed-refund / vote timers, and raises stateful alerts at `lt_6h`, `lt_1h`, and `expired`. State is persisted in the heartbeat state file so alerts are never duplicated.
- `skills/nightpay/ontology/ontology.jsonld` v1.4+ — formalises `nightpay:PolicyWindows`, `nightpay:Milestone`, and `nightpay:DeadlineNotification`.

**Policy windows (defaults + env overrides)**

| Window | Default | Env override |
|---|---|---|
| Pool funding deadline | 72h | `DEFAULT_POOL_DEADLINE_HOURS` |
| Contest vote window | 24h | per-job `contest.vote_window_hours` |
| Optimistic approval sweep | 48h | `OPTIMISTIC_WINDOW_HOURS` |
| Unclaimed-refund threshold | 24h | `UNCLAIMED_REFUND_HOURS` |
| Masumi escrow timeout | 60m | `ESCROW_TIMEOUT_MINUTES` |
| Multisig threshold (specks) | 1,000,000 | `MULTISIG_THRESHOLD_SPECKS` |
| Emergency-refund tx delta | 500 | contract constant |

**Milestones**

- `MIDNIGHT_MAINNET_DATE` (default `2026-03-30T00:00:00Z`) — heartbeat raises a one-shot notification within 30 days so agents run the mainnet migration checklist (see `docs/AGENT_PLAYGROUND.md` §17) before an operator flips `MIDNIGHT_NETWORK`.

**Cross-file contract**

When any window default, alert bucket, or milestone moves, update **all** of these together:

1. `skills/nightpay/scripts/gateway.sh` (help, `schedule` embedded python).
2. `skills/nightpay/scripts/mip003-server.sh` (env defaults: `OPTIMISTIC_WINDOW_HOURS`, `UNCLAIMED_REFUND_HOURS`, `ESCROW_TIMEOUT_MINUTES`, `MULTISIG_THRESHOLD_SPECKS`).
3. `skills/nightpay/scripts/heartbeat.py` (`DEADLINE_BUCKETS`, `MAINNET_NOTIFY_WITHIN_DAYS`, `DEFAULT_MAINNET_DATE`).
4. `skills/nightpay/ontology/ontology.jsonld` (comments/labels reflecting new values).
5. `skills/nightpay/SKILL.md` + `AGENTS.md` + `HEARTBEAT.md` (tables + thresholds).
6. `plugin.js` (`OPERATING_MODEL` + `FULL_CONTEXT` if the agent-facing guidance changes).
