# Submodule Workflow (Root + UI + Bridge)

NightPay uses three Git repositories in one workspace:

- Root repo: `nightpay` (this repo)
- UI submodule: `ui/` -> `nightpay-ui`
- Bridge submodule: `bridge/` -> `nightpay-bridge`

The root repo stores only a pointer (commit SHA) for each submodule.  
So submodule file changes are not included in a root commit unless you:

1. Commit and push in the submodule itself, then
2. Commit the updated submodule pointer in root

## Golden Rules

1. Commit where the files actually changed.
2. Push submodule commits before pushing root pointer updates.
3. If root deploy/CI must use new `ui` or `bridge` code, update and commit the submodule pointer in root.
4. Before any push, run status in all three repos.

## Current Branch Defaults

- Root repo: `master` (production), `staging` (staging)
- UI repo: `main`
- Bridge repo: `master`

Check at any time:

```bash
git branch -vv
git -C ui branch -vv
git -C bridge branch -vv
```

## Common Flows

### A) Root-only change

```bash
git add <root-files>
git commit -m "..."
git push origin master   # or staging
```

### B) UI-only change

```bash
git -C ui add <ui-files>
git -C ui commit -m "..."
git -C ui push origin main
```

If root should now point to that UI commit (recommended for deploys):

```bash
git add ui
git commit -m "chore: bump ui submodule"
git push origin master   # or staging
```

### C) Bridge-only change

```bash
git -C bridge add <bridge-files>
git -C bridge commit -m "..."
git -C bridge push origin master
```

If root should now point to that bridge commit:

```bash
git add bridge
git commit -m "chore: bump bridge submodule"
git push origin master   # or staging
```

### D) Combined change (root + ui + bridge)

```bash
# 1) Commit/push submodules first
git -C ui add <ui-files>
git -C ui commit -m "..."
git -C ui push origin main

git -C bridge add <bridge-files>
git -C bridge commit -m "..."
git -C bridge push origin master

# 2) Commit root files + updated submodule pointers
git add <root-files> ui bridge
git commit -m "..."
git push origin master   # or staging
```

## Pre-Push Checklist

```bash
git status --short
git -C ui status --short
git -C bridge status --short
git submodule status
```

Interpretation:

- ` M bin/...` means root file changed.
- ` m ui` means submodule `ui` HEAD differs from root pointer (expected until pointer commit).
- ` m bridge` means submodule `bridge` HEAD differs from root pointer.

## Fresh clone — full workspace (root + ui + bridge)

Three repos, one folder. Run once after clone:

```bash
git clone https://github.com/nightpay/nightpay.git
cd nightpay
bash scripts/submodule-init.sh
```

Private submodules need GitHub access to `nightpay-ui` and `nightpay-bridge` (PAT or SSH). CI uses `NIGHTPAY_UI_REPO_TOKEN` / `NIGHTPAY_BRIDGE_REPO_TOKEN`.

Then bootstrap the stack:

```bash
bash scripts/agent-playground-setup.sh init
bash scripts/agent-playground-setup.sh start   # MIP :8090 + UI dev :3333
# separate terminal:
cd bridge && npm run dev                       # bridge :4000
```

| Repo | Path | Branch | Run locally |
|------|------|--------|-------------|
| nightpay | `.` | `master` | MIP + gateway skill |
| nightpay-ui | `ui/` | `main` | `npm run dev --prefix ui` |
| nightpay-bridge | `bridge/` | `master` | `npm run dev` in `bridge/` |

Stay on pinned SHAs (match production): `bash scripts/submodule-init.sh --no-checkout`

## Fresh clone (submodules only, manual)

```bash
git submodule update --init --recursive
```

## Why this matters

If you skip submodule commits and only push root, teammates/CI will not get your UI or bridge file changes.
They will only get whichever submodule commit SHA root points to.

## Shipping the result to production

Pushing the root pointer commit above only lands the code on `origin/master` (or `staging`) — it does **not** automatically reach Hetzner unless CI is wired up and green. For the full flow from "I pushed the submodule pointer" to "production returns 200", see:

- **Private operator docs** (gitignored): `docs/OPS_INDEX.md`, `docs/ADJUSTMENT_DEPLOY_CHECKLIST.md` — pushing via `.github/workflows/deploy-hetzner.yml`, CI troubleshooting (403 Caddy perms, port conflicts, CRLF).

