# OpenClaw Agent Onboarding Guide

> Step-by-step guide for installing NightPay on OpenClaw.
> Three paths: plugin install (recommended), npx init, or git clone (advanced).

## Prerequisites

| Requirement | Why |
|---|---|
| OpenClaw installed and gateway running | Agent host |
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

| Path | Command | Skill auto-discovered? | Fragment merge needed? |
|------|---------|:---:|:---:|
| **A: Plugin install** (recommended) | `openclaw plugins install` + `enable` | ✅ | ❌ |
| **B: npx init** | `npx nightpay init` | ❌ (workspace copy) | ✅ |
| **C: ClawHub** | `clawhub install nightpay` | ✅ | ❌ |
| **D: Git clone** (advanced) | `git clone` + flatten | ❌ | ✅ |

---

## Path A: Plugin Install (Recommended)

The cleanest path. Skill files live inside the installed npm package — OpenClaw auto-discovers them.

### Step 1 — Install the plugin package

```bash
openclaw plugins install nightpay
```

This copies the package to `~/.openclaw/extensions/nightpay/`. The install step may print a
config-write warning — that's expected; the next step handles it.

### Step 2 — Enable the plugin

```bash
openclaw plugins enable nightpay
```

This registers the plugin and adds `nightpay` to `plugins.allow`. Verify:

```bash
openclaw plugins list
# Expected: NightPay | nightpay | loaded
```

### Step 3 — Set credentials

```bash
openclaw config set skills.entries.nightpay.env.MASUMI_API_KEY "your-masumi-api-key"
openclaw config set skills.entries.nightpay.env.OPERATOR_ADDRESS "your-64-char-hex"
openclaw config set skills.entries.nightpay.env.BRIDGE_URL "https://bridge.nightpay.dev"
# NIGHTPAY_API_URL defaults to https://api.nightpay.dev — skip unless self-hosting
openclaw config set skills.entries.nightpay.env.MIDNIGHT_NETWORK "preprod"
openclaw config set skills.entries.nightpay.env.OPERATOR_FEE_BPS "200"
```

For production: consider migrating secrets to the vault:
```bash
openclaw secrets configure
```

### Step 4 — Restart and verify

```bash
openclaw gateway restart
openclaw config validate
openclaw plugins list              # NightPay: loaded
```

Test with `/nightpay status` in your connected channel — should return API URL + network.

### Step 5 — (Optional) Bind to a channel

```bash
openclaw agents bind main telegram <chat_id>
```

Or create a dedicated agent:
```bash
openclaw agents add nightpay
openclaw agents bind nightpay telegram <chat_id>
```

---

## Path B: npx init + Fragment Merge

Use this when you want skill files in a specific workspace directory.

```bash
# 1. Install skill files into your workspace
cd ~/.openclaw/workspace-<agent>
npx nightpay init
# -> Creates ./skills/nightpay/

# 2. Merge config fragment
python3 -c "
import json, os

cfg = os.path.expanduser('~/.openclaw/openclaw.json')
frag = os.path.expanduser('~/.openclaw/workspace-<agent>/skills/nightpay/openclaw-fragment.json')

with open(cfg) as f: config = json.load(f)
with open(frag) as f: fragment = json.load(f)

config.setdefault('skills', {}).setdefault('entries', {})
config['skills']['entries']['nightpay'] = fragment['skills']['entries']['nightpay']

with open(cfg, 'w') as f: json.dump(config, f, indent=2)
print('Merged')
"

# 3. Set real credentials (fragment has empty placeholders)
openclaw config set skills.entries.nightpay.env.MASUMI_API_KEY "your-key"
openclaw config set skills.entries.nightpay.env.OPERATOR_ADDRESS "64-char-hex"
openclaw config set skills.entries.nightpay.env.BRIDGE_URL "https://bridge.nightpay.dev"

# 4. Validate and restart
openclaw config validate
openclaw gateway restart
```

---

## Path C: ClawHub

```bash
clawhub install nightpay
# Or scoped to a specific agent workspace:
clawhub install nightpay --workspace ~/.openclaw/workspace-nightpay
```

ClawHub handles directory structure and versioning automatically.
Update later: `clawhub update nightpay`

---

## Path D: Git Clone (Advanced)

> Use only for development/contribution. For production installs, use Path A or B.

```bash
# 1. (Optional) Create a dedicated agent
openclaw agents add nightpay

# 2. Clone into workspace
git clone https://github.com/nightpay/nightpay.git \
  ~/.openclaw/workspace-nightpay/skills/nightpay

# 3. CRITICAL: Flatten — git clone nests the skill one level deep
cp -r ~/.openclaw/workspace-nightpay/skills/nightpay/skills/nightpay/* \
      ~/.openclaw/workspace-nightpay/skills/nightpay/
chmod +x ~/.openclaw/workspace-nightpay/skills/nightpay/scripts/*.sh

# 4. Verify flatten worked
ls ~/.openclaw/workspace-nightpay/skills/nightpay/SKILL.md
# Expected: file exists

# 5. Merge config fragment (same as Path B Step 2 above)
# 6. Set real env values
# 7. openclaw config validate && openclaw gateway restart
```

---

## Environment Variables Reference

| Variable | Required | Default | Description |
|---|---|---|---|
| `MASUMI_API_KEY` | Yes | — | Masumi payment API key |
| `NIGHTPAY_API_URL` | Yes | `https://api.nightpay.dev` | MIP-003 API base URL |
| `BRIDGE_URL` | Yes* | — | Midnight bridge endpoint |
| `OPERATOR_ADDRESS` | Yes | — | 64-char hex operator address |
| `RECEIPT_CONTRACT_ADDRESS` | No | — | 64-char hex contract address |
| `OPERATOR_SECRET_KEY` | No | — | Operator secret for auth |
| `MIDNIGHT_NETWORK` | No | `preprod` | `preprod` or `mainnet` |
| `OPERATOR_FEE_BPS` | No | `200` | Fee in basis points (default 2%) |
| `DEFAULT_POOL_DEADLINE_HOURS` | No | `72` | Pool funding window |
| `CONTENT_SAFETY_URL` | No | — | External content safety API |

*`BRIDGE_URL` can be empty for stub mode (no on-chain transactions).

---

## Verification Checklist

```bash
# 1. Config valid
openclaw config validate

# 2. Plugin loaded (Path A/C)
openclaw plugins list | grep nightpay
# Expected: NightPay | nightpay | loaded

# 3. Skill active (Path B/D)
ls ~/.openclaw/workspace-<agent>/skills/nightpay/SKILL.md

# 4. Env configured
openclaw config get skills.entries.nightpay.env.MASUMI_API_KEY
# Expected: non-empty, not placeholder

# 5. API reachable
curl -sf "${NIGHTPAY_API_URL:-https://api.nightpay.dev}/availability" | python3 -m json.tool

# 6. /nightpay status command works (in connected channel)
# Expected: "✅ NightPay ready — API: https://api.nightpay.dev"
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `plugins install` prints config-write warning | Expected — the allowlist write fails before enable runs | Run `openclaw plugins enable nightpay` immediately after |
| `SKILL.md not found` / skill not activating | Git clone nests skill at wrong depth | Run the flatten step (Path D Step 3) |
| Env vars are placeholder strings | `openclaw-fragment.json` applied without setting real values | `openclaw config set skills.entries.nightpay.env.<KEY> "real-value"` |
| `openclaw agents add` hangs | Interactive TUI, no `--non-interactive` flag | Add agent entry via direct JSON edit + `openclaw config validate` |
| Permission denied on gateway.sh | Scripts not executable | `chmod +x ~/.openclaw/workspace-.../skills/nightpay/scripts/*.sh` |

---

## Updating

```bash
# Plugin path (A)
openclaw plugins uninstall nightpay
openclaw plugins install nightpay
openclaw plugins enable nightpay

# npx path (B)
cd ~/.openclaw/workspace-<agent>
npx nightpay init   # re-runs init, updates skill files in place

# ClawHub path (C)
clawhub update nightpay

# Git clone path (D)
cd ~/.openclaw/workspace-nightpay/skills/nightpay
git pull origin main
cp -r skills/nightpay/* .
chmod +x scripts/*.sh
```

---

## Uninstalling

```bash
# Plugin path
openclaw plugins disable nightpay
openclaw plugins uninstall nightpay
openclaw config unset skills.entries.nightpay

# Workspace path
openclaw config unset skills.entries.nightpay
rm -rf ~/.openclaw/workspace-<agent>/skills/nightpay

# Remove dedicated agent (if created)
openclaw agents delete nightpay
```
