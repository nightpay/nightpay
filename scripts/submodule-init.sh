#!/usr/bin/env bash
# submodule-init.sh — clone + install ui/ and bridge/ for local full-stack work.
# Keeps three repos split; this script only prepares the workspace.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_BUILD=0
DO_CHECKOUT=1

usage() {
  cat <<'EOF'
Usage:
  bash scripts/submodule-init.sh [--build] [--no-checkout]

  --build        Run `npm run build` in ui/ after install
  --no-checkout  Stay on pinned SHAs (detached HEAD); default checks out ui=main, bridge=master

After this:
  bash scripts/agent-playground-setup.sh init
  bash scripts/agent-playground-setup.sh start    # MIP + UI dev server
  cd bridge && npm run dev                        # bridge on :4000 (separate terminal)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) DO_BUILD=1; shift ;;
    --no-checkout) DO_CHECKOUT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd git
require_cmd npm

echo "== NightPay submodule init =="
echo "root: $ROOT_DIR"

cd "$ROOT_DIR"
git submodule sync --recursive
git submodule update --init --recursive

if [[ "$DO_CHECKOUT" == "1" ]]; then
  if [[ -d "$ROOT_DIR/ui/.git" ]]; then
    echo "== ui: checkout main =="
    git -C "$ROOT_DIR/ui" fetch origin main 2>/dev/null || git -C "$ROOT_DIR/ui" fetch origin
    git -C "$ROOT_DIR/ui" checkout main 2>/dev/null || git -C "$ROOT_DIR/ui" checkout -B main
    git -C "$ROOT_DIR/ui" pull --ff-only origin main 2>/dev/null || true
  fi
  if [[ -d "$ROOT_DIR/bridge/.git" ]]; then
    echo "== bridge: checkout master =="
    git -C "$ROOT_DIR/bridge" fetch origin master 2>/dev/null || git -C "$ROOT_DIR/bridge" fetch origin
    git -C "$ROOT_DIR/bridge" checkout master 2>/dev/null || git -C "$ROOT_DIR/bridge" checkout -B master
    git -C "$ROOT_DIR/bridge" pull --ff-only origin master 2>/dev/null || true
  fi
fi

if [[ -f "$ROOT_DIR/ui/package.json" ]]; then
  echo "== ui: npm install =="
  npm install --no-audit --no-fund --prefix "$ROOT_DIR/ui"
  if [[ "$DO_BUILD" == "1" ]]; then
    echo "== ui: npm run build =="
    npm run build --prefix "$ROOT_DIR/ui"
  fi
else
  echo "WARN: ui/ not present — check submodule access (private repo token?)" >&2
fi

if [[ -f "$ROOT_DIR/bridge/package.json" ]]; then
  echo "== bridge: npm install =="
  npm install --no-audit --no-fund --prefix "$ROOT_DIR/bridge"
  if [[ -f "$ROOT_DIR/bridge/tsconfig.json" ]]; then
    echo "== bridge: npm run build =="
    npm run build --prefix "$ROOT_DIR/bridge" 2>/dev/null || echo "WARN: bridge build skipped (compact/tsc may need toolchain)" >&2
  fi
else
  echo "WARN: bridge/ not present — check submodule access (private repo token?)" >&2
fi

echo ""
echo "== Submodule status =="
git submodule status

echo ""
echo "Next:"
echo "  bash scripts/agent-playground-setup.sh init && bash scripts/agent-playground-setup.sh start"
echo "  cd bridge && cp .env.example .env  # if present; then npm run dev"
echo "  ui dev:  http://localhost:3333  |  MIP: :8090  |  bridge: :4000"
