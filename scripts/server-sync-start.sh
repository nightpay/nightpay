#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/server-sync-start.sh \
    --host <hostname-or-ip> \
    --ssh-key <path-to-private-key> \
    [--remote-dir /opt/nightpay] \
    [--site-url https://board.nightpay.dev] \
    [--api-url https://api.nightpay.dev] \
    [--bridge-url https://bridge.nightpay.dev] \
    [--skip-install] \
    [--require-onchain]

What this script does:
  1) Verifies SSH access and server architecture.
  2) Backs up remote env files with a timestamp.
  3) Syncs this repo to the server.
  4) Initializes/starts NightPay services.
  5) Runs doctor and health checks (Masumi local + public URLs).
EOF
}

HOST=""
SSH_KEY=""
REMOTE_DIR="/opt/nightpay"
SKIP_INSTALL=0
SITE_URL="https://board.nightpay.dev"
API_URL="https://api.nightpay.dev"
BRIDGE_URL="https://bridge.nightpay.dev"
REQUIRE_ONCHAIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --site-url)
      SITE_URL="${2:-}"
      shift 2
      ;;
    --api-url)
      API_URL="${2:-}"
      shift 2
      ;;
    --bridge-url)
      BRIDGE_URL="${2:-}"
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift 1
      ;;
    --require-onchain)
      REQUIRE_ONCHAIN=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$HOST" || -z "$SSH_KEY" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key not found: $SSH_KEY" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=20
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
)

run_ssh() {
  local remote_cmd="$1"
  ssh "${SSH_OPTS[@]}" "root@${HOST}" "$remote_cmd"
}

echo "[1/6] Verify SSH connectivity..."
run_ssh "echo connected: \$(hostname)"

echo "[2/6] Verify server architecture..."
ARCH="$(run_ssh "uname -m")"
if [[ "$ARCH" != "x86_64" ]]; then
  echo "ERROR: expected x86_64 server for Masumi compatibility; found: $ARCH" >&2
  exit 1
fi

echo "[3/6] Backup remote env files..."
run_ssh "\
  set -euo pipefail; \
  mkdir -p '${REMOTE_DIR}/.backups'; \
  ts=\$(date +%Y%m%d-%H%M%S); \
  for f in '${REMOTE_DIR}/.agent-playground.env' '${REMOTE_DIR}/.env' '/opt/masumi-services-dev-quickstart/.env'; do \
    if [[ -f \"\$f\" ]]; then cp \"\$f\" '${REMOTE_DIR}/.backups/'\"\$(basename \"\$f\")\"'.'\"\$ts\"; fi; \
  done; \
  echo backup_timestamp=\$ts"

echo "[4/6] Sync repo to ${HOST}:${REMOTE_DIR}..."
tar \
  --exclude=.git \
  --exclude=node_modules \
  --exclude=ui/node_modules \
  --exclude=.agent-playground \
  --exclude=.env \
  --exclude=.env.* \
  --exclude=.private \
  --exclude=hetzner_* \
  -czf - -C "$ROOT_DIR" . \
| ssh "${SSH_OPTS[@]}" "root@${HOST}" "\
    set -euo pipefail; \
    mkdir -p '${REMOTE_DIR}'; \
    find '${REMOTE_DIR}' -mindepth 1 -maxdepth 1 \
      ! -name '.backups' \
      ! -name '.agent-playground' \
      ! -name '.agent-playground.env' \
      ! -name '.env' \
      -exec rm -rf {} +; \
    tar -xzf - -C '${REMOTE_DIR}'; \
    if ! id -u deploy >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,docker deploy; fi; \
    chown -R deploy:deploy '${REMOTE_DIR}'; \
    find '${REMOTE_DIR}' -type f -name '*.sh' -exec sed -i 's/\r$//' {} +"

echo "[5/6] Install deps and start NightPay..."
ssh "${SSH_OPTS[@]}" "root@${HOST}" "REMOTE_DIR='${REMOTE_DIR}' SKIP_INSTALL='${SKIP_INSTALL}' bash -s" <<'REMOTE'
set -euo pipefail

if [[ "$SKIP_INSTALL" != "1" ]]; then
  su - deploy -c "cd '$REMOTE_DIR' && npm install --no-audit --no-fund"
  if [[ -f "$REMOTE_DIR/ui/package.json" ]]; then
    su - deploy -c "cd '$REMOTE_DIR/ui' && npm install --no-audit --no-fund"
  else
    echo "WARN: $REMOTE_DIR/ui/package.json missing; skipping UI npm install."
  fi
fi

if [[ ! -f "$REMOTE_DIR/.agent-playground.env" ]]; then
  su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh init"
fi

su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh stop || true"
su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh start"
REMOTE

echo "[6/6] Doctor + endpoint checks..."
ssh "${SSH_OPTS[@]}" "root@${HOST}" "REMOTE_DIR='${REMOTE_DIR}' SITE_URL='${SITE_URL}' API_URL='${API_URL}' BRIDGE_URL='${BRIDGE_URL}' REQUIRE_ONCHAIN='${REQUIRE_ONCHAIN}' bash -s" <<'REMOTE'
set -euo pipefail

set +e
su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh doctor"
doctor_exit=$?
set -e

echo "doctor_exit=$doctor_exit (non-zero usually means env placeholders still need to be filled)"
echo "Masumi payment health (local 3001):"
curl -fsS http://127.0.0.1:3001/api/v1/health || true
echo
echo "Masumi registry health (local 3000):"
curl -fsS http://127.0.0.1:3000/api/v1/health || true
echo
echo "MIP availability:"
curl -fsS "${API_URL%/}/availability"
echo
echo "UI status:"
curl -sS -o /dev/null -w "%{http_code}\n" "${SITE_URL%/}/"
echo "Bridge health:"
bridge_health="$(curl -fsS "${BRIDGE_URL%/}/health")"
echo "$bridge_health"
echo "$bridge_health" | python3 - "$REQUIRE_ONCHAIN" <<'PY'
import json
import sys

require_onchain = sys.argv[1] == "1"
try:
    payload = json.loads(sys.stdin.read())
except Exception as exc:  # noqa: BLE001
    print(f"WARN: bridge health was not valid JSON: {exc}")
    sys.exit(0)

status = str(payload.get("status", "")).lower()
network = str(payload.get("network", "")).lower()
stub = bool(payload.get("stub", False))
init_error = payload.get("initError")

if status != "ok":
    print(f"WARN: bridge status is '{status}'")

if network and network != "preprod":
    print(f"WARN: bridge network is '{network}', expected 'preprod' until mainnet cutover")

if stub:
    msg = "WARN: bridge is in STUB mode (Midnight on-chain not active)"
    if init_error:
        msg += f"; initError={init_error}"
    print(msg)
    if require_onchain:
        print("ERROR: --require-onchain set and bridge is still stub=true")
        sys.exit(2)
else:
    print("OK: bridge is in on-chain mode (stub=false)")
PY
REMOTE

echo "done."
echo "next:"
echo "  1) ssh -i '$SSH_KEY' root@'$HOST'"
echo "  2) su - deploy && cd '$REMOTE_DIR'"
echo "  3) edit .agent-playground.env with MASUMI_API_KEY / OPERATOR_ADDRESS / RECEIPT_CONTRACT_ADDRESS / BRIDGE_URL"
echo "  4) bash scripts/agent-playground-setup.sh stop && bash scripts/agent-playground-setup.sh start"
echo "  5) bash scripts/agent-playground-setup.sh doctor"
