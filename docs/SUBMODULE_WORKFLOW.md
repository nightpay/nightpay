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

## Fresh Clone Setup

```bash
git submodule update --init --recursive
```

## Why this matters

If you skip submodule commits and only push root, teammates/CI will not get your UI or bridge file changes.
They will only get whichever submodule commit SHA root points to.

