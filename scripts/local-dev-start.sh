#!/usr/bin/env bash
# local-dev-start.sh — start MIP + UI + bridge on localhost (full workspace dev).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.agent-playground.env"
BRIDGE_PID_FILE="${ROOT_DIR}/.agent-playground/run/bridge.pid"
BRIDGE_LOG="${ROOT_DIR}/.agent-playground/logs/bridge.log"

usage() {
  cat <<'EOF'
Usage: bash scripts/local-dev-start.sh [--init-submodules]

Starts the local NightPay stack:
  MIP-003  http://localhost:8090
  UI       http://localhost:3333
  Bridge   http://localhost:4000  (stub until WALLET_SEED in bridge/.env)

Options:
  --init-submodules   Run scripts/submodule-init.sh first if ui/ or bridge/ missing

Stop:  bash scripts/agent-playground-setup.sh stop
       kill $(cat .agent-playground/run/bridge.pid) 2>/dev/null || true
EOF
}

INIT_SUB=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --init-submodules) INIT_SUB=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$INIT_SUB" == "1" ]] || [[ ! -f "${ROOT_DIR}/ui/package.json" ]] || [[ ! -f "${ROOT_DIR}/bridge/package.json" ]]; then
  if [[ ! -f "${ROOT_DIR}/ui/package.json" ]] || [[ ! -f "${ROOT_DIR}/bridge/package.json" ]]; then
    echo "== Submodules missing — running submodule-init.sh =="
    bash "${ROOT_DIR}/scripts/submodule-init.sh"
  fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "== Creating .agent-playground.env (dummy mode) =="
  bash "${ROOT_DIR}/scripts/agent-playground-setup.sh" init --dummy
fi

echo "== Starting MIP + UI =="
bash "${ROOT_DIR}/scripts/agent-playground-setup.sh" start

mkdir -p "$(dirname "$BRIDGE_PID_FILE")" "$(dirname "$BRIDGE_LOG")"

bridge_running=0
if [[ -f "$BRIDGE_PID_FILE" ]]; then
  bp="$(cat "$BRIDGE_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$bp" ]] && kill -0 "$bp" 2>/dev/null; then
    bridge_running=1
  fi
fi
if curl -sf --max-time 2 "http://127.0.0.1:4000/health" >/dev/null 2>&1; then
  bridge_running=1
fi

if [[ "$bridge_running" == "0" ]]; then
  echo "== Starting bridge (stub mode until bridge/.env has WALLET_SEED) =="
  (
    cd "${ROOT_DIR}/bridge"
    npm run dev
  ) >>"$BRIDGE_LOG" 2>&1 &
  echo $! >"$BRIDGE_PID_FILE"
  sleep 2
else
  echo "== Bridge already running on :4000 =="
fi

echo ""
echo "== Status =="
bash "${ROOT_DIR}/scripts/agent-playground-setup.sh" status
curl -sf --max-time 5 "http://127.0.0.1:4000/health" >/dev/null \
  && echo "bridge: running (http://localhost:4000/health)" \
  || echo "bridge: starting — see $BRIDGE_LOG"

echo ""
echo "Open in browser:"
echo "  Board UI:  http://localhost:3333"
echo "  MIP API:   http://localhost:8090/availability"
echo "  Bridge:    http://localhost:4000/health"
echo ""
echo "Create a job:"
echo "  bash skills/nightpay/scripts/gateway.sh start-job \"My task\" 5000000 public"
