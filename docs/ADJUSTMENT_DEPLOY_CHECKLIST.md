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

## 2.1) One-time setup for auto-deploy on push to `master` (and `main`)

This repo now includes workflow: `.github/workflows/deploy-hetzner.yml`.

Configure these in GitHub before relying on auto-deploy:

- **Repository secrets**
  - `HETZNER_HOST` (for example `static.<ip>.clients.your-server.de`)
  - `HETZNER_SSH_KEY` (private key content, e.g. `hetzner_ed25519_martin`)
  - `HETZNER_KNOWN_HOSTS` (optional but recommended; `known_hosts` entry)
  - `HETZNER_SSH_PORT` (optional, default `22`)
  - `NIGHTPAY_UI_REPO_TOKEN` (required; fine-grained PAT with read access to `nightpay/nightpay-ui` and `nightpay/nightpay-bridge`)
  - `NIGHTPAY_BRIDGE_REPO_TOKEN` (optional override for bridge submodule; falls back to `NIGHTPAY_UI_REPO_TOKEN`; you can use the same token value in both secrets)
- **Repository variables** (optional overrides)
  - `HETZNER_REMOTE_DIR` (default `/opt/nightpay`)
  - `HETZNER_BRIDGE_DIR` (default `/opt/nightpay-bridge`)
  - `HETZNER_MASUMI_DIR` (default `/opt/masumi-services-dev-quickstart`)
  - `HETZNER_SITE_URL` (default `https://nightpay.dev/`)
  - `HETZNER_BOARD_URL` (default `https://board.nightpay.dev/`)
  - `HETZNER_API_URL` (default `https://api.nightpay.dev/availability`)
  - `HETZNER_BRIDGE_URL` (default `https://bridge.nightpay.dev/health`)

After these are set, every push to `master` (or `main`) triggers deploy + Docker recreate + health checks.
Submodule token checks are fail-fast: deploy now stops immediately if `ui` or `bridge` private repo access is missing.
Production now has a mandatory web gate: deploy fails unless site/board/api/bridge URLs are healthy.

## 2.2) Optional staging auto-deploy (`staging` branch)

Workflow: `.github/workflows/deploy-hetzner-staging.yml`

Behavior:
- Push to `staging` deploys into an isolated app directory (default `/opt/nightpay-staging`)
- Staging defaults to ports `3334` (UI) + `8091` (MIP)
- Staging skips proof/Masumi container recreation by default so production services are not touched

Optional staging-specific secrets (fallbacks to production secrets when omitted):

- `HETZNER_STAGING_HOST`
- `HETZNER_STAGING_SSH_KEY`
- `HETZNER_STAGING_KNOWN_HOSTS`
- `HETZNER_STAGING_SSH_PORT`

Optional staging variables:

- `HETZNER_STAGING_REMOTE_DIR` (default `/opt/nightpay-staging`)
- `HETZNER_STAGING_UI_PORT` (default `3334`)
- `HETZNER_STAGING_MIP_PORT` (default `8091`)
- `HETZNER_STAGING_SITE_URL` (**required** for staging web gate)
- `HETZNER_STAGING_BOARD_URL` (**required** for staging web gate)
- `HETZNER_STAGING_API_URL` (**required** for staging web gate)
- `HETZNER_STAGING_BRIDGE_URL` (**required** for staging web gate)

Staging now has a mandatory web gate: deploy fails unless all four staging URLs return healthy responses.

## 3) Manual deploy fallback (SSH server)

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
- pushes `main` to GitHub
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
npx skills-ref validate ./skills/nightpay
# Keep versions aligned
# - package.json version
# - skills/nightpay/SKILL.md frontmatter version
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
