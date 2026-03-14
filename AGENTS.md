# NightPay — Agent Coding Instructions

This file is read automatically by Claude Code, OpenClaw, Cursor, Copilot, and any
AGENTS.md-compatible agent before writing or reviewing code in this repo.

**Before writing any code, reflect on the three reference ecosystems below.**
Check the relevant section for the component you are touching.

---

## 1. Midnight / Cardano / Hoskinson

**What we build on:** Midnight is IOG's ZK privacy L1 anchored to Cardano.
Our contract (`skills/nightpay/contracts/receipt.compact`) runs here.
Our bridge (`bridge/`) talks to it via the TypeScript SDK.

**Always check before touching Compact or bridge code:**

| Resource | URL | Use for |
|---|---|---|
| Compact language reference | https://docs.midnight.network/develop/reference/compact/lang-ref | Syntax, types, circuit rules — ground truth |
| Compact stdlib | https://docs.midnight.network/develop/reference/compact/compact-std-library/exports | MerkleTree, hash, effects, send, receive |
| Compact overview + DSL | https://docs.midnight.network/compact | Circuits, witnesses, public/private state model |
| Midnight concepts | https://docs.midnight.network/concepts | Ledgers, UTXO, ZK proofs, Kachina, Compact — align terminology |
| Compact tools release notes | https://docs.midnight.network/relnotes/compact-tools | Compiler version changes, `compact fixup` notes |
| All component release notes | https://docs.midnight.network/relnotes/overview | Node, proof server, SDK, DApp connector |
| Midnight MCP (AI dev) | https://docs.midnight.network/blog/midnight-mcp-ai-assisted-development | AI-assisted Compact dev — validates against real compiler |
| Masumi docs | https://docs.masumi.network/documentation | Agent payment integration |
| Masumi API reference | https://docs.masumi.network/api-reference | Endpoint schemas for gateway.sh and mip003-server.sh |
| Masumi MIP-003 spec | https://docs.masumi.network/core-concepts/agentic-service | Required endpoints for our MIP-003 server |
| Masumi GitHub | https://github.com/masumi-network | Source, quickstarts, SDK |
| Cardano developer portal | https://developers.cardano.org/ | Settlement layer context |
| IOG technical blog | https://iohk.io/en/blog/ | Architecture decisions, partner chain updates |
| DeepWiki: masumi-docs | https://deepwiki.com/masumi-network/masumi-docs | Internal structure when docs are sparse |

**Key rules for this codebase:**
- Compact developer tools are **v0.4.0** (Jan 2026) — run `compact fixup --check` first, then `compact fixup`
- Compact compiler inside tools is v0.29.0 — `fixup --check` mode was added in 0.4.0 (use it)
- Proof system is BLS12-381 — do NOT write Pluto-Eris code
- `MerkleTree<25>` is our depth — max is 32, we are safe
- Bridge SDK versions: `midnight-js-*@3.1.0`, `wallet-sdk-*@1.0.0`, `ledger-v7@7.0.1`, `compact-js@2.4.0`
- Proof server runs on `localhost:6300` via Docker — always local, never remote
- **Mainnet (Kūkolu) launches last week of March 2026** — keep `preprod` default until then
- **Midnight City simulation opens Feb 26, 2026** — good demo window before mainnet
- WebSocket polyfill (`globalThis.WebSocket = WebSocket`) must be set before any provider
- Browser wallet is Lace (Chrome only, `window.midnight.mnLace`) — our bridge is server-side, no browser wallet needed
- Compact is now formally named **Minokawa** under LF Decentralized Trust — docs still say "Compact"

**Critical env vars — format reference:**
- `RECEIPT_CONTRACT_ADDRESS` — **64-char lowercase hex** string. Returned by bridge `POST /deploy` when the contract is deployed. Required by every gateway command. See `docs/AGENT_PLAYGROUND.md` §3 for deployment steps.
- `OPERATOR_ADDRESS` — **64-char lowercase hex** (32-byte Midnight shielded address). Derived from operator wallet spending key. Get from bridge `GET /operator-address` or Lace wallet Settings → Developer → Spending Key → Derived Address. Set once at `initialize()` — immutable after.
- `MASUMI_API_KEY` — the `ADMIN_KEY` value from the Masumi `.env` file. Set when installing Masumi via docker compose. See `docs/AGENT_PLAYGROUND.md` §2.
- `BRIDGE_URL` — HTTP base URL of the running bridge, e.g. `http://localhost:4000`. If empty, gateway runs in stub/local mode — hashes computed locally, no Midnight transactions.

**Masumi local install (required for `doctor` to pass):**
```bash
git clone https://github.com/masumi-network/masumi-services-dev-quickstart.git
cd masumi-services-dev-quickstart && cp .env.example .env
# Fill BLOCKFROST_API_KEY_PREPROD (free at blockfrost.io, choose Preprod) and ADMIN_KEY
docker compose up -d
```

**OpenZeppelin Compact security scanner (run before every deployment):**
```bash
npm install -g @openzeppelin/compact-security-detectors-sdk
compact-security-detectors scan skills/nightpay/contracts/receipt.compact
```

---

## 2. OpenClaw

**What we target:** OpenClaw agents discover and run our skill from `skills/nightpay/`.
The SKILL.md frontmatter is how they find us.

**Always check before touching SKILL.md or openclaw-fragment.json:**

| Resource | URL | Use for |
|---|---|---|
| Skills reference | https://docs.openclaw.ai/tools/skills | SKILL.md format, frontmatter schema, discovery |
| Skills config | https://docs.openclaw.ai/tools/skills-config | `openclaw.json` schema — `entries`, `env`, `enabled` |
| ClawHub docs | https://docs.openclaw.ai/tools/clawhub | Publishing, versioning, `clawhub install` |
| AgentSkills spec | https://agentskills.io/specification | The open standard SKILL.md implements |
| AGENTS.md standard | https://agents.md/ | This file's format |
| OpenClaw AGENTS.md | https://github.com/openclaw/openclaw/blob/main/AGENTS.md | How OpenClaw itself is maintained |
| DeepWiki: openclaw | https://deepwiki.com/openclaw/openclaw | Architecture, skills system internals |
| ClawHub registry | https://clawhub.com/ | Competitive research, verify our listing |

**Key rules for SKILL.md:**
- `name` must exactly match the directory name (`nightpay`)
- `description` is the activation mechanism — keep trigger phrases in it
- `compatibility` must be a plain string, NOT a YAML list
- `metadata` must be single-line JSON string — OpenClaw's parser rejects multi-line
- `allowed-tools: Bash` is required for shell script skills
- `metadata.openclaw.os` must exclude `win32` for bash-only skills
- `skills.entries` in openclaw.json valid fields: `enabled`, `env`, `apiKey`, `config` (config added v2026.1.30)
- Fields `path`, `activation`, `tools.allow/deny` are NOT valid entries fields
- Validate before ClawHub submission: `npx skills-ref validate ./skills/nightpay`
- ClawHub now runs safety scanning — 230+ malicious skills flagged since Jan 2026; clean skills pass automatically

---

## 3. Claude Code

**What we use:** Claude Code (this agent) reads this file. Our npm package also
supports `npx nightpay init` which installs the skill into Claude Code projects.

**Always check before touching SDK integration or hook patterns:**

| Resource | URL | Use for |
|---|---|---|
| Claude Code overview | https://code.claude.com/docs/en/overview | Tools, memory, agent loop |
| Memory + CLAUDE.md format | https://code.claude.com/docs/en/memory | CLAUDE.md hierarchy, @import syntax |
| Hooks reference | https://code.claude.com/docs/en/hooks | Hook events, JSON schemas, lifecycle |
| Release notes | https://docs.anthropic.com/en/release-notes/claude-code | Breaking changes, new capabilities |
| Claude Agent SDK | https://platform.claude.com/docs/en/agent-sdk/overview | Programmatic agent building |
| Agent SDK migration | https://platform.claude.com/docs/en/agent-sdk/migration-guide | Breaking changes from claude-code SDK |
| MCP specification | https://modelcontextprotocol.io/specification/2025-11-25 | Protocol spec (Nov 2025, current) |
| MCP docs | https://modelcontextprotocol.io/ | Quickstart, server concepts |
| MCP reference servers | https://github.com/modelcontextprotocol/servers | Implementation templates |

**Key rules:**
- Project memory lives in `MEMORY.md` (this project) and `~/.claude/projects/.../MEMORY.md`
- The `docs/ECOSYSTEM.md` tracks all external repos — check it before architectural decisions
- **Agent onboarding runbook (complete): `docs/AGENT_PLAYGROUND.md`** — covers Masumi install, contract deployment, all env vars, full lifecycle, all endpoints, recovery matrix
- Preferred bootstrap command for agents: `bash scripts/agent-playground-setup.sh init`
- `AGENTS.md` (this file) is the coding instruction layer — update it when conventions change
- `.claude/` and `.cursor/` — local IDE config and skills; never commit (see "Do not publish" below)

---

## 4. OpenShart (Encrypted Agent Memory)

**What we use:** OpenShart encrypts funder credentials so they never appear in
plaintext conversation history, agent logs, or LLM provider telemetry.

**Always check before touching credential storage or gateway fund-pool/refund code:**

| Resource | URL | Use for |
|---|---|---|
| OpenShart GitHub | https://github.com/bcharleson/openshart | Source, API reference |
| OpenShart website | https://www.openshart.dev/ | Architecture, security model |

**Key rules for this codebase:**
- `fund-pool` auto-detects OpenShart and encrypts credentials — never print raw nullifiers when OpenShart is available
- `claim-refund` and `emergency-refund` accept `--memory-id` for auto-recall
- Credentials are compartmentalized under `NIGHTPAY_FUNDING` — do not change the compartment name
- OpenShart is **optional** — gateway.sh must always work without it (plaintext fallback with WARNING)
- `_shart_store()` / `_shart_recall()` / `_shart_search()` are the only gateway functions that touch OpenShart
- Never import OpenShart in the Compact contract or bridge — it's a gateway-layer concern only

---

## Project Conventions

**File ownership:**
- `receipt.compact` — ZK contract, touch carefully, run `compact fixup --check` then `compact fixup` after
- `gateway.sh` — bounty lifecycle, main integration point between Masumi and Midnight
- `mip003-server.sh` — MIP-003 HTTP server (Python inside bash), job lifecycle + idempotency
- `bridge/src/` — TypeScript SDK integration, follows example-bboard patterns (not example-counter — we have witnesses)
- `SKILL.md` — agent discovery, strict format rules (see OpenClaw section above)
- `openclaw-fragment.json` — merge into `~/.openclaw/openclaw.json` to activate skill with env vars
- `docs/AGENT_PLAYGROUND.md` — **the complete agent onboarding runbook** — update when setup steps change
- `docs/HETZNER_X86_RUNBOOK.md` — reproducible VPS deployment flow used on Hetzner x86 instances
- `docs/ECOSYSTEM.md` — ecosystem tracker, update before releases
- `docs/architecture.md` — component overview + bridge API contract — update when endpoints change
- `docs/MIDNIGHT_JS_INTEGRATION.md` — bridge adoption options (Option A–D) for bridge maintainers
- `scripts/agent-playground-setup.sh` — agent bootstrap (init/start/doctor/stop)
- `ui/` — read-only React bounty board frontend; no wallet required for viewers

**Runtime agent playbooks (how to use NightPay):**
- **Post + hire flow:** `gateway.sh post-bounty` -> `gateway.sh find-agent` -> `gateway.sh hire-and-pay <agent> <desc> <commitment> [refund_address]`
- **Delivery + settlement flow:** worker calls `/provide_input/<job_id>` or `/provide_result/<job_id>` with `Authorization: Bearer <job_token>`; operator runs `gateway.sh complete <job_id> <commitment>`
- **No-agent refund flow:** run `gateway.sh refund-unclaimed --dry-run` then without dry-run on schedule; this only targets `running` jobs with `claims_count=0`, empty assignee, old `started_at`, and valid `input_data.commitmentHash`
- **Dispute flow:** `/dispute/<job_id>` is valid from `running`, `awaiting_approval`, and `multisig_pending` (job_token or operator signature required)
- **High-value flow:** if `amount_specks >= MULTISIG_THRESHOLD_SPECKS`, job transitions to `multisig_pending` and requires multisig approval path before `complete`
- **Ops routing flow:** keep ports `3333/8090/4000` private; expose only `80/443` and reverse-proxy subdomains via Caddy (`board.*`, `api.*`, `bridge.*`)

**Git/submodule workflow (required):**
- This workspace has three repos: root `nightpay`, submodule `ui/`, submodule `bridge/`.
- Commit in the repo where files changed (`git -C ui ...`, `git -C bridge ...`, or root `git ...`).
- Push submodule commits first, then commit root submodule pointers (`git add ui bridge`) when root must reference those new SHAs.
- Before push, run: `git status --short`, `git -C ui status --short`, `git -C bridge status --short`, `git submodule status`.
- Reference runbook: `docs/SUBMODULE_WORKFLOW.md`.

**When editing 5/6/7 flows (refund/discovery/dispute), update these together:**
1. `skills/nightpay/scripts/gateway.sh`
2. `skills/nightpay/scripts/mip003-server.sh`
3. `test/smoke.sh` (Section `gateway.sh refund + discovery pretend` and dispute tests)
4. `README.md` (operator/agent runbook)

**Before any release:**
1. Run `bash test/smoke.sh` — tests run without Midnight/Masumi connectivity
2. Run `compact-security-detectors scan skills/nightpay/contracts/receipt.compact`
3. Check `docs/ECOSYSTEM.md` refresh checklist
4. Bump version in `package.json` and `SKILL.md` metadata together
5. Run `npx skills-ref validate ./skills/nightpay`
6. Run `npm publish` from repo root

**Stub mode (for agents running without bridge):** If `BRIDGE_URL` is not set, `gateway.sh` computes hashes locally and skips on-chain calls. All commands still work — they just don't submit to Midnight. `onChain: false` and `stub: true` appear in responses. This is expected in dev.

**Public repo — do not publish (must be in .gitignore, never commit):**  
Canonical list and rationale: **`docs/architecture.md` § "Public vs private (what goes in .gitignore)"**. Summary: **`bridge/`** (do not replicate — private repo), `plans/`, `LAUNCH.md`, `docs/MARKETING.md`, `.cursor/`, `.claude/`, `.private/`, `scripts/*` (except the three allowlisted), `.agent-playground*` and playground envs, SSH keys and key material, `docs/HETZNER_X86_RUNBOOK.md`, `test/smoke.sh`, `test/chaos_stress_suite.py`, and any file with real hostnames, API keys, or deployment credentials. Validate before push: `git status` and `git diff --cached` must not add paths listed in `.gitignore`.

**Never:**
- Log or persist bounty descriptions in plaintext (classify-then-forget rule)
- Store funder identity anywhere
- Commit `WALLET_SEED`, `MASUMI_API_KEY`, `OPERATOR_SECRET_KEY`, or `JOB_TOKEN_SECRET`
- Use Pluto-Eris proof code (migrated to BLS12-381 May 2025)
- Deploy to `win32` without removing shell script dependencies first
- Switch `MIDNIGHT_NETWORK` to `mainnet` without explicit human approval and the mainnet migration checklist in `docs/AGENT_PLAYGROUND.md` §17
