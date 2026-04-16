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
  - `REPO_NIGHTPAY_UI_REPO_TOKEN` (optional but preferred fallback when environment secrets are not manageable)
  - `REPO_NIGHTPAY_BRIDGE_REPO_TOKEN` (optional but preferred fallback when environment secrets are not manageable)
  - `NIGHTPAY_UI_REPO_TOKEN` (required; fine-grained PAT with read access to `nightpay/nightpay-ui` and `nightpay/nightpay-bridge`)
  - `NIGHTPAY_BRIDGE_REPO_TOKEN` (optional override for bridge submodule; each submodule now prefers its own secret and falls back to the other one; you can use the same token value in both secrets)
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
Masumi internal ports are now enforced as private-only: deploy forces service and DB mappings to `127.0.0.1` and fails if `3000/3001/13000/13001/5432/5433/15432/15433` are publicly bound.

## 2.2) Optional staging auto-deploy (`staging` branch)

Workflow: `.github/workflows/deploy-hetzner-staging.yml`

Behavior:
- Push to `staging` deploys into an isolated app directory (default `/opt/nightpay-staging`)
- Staging defaults to ports `3334` (UI) + `8091` (MIP)
- Staging skips bridge sync/restart by default so production bridge deploy path is not contended
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
- `HETZNER_STAGING_SITE_URL` (optional; default `https://staging.nightpay.dev/`)
- `HETZNER_STAGING_BOARD_URL` (optional; default `https://staging.nightpay.dev/`)
- `HETZNER_STAGING_API_URL` (optional; default `https://api.staging.nightpay.dev/availability`)
- `HETZNER_STAGING_BRIDGE_URL` (optional; default `https://bridge.nightpay.dev/health`)

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

## 6) Shipping work from a sync / working branch into production via CI

Use this flow when your changes live on a non-default branch (for example `push-sync`, feature branches, or the output of a local edit session) and you want them deployed through **`.github/workflows/deploy-hetzner.yml`** instead of tar-uploading from your laptop. The workflow only fires on pushes to **`master`** (prod), **`main`** (prod alias), or **`staging`** (staging); any other branch sits on GitHub but does nothing on Hetzner.

### 6.1) Pre-flight: is the sync branch ahead of origin?

```bash
git fetch origin
git log --oneline origin/master..<your-branch>   # commits you want to ship
git log --oneline <your-branch>..origin/master   # commits on origin you might be missing
git merge-base <your-branch> origin/master       # common ancestor
```

Interpret the result:
- **Second query empty** -> `<your-branch>` is a clean fast-forward; merge is trivial.
- **Second query non-empty but short** -> origin has drifted (often a prior PR-merge commit); a regular merge will reconcile.
- **Local `master` is ahead/behind `origin/master`** -> someone rewrote history on origin (backup branches with names like `backup/master-before-onecommit-*` or `truncate/master-*` are the tell). Hard-reset local `master` to `origin/master` before merging.

### 6.2) Reconcile local `master`, then merge the sync branch

```bash
git checkout master
git reset --hard origin/master         # only after confirming drift is intentional
git merge <your-branch> --no-ff -m "Merge <your-branch>: <what it brings>"
git submodule status                   # confirm ui/bridge pointers match what you want deployed
git log --oneline --graph -n 10        # sanity check
```

### 6.3) Push and verify CI

```bash
git push origin master
```

Verification path without `gh auth`:

```bash
# Latest Deploy Hetzner runs (unauthenticated; works for public repos)
curl -sS "https://api.github.com/repos/nightpay/nightpay/actions/runs?branch=master&per_page=3" \
  | grep -E '"(status|conclusion|display_title|html_url|head_sha)"'

# Per-job step breakdown for one run
curl -sS "https://api.github.com/repos/nightpay/nightpay/actions/runs/<run_id>/jobs" \
  | grep -E '"(name|status|conclusion)"'
```

The production job must pass **every** step for the deploy to be considered green:

| Step | What it guards |
|---|---|
| Checkout | Workflow file itself + `bin/` helpers |
| Prepare SSH | `HETZNER_SSH_KEY` + `HETZNER_KNOWN_HOSTS` secrets are present |
| Checkout Private Submodules | `NIGHTPAY_UI_REPO_TOKEN` / `NIGHTPAY_BRIDGE_REPO_TOKEN` can clone `ui/` and `bridge/` |
| Deploy To Hetzner | `bin/deploy-hetzner-ci.sh` completed: rsync, npm install, `npm run build` for `ui/`, Caddy perms fix, restart, doctor |
| Validate Web Endpoints (Production Gate) | `bin/validate-web-endpoints.sh` got `200` from `nightpay.dev/`, `board.nightpay.dev/`, `api.nightpay.dev/availability`, `bridge.nightpay.dev/health` |

### 6.4) Manual tar-sync fallback (same thing, without CI)

If CI secrets are broken or you need the change live *now* and can accept a scrubbed audit trail, `scripts/server-sync-start.ps1` / `.sh` performs the same steps locally: tar the working tree, scp, extract, `npm install` + `npm run build`, restart services, run `doctor`. This path was used for the `2026-04-16` UI refactor while CI was green but the production gate was failing on a pre-existing Caddy perm bug. The tar path also triggers the same CRLF and perm footguns called out in §6.5 below, so prefer CI unless you have a reason.

## 7) CI production gate troubleshooting

Symptoms and root causes actually observed on this repo.

### 7.1) `Validate Web Endpoints (Production Gate)` fails with 403 on `nightpay.dev` / `board.nightpay.dev`

**What the gate is checking:** `bin/validate-web-endpoints.sh` runs four `curl` checks and requires all four to return `200`. Site and board are served by Caddy as **static files from `/opt/nightpay/ui/dist/`** (see `docs/architecture.md` Caddy multisite table). `403` means Caddy answered the request but the backend refused.

**Three things must simultaneously be true for those URLs to return 200:**

1. `/opt/nightpay/ui/dist/index.html` **exists**. It's created by `npm run build` inside `ui/`.
2. `/opt/nightpay` itself must be **traversable by the `caddy` OS user**. Default mode after `tar -xf` is `drwx------` (owner `deploy`, caddy can't enter) -> 403.
3. `/opt/nightpay/ui/dist/` and its contents must be **readable by caddy** (file-level `o+r`).

**One-line diagnostic (run on the server):**

```bash
stat -c '%A %U:%G %n' /opt/nightpay /opt/nightpay/ui /opt/nightpay/ui/dist /opt/nightpay/ui/dist/index.html
```

If `/opt/nightpay` starts with `drwx------`, that's the bug. Fix:

```bash
chmod o+rx /opt/nightpay
chmod -R o+rX /opt/nightpay/ui/dist
```

`bin/deploy-hetzner-ci.sh` applies both of these automatically after each deploy (added `2026-04-16` alongside the missing `npm run build` step). If the perm ever regresses, the fix is to re-run deploy rather than hand-patch.

### 7.2) `MIP-003 failed to start: Address already in use`

`scripts/agent-playground-setup.sh start` writes PID files under `.agent-playground/run/`. If a prior run exited uncleanly, the PID file is stale but the old process is still bound to `8090` (MIP) or `3333` (UI). `stop` reads the stale PID, finds no process, and returns success. Next `start` tries to bind and crashes.

Fix sequence:

```bash
fuser -k 8090/tcp 3333/tcp 4000/tcp   # kill whatever actually holds the ports
sleep 2
rm -f /opt/nightpay/.agent-playground/run/*.pid
su - deploy -c 'cd /opt/nightpay && bash scripts/agent-playground-setup.sh start'
```

### 7.3) `bash: $'\r': command not found` after a Windows-origin tar-sync

PowerShell `tar.exe` preserves CRLF inside `.env` files. `scripts/server-sync-start.ps1` strips `\r` from `*.sh` during extract but does **not** strip it from `.agent-playground.env`. If you see `doctor` fail env parsing after a Windows deploy:

```bash
sed -i 's/\r$//' /opt/nightpay/.agent-playground.env
```

(Consider this a reminder to ship that sed into `server-sync-start.ps1` next time it changes.)

### 7.4) Deploy step succeeds but the UI still serves old code

The dev-server path (`npm run dev` via `scripts/agent-playground-setup.sh`) binds `:3333` and is only useful for Vite HMR on the server — **it is not what `nightpay.dev` serves**. Public traffic hits `ui/dist/`. If you see old UI code live:

```bash
ls -la /opt/nightpay/ui/dist/   # check mtime of index.html
```

If `index.html` is older than your latest commit, the build didn't run. CI from `2026-04-16` onwards always runs `npm run build` in `ui/` — if the step shows skipped, check that `ui/package.json` exists in the CI payload (submodule must have checked out).

## 8) Mandatory bundle for refund/discovery/dispute flow edits

When adjusting 5/6/7 lifecycle paths, update together:
1. `skills/nightpay/scripts/gateway.sh`
2. `skills/nightpay/scripts/mip003-server.sh`
3. `test/smoke.sh`
4. `README.md` runbook section

This keeps operator behavior, API behavior, and regression coverage in sync.
