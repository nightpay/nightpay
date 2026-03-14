# Adjustment Checklist: GitHub -> SSH Deploy -> npm (When Needed)

Use this every time you adjust NightPay behavior (UI, gateway, MIP-003 flows, contract wiring).

## 1) Validate locally

Run the checks that match your change scope:

```bash
# UI changes
npm run build --prefix ui

# Gateway / MIP lifecycle changes
bash test/smoke.sh

# Contract safety scan (before any deployment)
compact-security-detectors scan skills/nightpay/contracts/receipt.compact
```

## 2) Commit and push to GitHub

```bash
git add <changed-files>
git commit -m "Describe adjustment"
git push origin master
```

## 3) Deploy the pushed commit to SSH server

Fast path (existing server already bootstrapped):

```bash
bash .private/deploy-nightpay-hetzner.sh <HOST> ./hetzner_ed25519_martin
```

PowerShell alternative (recommended on Windows for clearer step output):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/deploy-nightpay-hetzner.ps1 `
  -HostName <HOST> `
  -KeyPath .\hetzner_ed25519_martin
```

What this does:
- pushes `master` to GitHub
- syncs the latest tracked commit to `/opt/nightpay`
- normalizes line endings for `.sh`/`.compact`
- restarts services and runs `doctor`
- checks MIP and bridge health
- refuses deploy from dirty working tree unless explicitly bypassed
- backs up remote env files before sync

## 4) Post-deploy verification

```bash
ssh -i ./hetzner_ed25519_martin root@<HOST>
su - deploy
cd /opt/nightpay
bash scripts/agent-playground-setup.sh doctor
curl -sS http://localhost:8090/availability
curl -sS http://localhost:4000/health
```

## 5) npm publish (only when distribution artifacts changed)

Publish only if users need new installable package/skill behavior.

Publish is required when you change:
- `package.json` versioned package behavior (CLI/install flow)
- skill packaging/install output used by `npx nightpay init`
- `skills/nightpay/SKILL.md` metadata/version for distribution

Before publish:

```bash
bash test/smoke.sh
npx @agentskills/skills-ref validate ./skills/nightpay
# Keep versions aligned
# - package.json version
# - skills/nightpay/SKILL.md metadata version
npm publish
```

Do not publish for server-only changes that do not affect npm-distributed artifacts.

## 6) Mandatory bundle for refund/discovery/dispute flow edits

When adjusting 5/6/7 lifecycle paths, update together:
1. `skills/nightpay/scripts/gateway.sh`
2. `skills/nightpay/scripts/mip003-server.sh`
3. `test/smoke.sh`
4. `README.md` runbook section

This keeps operator behavior, API behavior, and regression coverage in sync.
