# OpenClaw Agent Onboarding Guide

> Real-world, step-by-step guide for onboarding NightPay as an OpenClaw agent.
> Written from an actual installation session — includes what worked, what didn't,
> and how to get from zero to a running NightPay agent in under 10 minutes.

## Prerequisites

| Requirement | Why |
|---|---|
| OpenClaw installed and gateway running | Agent host |
| `git` | Clone the skill repo |
| `bash`, `curl`, `openssl`, `sqlite3`, `sha256sum` | Required by NightPay scripts |
| Masumi API key + operator credentials | Payment settlement |
| Midnight preprod wallet (funded with NIGHT + DUST) | ZK proofs + on-chain settlement |

Verify OpenClaw is healthy before starting:

```bash
openclaw status --all
openclaw config validate
```

---

## Installation Paths

NightPay supports four installation methods. **Pick one.**

### Path A: ClawHub (Recommended)

```bash
clawhub install nightpay
```

If you want it scoped to a specific agent:

```bash
clawhub install nightpay --workspace ~/.openclaw/workspace-nightpay
```

**Pros:** Handles directory structure automatically, versioned updates via `clawhub update`.
**Cons:** Requires ClawHub CLI (`npx clawhub` or global install).

### Path B: npx init

```bash
npx nightpay init
```

Copies the skill into `./skills/nightpay/` relative to your current directory.

### Path C: Git Clone (Manual)

> **This is the path documented below in detail**, since it is what most developers
> reach for first and has the most gotchas.

```bash
git clone https://github.com/nightpay/nightpay.git <target-dir>
```

### Path D: Masumi Service Registration

For agent-to-agent discovery (advanced). See README.md.

---

## Path C Walkthrough: Git Clone (Full Manual Install)

### Step 1 — Create the OpenClaw agent

```bash
openclaw agents add nightpay
```

This launches an interactive TUI. Accept the default workspace
(`~/.openclaw/workspace-nightpay`) or specify your own.

> **Automation note:** As of March 2026, `openclaw agents add` has no
> `--non-interactive` flag. If you need to script this, add the agent entry
> directly to `openclaw.json`:
>
> ```python
> import json
> with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
>     config = json.load(f)
> config["agents"]["list"].append({
>     "id": "nightpay",
>     "name": "nightpay",
>     "workspace": "~/.openclaw/workspace-nightpay",
>     "model": { "primary": "openai/gpt-5.1-codex-mini" }
> })
> with open(os.path.expanduser("~/.openclaw/openclaw.json"), "w") as f:
>     json.dump(config, f, indent=2)
> ```
>
> Always run `openclaw config validate` after manual config edits.

### Step 2 — Clone into the workspace skills directory

```bash
git clone https://github.com/nightpay/nightpay.git \
  ~/.openclaw/workspace-nightpay/skills/nightpay
```

### Step 3 — Flatten the skill directory (CRITICAL)

**This is the step most people miss.** The repo nests the actual OpenClaw skill
one level deep:

```
# What git clone gives you:
workspace-nightpay/skills/nightpay/          # repo root
  README.md
  package.json
  skills/
    nightpay/                                 # <-- actual skill is HERE
      SKILL.md                                # <-- OpenClaw looks for this
      scripts/
      rules/
      ontology/
      openclaw-fragment.json

# What OpenClaw expects:
workspace-nightpay/skills/nightpay/
  SKILL.md                                    # <-- must be at THIS level
  scripts/
  rules/
  ...
```

**Fix:** Copy the inner skill contents up to the repo root level:

```bash
cp -r ~/.openclaw/workspace-nightpay/skills/nightpay/skills/nightpay/* \
      ~/.openclaw/workspace-nightpay/skills/nightpay/
```

After this, both the repo files (README, package.json, .git) and the skill files
(SKILL.md, scripts/, rules/) coexist at the same level. This is fine — OpenClaw
only looks for `SKILL.md`.

**Verify:**

```bash
ls ~/.openclaw/workspace-nightpay/skills/nightpay/SKILL.md
# Should exist and be ~17KB
```

> **Why does the repo nest skills?** The `skills/nightpay/` structure is the
> ClawHub packaging convention. `clawhub install` and `npx nightpay init` both
> handle the extraction automatically. Raw `git clone` does not.

### Step 4 — Make scripts executable

```bash
chmod +x ~/.openclaw/workspace-nightpay/skills/nightpay/scripts/*.sh
```

### Step 5 — Merge the config fragment

The repo ships `openclaw-fragment.json` with the skill entry and placeholder
env vars. Merge it into your main config:

```bash
python3 -c "
import json

with open('\$HOME/.openclaw/openclaw.json') as f:
    config = json.load(f)

with open('\$HOME/.openclaw/workspace-nightpay/skills/nightpay/openclaw-fragment.json') as f:
    fragment = json.load(f)

config.setdefault('skills', {}).setdefault('entries', {})
config['skills']['entries']['nightpay'] = fragment['skills']['entries']['nightpay']

with open('\$HOME/.openclaw/openclaw.json', 'w') as f:
    json.dump(config, f, indent=2)

print('Merged nightpay skill entry into openclaw.json')
"
```

Or manually copy the `skills.entries.nightpay` block from `openclaw-fragment.json`
into your `openclaw.json`.

### Step 6 — Configure environment variables

The fragment sets placeholder values. Replace them with real credentials:

```bash
openclaw config set skills.entries.nightpay.env.MASUMI_API_KEY "<your-key>"
openclaw config set skills.entries.nightpay.env.NIGHTPAY_API_URL "https://api.nightpay.dev"
openclaw config set skills.entries.nightpay.env.BRIDGE_URL "https://bridge.nightpay.dev"
openclaw config set skills.entries.nightpay.env.OPERATOR_ADDRESS "<64-char-hex>"
openclaw config set skills.entries.nightpay.env.RECEIPT_CONTRACT_ADDRESS "<64-char-hex>"
openclaw config set skills.entries.nightpay.env.OPERATOR_SECRET_KEY "<your-secret>"
openclaw config set skills.entries.nightpay.env.MIDNIGHT_NETWORK "preprod"
openclaw config set skills.entries.nightpay.env.OPERATOR_FEE_BPS "200"
```

> **Security note:** For production, consider migrating these to the OpenClaw
> secrets vault (`openclaw secrets configure`) instead of plaintext env vars.

### Step 7 — Validate and bind

```bash
openclaw config validate
openclaw agents bind nightpay telegram <chat_id>
openclaw agents list
openclaw agents bindings
```

### Step 8 — Test

Send a message to the bound channel mentioning "bounty", "nightpay", or
"create a pool" — the skill should activate.

---

## Environment Variables Reference

| Variable | Required | Description | Example |
|---|---|---|---|
| `MASUMI_API_KEY` | Yes | Masumi payment API key | `msk_...` |
| `NIGHTPAY_API_URL` | Yes | MIP-003 API base URL | `https://api.nightpay.dev` |
| `BRIDGE_URL` | Yes* | Midnight bridge endpoint | `https://bridge.nightpay.dev` |
| `OPERATOR_ADDRESS` | Yes | 64-char hex operator address | `a1b2c3...` |
| `RECEIPT_CONTRACT_ADDRESS` | Yes | 64-char hex contract address | `d4e5f6...` |
| `OPERATOR_SECRET_KEY` | Yes | Operator secret for auth | (random) |
| `MIDNIGHT_NETWORK` | Yes | Network target | `preprod` or `mainnet` |
| `OPERATOR_FEE_BPS` | No | Fee in basis points (default 200 = 2%) | `200` |
| `DEFAULT_POOL_DEADLINE_HOURS` | No | Pool funding window (default 72h) | `72` |
| `CONTENT_SAFETY_URL` | No | External content safety API | (optional) |
| `JOB_TOKEN_SECRET` | No | Secret for signing job tokens | (random) |
| `UNCLAIMED_REFUND_HOURS` | No | Hours before unclaimed refunds sweep | `24` |
| `MIP003_MODE` | No | `compat` (default) or `strict` | `compat` |
| `ONTOLOGY_DIR` | No | Path to ontology files | `./skills/nightpay/ontology` |

*`BRIDGE_URL` can be empty for stub mode (no on-chain transactions).

---

## Post-Install Verification Checklist

```bash
# 1. Config is valid
openclaw config validate
# Expected: "Config valid"

# 2. Agent is registered
openclaw agents list --json | python3 -c "
import sys, json
agents = json.load(sys.stdin)
np = [a for a in agents if a['id'] == 'nightpay']
print('PASS' if np else 'FAIL: nightpay agent not found')
if np: print(json.dumps(np[0], indent=2))
"

# 3. SKILL.md is at the right path
ls -la ~/.openclaw/workspace-nightpay/skills/nightpay/SKILL.md
# Expected: file exists, ~17KB

# 4. Scripts are executable
ls -la ~/.openclaw/workspace-nightpay/skills/nightpay/scripts/gateway.sh
# Expected: -rwxr-xr-x

# 5. Config fragment merged
openclaw config get skills.entries.nightpay.enabled
# Expected: true

# 6. Channel binding exists (after binding)
openclaw agents bindings | grep nightpay
```

---

## Common Issues

### "SKILL.md not found" / Skill not activating

**Cause:** Git clone nests the skill at `skills/nightpay/skills/nightpay/SKILL.md`.
**Fix:** Run the flatten step (Step 3 above).

### Agent added but not visible in `openclaw agents list`

**Cause:** Manual JSON edit had a syntax error.
**Fix:** `openclaw config validate` — fix any reported errors, or restore from backup:
```bash
cp ~/.openclaw/openclaw.json.bak.1 ~/.openclaw/openclaw.json
```

### Env vars are placeholder strings, not real values

**Cause:** `openclaw-fragment.json` sets `"MASUMI_API_KEY": "MASUMI_API_KEY"` as
a placeholder. If you merged without replacing, the skill gets the literal string.
**Fix:** Set each var with `openclaw config set skills.entries.nightpay.env.MASUMI_API_KEY "<real-value>"`

### `openclaw agents add` hangs in CI/scripts

**Cause:** Interactive TUI with no `--non-interactive` flag.
**Fix:** Add the agent entry via direct JSON manipulation (see Step 1 automation note).

### Permission denied on gateway.sh

**Cause:** Scripts not marked executable after clone.
**Fix:** `chmod +x ~/.openclaw/workspace-nightpay/skills/nightpay/scripts/*.sh`

---

## Updating

### Via ClawHub (if installed that way)

```bash
clawhub update nightpay
```

### Via Git (if cloned manually)

```bash
cd ~/.openclaw/workspace-nightpay/skills/nightpay
git pull origin main
# Re-flatten if the inner skill structure changed:
cp -r skills/nightpay/* .
chmod +x scripts/*.sh
```

---

## Uninstalling

```bash
# Remove agent
openclaw agents delete nightpay

# Remove skill entry from config
openclaw config unset skills.entries.nightpay

# Remove workspace (optional — keeps data if you want to reinstall later)
rm -rf ~/.openclaw/workspace-nightpay
```
