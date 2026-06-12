# NightPay Agent Onboarding — Universal Guide

> How to add NightPay to **any** AI agent platform, or use it with no platform at all.

NightPay's core is platform-agnostic: `gateway.sh` is pure Bash + curl, and the MIP-003 API speaks HTTP/JSON. The `SKILL.md` declares compatibility with OpenClaw, ACP, Claude Code, Cursor, and Copilot — but the actual integration surface is just **environment variables + shell commands**.

This guide covers every supported platform, plus a raw API path for anything else.

---

## Table of Contents

1. [Prerequisites (all platforms)](#1-prerequisites-all-platforms)
2. [Platform A: OpenClaw](#2-platform-a-openclaw)
3. [Platform B: Claude Code](#3-platform-b-claude-code)
4. [Platform C: Cursor](#4-platform-c-cursor)
5. [Platform D: GitHub Copilot](#5-platform-d-github-copilot)
6. [Platform E: ACP (Agent Communication Protocol)](#6-platform-e-acp)
7. [Platform F: Raw API (no orchestrator)](#7-platform-f-raw-api-no-orchestrator)
8. [Verification (all platforms)](#8-verification-all-platforms)
9. [Environment Variables Reference](#9-environment-variables-reference)
10. [FAQ](#10-faq)

---

## 1. Prerequisites (all platforms)

Before you begin, you need:

| Requirement | Why |
|---|---|
| `bash`, `curl`, `openssl`, `sqlite3`, `sha256sum` | Required by `gateway.sh` |
| A running NightPay stack (MIP-003 API + bridge) | Your agent talks to deployed endpoints |
| `MASUMI_API_KEY` | Authentication with the Masumi payment service |
| `OPERATOR_ADDRESS` | Your Midnight operator shielded address |
| Network access to `NIGHTPAY_API_URL` and `BRIDGE_URL` | The deployed stack endpoints |

**Don't have a running stack?** See `docs/AGENT_PLAYGROUND.md` for operator bootstrap. VPS deploy runbooks are private (local `docs/HETZNER_X86_RUNBOOK.md`, gitignored).

### Get the skill files

Pick one:

```bash
# Option 1: npx (recommended — copies skill files into ./skills/nightpay)
npx nightpay init

# Option 2: git clone
git clone https://github.com/nightpay/nightpay.git
cd nightpay
```

> **Important (git clone only):** The skill files live at `skills/nightpay/` inside the repo.
> If your platform expects skills at a specific path, you may need to copy or symlink
> that directory. See the platform-specific sections below.

---

## 2. Platform A: OpenClaw

> **Full guide:** [`docs/OPENCLAW_ONBOARDING.md`](OPENCLAW_ONBOARDING.md)

### Recommended: Plugin Install (two commands)

```bash
openclaw plugins install nightpay
openclaw plugins enable nightpay
```

Skill files are auto-discovered from the installed package. No workspace copy, no fragment merge.
Then set credentials and restart:

```bash
openclaw config set skills.entries.nightpay.env.MASUMI_API_KEY "your-key"
openclaw config set skills.entries.nightpay.env.OPERATOR_ADDRESS "64-char-hex"
openclaw config set skills.entries.nightpay.env.BRIDGE_URL "https://bridge.nightpay.dev"
openclaw gateway restart
```

Verify: `/nightpay status` in your connected channel.

### Alternative: npx init + fragment merge

```bash
cd ~/.openclaw/workspace-<agent>
npx nightpay init
# Merge skills/nightpay/openclaw-fragment.json into openclaw.json
# Set real env values (fragment has empty placeholders)
openclaw config validate && openclaw gateway restart
```

See [`OPENCLAW_ONBOARDING.md`](OPENCLAW_ONBOARDING.md) for all paths including git clone.


## 3. Platform B: Claude Code

Claude Code discovers tools via Markdown files in the project directory. NightPay's `SKILL.md` is already in the right format.

### Step 1: Add skill to your project

```bash
cd your-project/
npx nightpay init
# Creates ./skills/nightpay/ with SKILL.md and all scripts
```

Or with git:

```bash
git clone https://github.com/nightpay/nightpay.git /tmp/nightpay-src
cp -r /tmp/nightpay-src/skills/nightpay ./skills/nightpay
```

### Step 2: Create a .claude/commands/ wrapper (optional but recommended)

Create `.claude/commands/nightpay.md`:

```markdown
---
description: "Run NightPay bounty operations"
---

Use the NightPay skill at `skills/nightpay/SKILL.md` for anonymous community bounty operations.

Available commands via `bash skills/nightpay/scripts/gateway.sh`:
- `create-pool <description> <contribution_specks> <goal_specks>` — create a bounty pool
- `fund-pool <pool_commitment>` — fund an existing pool
- `pool-status <pool_commitment>` — check pool status
- `post-bounty <description> <amount_specks>` — post a simple bounty
- `find-agent <capability>` — discover agents on Masumi
- `stats` — view contract statistics
```

### Step 3: Set environment variables

Add to your `.claude/settings.json` or export before launching Claude Code:

```bash
export MASUMI_API_KEY="your-actual-key"
export OPERATOR_ADDRESS="your-operator-address"
export NIGHTPAY_API_URL="https://api.nightpay.dev"
export BRIDGE_URL="https://bridge.nightpay.dev"
export MIDNIGHT_NETWORK="preprod"
```

Or create a `.env` file in your project root:

```env
MASUMI_API_KEY=your-actual-key
OPERATOR_ADDRESS=your-operator-address
NIGHTPAY_API_URL=https://api.nightpay.dev
BRIDGE_URL=https://bridge.nightpay.dev
MIDNIGHT_NETWORK=preprod
```

### Step 4: Verify

In Claude Code, ask:

```
Run: bash skills/nightpay/scripts/gateway.sh stats
```

If you see contract statistics, the skill is working.

### How Claude Code uses it

Claude Code reads `SKILL.md` for context about what the skill does, then executes commands via `Bash` tool calls to `gateway.sh`. The agent understands the bounty lifecycle from the skill description and can orchestrate multi-step flows (create pool → fund → hire agent → complete).

---

## 4. Platform C: Cursor

Cursor uses project rules and tool definitions. NightPay integrates via `.cursor/rules/` or `.cursorrules`.

### Step 1: Add skill files

```bash
cd your-project/
npx nightpay init
```

### Step 2: Create a Cursor rule

Create `.cursor/rules/nightpay.md`:

```markdown
# NightPay Bounty Skill

When the user asks about bounties, community funding, or anonymous payments,
use the NightPay skill.

## Available commands

Run these via the terminal:

```bash
# Create a bounty pool
bash skills/nightpay/scripts/gateway.sh create-pool "description" 5000 25000

# Fund a pool anonymously
bash skills/nightpay/scripts/gateway.sh fund-pool <pool_commitment>

# Check pool status
bash skills/nightpay/scripts/gateway.sh pool-status <pool_commitment>

# Post a simple bounty
bash skills/nightpay/scripts/gateway.sh post-bounty "description" 10000

# Find an agent
bash skills/nightpay/scripts/gateway.sh find-agent "code review"

# View stats
bash skills/nightpay/scripts/gateway.sh stats
```

## Environment

Required env vars must be set before running:
- MASUMI_API_KEY, OPERATOR_ADDRESS, NIGHTPAY_API_URL, BRIDGE_URL

See `skills/nightpay/SKILL.md` for full documentation.
```

### Step 3: Set environment variables

Add to your shell profile or `.env`:

```bash
export MASUMI_API_KEY="your-actual-key"
export OPERATOR_ADDRESS="your-operator-address"
export NIGHTPAY_API_URL="https://api.nightpay.dev"
export BRIDGE_URL="https://bridge.nightpay.dev"
```

### Step 4: Verify

In Cursor's chat, ask: "Run `bash skills/nightpay/scripts/gateway.sh stats`"

---

## 5. Platform D: GitHub Copilot

GitHub Copilot agent mode can execute shell commands. NightPay works via workspace instructions.

### Step 1: Add skill files

```bash
cd your-project/
npx nightpay init
```

### Step 2: Add workspace instructions

Create `.github/copilot-instructions.md` (or append to it):

```markdown
## NightPay Bounty Skill

This project includes the NightPay anonymous bounty skill at `skills/nightpay/`.

When asked about bounties, anonymous funding, or agent payments, use:

```bash
bash skills/nightpay/scripts/gateway.sh <command> [args]
```

Commands: create-pool, fund-pool, pool-status, post-bounty, find-agent,
hire-and-pay, check-job, complete, refund, stats.

See `skills/nightpay/SKILL.md` for full documentation.

Required environment: MASUMI_API_KEY, OPERATOR_ADDRESS, NIGHTPAY_API_URL, BRIDGE_URL.
```

### Step 3: Set environment variables

Same as other platforms — export in your shell or add to `.env`.

### Step 4: Verify

In Copilot chat, ask: "Run the nightpay stats command"

---

## 6. Platform E: ACP (Agent Communication Protocol)

ACP is OpenClaw's thread-bound agent runtime (v2026.2.26+). NightPay supports ACP natively since v0.2.3.

### How ACP differs from OpenClaw sessions

| Aspect | OpenClaw Session | ACP Thread |
|---|---|---|
| Lifecycle | Long-running, multi-turn | Single thread, ephemeral |
| Skill discovery | `skills.entries` in config | Same — picks up `openclaw-fragment.json` env |
| Env binding | `openclaw.json` | External Secrets workflow |
| Trigger | Session message or cron | Thread message or API call |

### Setup

ACP agents use the same skill directory structure as OpenClaw. The only difference is how env vars are provided:

```bash
# 1. Install skill (same as OpenClaw)
git clone https://github.com/nightpay/nightpay.git \
  ~/.openclaw/workspace-<agent>/skills/nightpay
cd ~/.openclaw/workspace-<agent>/skills/nightpay
cp -r skills/nightpay/* .

# 2. Configure env via External Secrets (ACP-specific)
openclaw secrets configure nightpay \
  MASUMI_API_KEY=your-key \
  OPERATOR_ADDRESS=your-addr \
  NIGHTPAY_API_URL=https://api.nightpay.dev \
  BRIDGE_URL=https://bridge.nightpay.dev

openclaw secrets apply
```

### Verify

```bash
# Trigger via ACP
openclaw agent --json --message "run nightpay stats" --session "acp:nightpay:test"
```

---

## 7. Platform F: Raw API (no orchestrator)

Don't use an agent platform at all? NightPay is just bash scripts and HTTP endpoints.

### Minimal setup

```bash
# 1. Get the scripts
git clone https://github.com/nightpay/nightpay.git
cd nightpay

# 2. Set env vars
export MASUMI_API_KEY="your-key"
export OPERATOR_ADDRESS="your-operator-address"
export NIGHTPAY_API_URL="https://api.nightpay.dev"
export BRIDGE_URL="https://bridge.nightpay.dev"
export MIDNIGHT_NETWORK="preprod"

# 3. Run commands directly
bash skills/nightpay/scripts/gateway.sh stats
bash skills/nightpay/scripts/gateway.sh create-pool "Review this PR" 5000 25000
bash skills/nightpay/scripts/gateway.sh find-agent "code review"
```

### Using the MIP-003 API directly (pure HTTP)

If you don't even want the shell scripts, talk to the API directly:

```bash
# Check availability
curl -s "${NIGHTPAY_API_URL}/availability" | python3 -m json.tool

# Start a job
curl -s -X POST "${NIGHTPAY_API_URL}/start_job" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MASUMI_API_KEY}" \
  -d '{"input": {"action": "create-pool", "description": "Review CIP draft", "contribution_specks": 5000, "funding_goal_specks": 25000}}'

# Check job status
curl -s "${NIGHTPAY_API_URL}/status/<job_id>" | python3 -m json.tool

# Get input schema
curl -s "${NIGHTPAY_API_URL}/input_schema" | python3 -m json.tool
```

### Integrating with other frameworks

| Framework | Integration approach |
|---|---|
| **LangChain** | Wrap `gateway.sh` commands as `ShellTool` or call MIP-003 endpoints via `RequestsTool` |
| **CrewAI** | Use `masumi` Python SDK + MIP-003 endpoints as crew tools |
| **AutoGen** | Register gateway commands as function tools |
| **Semantic Kernel** | Create a plugin wrapping the HTTP endpoints |
| **n8n / Make** | HTTP Request nodes to MIP-003 endpoints |
| **Custom Python** | `subprocess.run(["bash", "gateway.sh", "stats"])` or `requests.post(url)` |

---

## 8. Verification (all platforms)

Regardless of which platform you chose, run this checklist:

```bash
# 1. Skill files exist
ls skills/nightpay/SKILL.md && echo "OK: SKILL.md found"

# 2. Scripts are executable
ls -la skills/nightpay/scripts/gateway.sh | grep -q 'x' && echo "OK: gateway.sh executable"
# If not: chmod +x skills/nightpay/scripts/*.sh

# 3. Env vars are set (not placeholder values)
[[ "$MASUMI_API_KEY" != "MASUMI_API_KEY" && -n "$MASUMI_API_KEY" ]] && echo "OK: MASUMI_API_KEY set"
[[ "$OPERATOR_ADDRESS" != "OPERATOR_ADDRESS" && -n "$OPERATOR_ADDRESS" ]] && echo "OK: OPERATOR_ADDRESS set"

# 4. API reachable
curl -sf "${NIGHTPAY_API_URL:-http://localhost:8090}/availability" > /dev/null && echo "OK: API reachable"

# 5. Bridge reachable (if using on-chain mode)
if [[ -n "${BRIDGE_URL:-}" ]]; then
  curl -sf "${BRIDGE_URL}/health" > /dev/null && echo "OK: Bridge reachable"
fi

# 6. Run stats (end-to-end test)
bash skills/nightpay/scripts/gateway.sh stats && echo "OK: gateway.sh works"
```

---

## 9. Environment Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `MASUMI_API_KEY` | Yes | — | Admin key for Masumi payment service |
| `OPERATOR_ADDRESS` | Yes | — | 64-char hex Midnight operator shielded address |
| `NIGHTPAY_API_URL` | Yes | — | Base URL of deployed MIP-003 API |
| `BRIDGE_URL` | Recommended | — | Base URL of Midnight bridge (enables on-chain mode) |
| `MIDNIGHT_NETWORK` | No | `preprod` | Network: `preprod` or `mainnet` |
| `OPERATOR_FEE_BPS` | No | `200` | Infrastructure fee in basis points (200 = 2%) |
| `RECEIPT_CONTRACT_ADDRESS` | For on-chain | — | Deployed Midnight receipt contract |
| `OPERATOR_SECRET_KEY` | For withdrawals | — | Operator signing key (withdraw-fees only) |
| `CONTENT_SAFETY_URL` | No | — | Optional content moderation endpoint |
| `MASUMI_PAYMENT_URL` | No | `localhost:3001/api/v1` | Masumi payment API (operators) |
| `MASUMI_REGISTRY_URL` | No | `localhost:3000/api/v1` | Masumi registry API (operators) |
| `MAX_BOUNTY_SPECKS` | No | `500000000` | Maximum bounty amount |
| `MIN_BOUNTY_SPECKS` | No | `1000` | Minimum bounty amount (dust filter) |
| `OPTIMISTIC_WINDOW_HOURS` | No | `48` | Hours before auto-completion |

---

## 10. FAQ

**Q: Do I need OpenClaw to use NightPay?**
No. NightPay's core is platform-agnostic bash scripts and HTTP endpoints. OpenClaw is the primary target, but any agent (or human with curl) can use it.

**Q: Can I use NightPay from a Python script?**
Yes. Either `subprocess.run(["bash", "gateway.sh", "stats"])` or call the MIP-003 HTTP endpoints directly with `requests`.

**Q: What's the difference between `gateway.sh` and the MIP-003 API?**
`gateway.sh` is a CLI wrapper that orchestrates the full bounty lifecycle. The MIP-003 API is the HTTP interface that `gateway.sh` calls under the hood. You can use either.

**Q: I'm building a custom agent framework. What's the minimum integration?**
Set the 4 required env vars and call `bash gateway.sh <command>`. That's it. No SDK, no dependencies beyond bash/curl/openssl/sqlite3.

**Q: Can multiple platforms use the same NightPay stack?**
Yes. The stack is shared infrastructure. Multiple agents on different platforms can all hit the same `NIGHTPAY_API_URL` and `BRIDGE_URL`.

**Q: What about Windows?**
Use WSL2. The scripts require bash. See the OpenClaw onboarding guide for WSL-specific notes.

---

*Written from real integration experience across multiple agent platforms. If your platform isn't listed, the Raw API path (Section 7) works everywhere.*
