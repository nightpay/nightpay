#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/server-sync-start.sh \
    --host <hostname-or-ip> \
    --ssh-key <path-to-private-key> \
    [--remote-dir /opt/nightpay] \
    [--skip-install]

What this script does:
  1) Verifies SSH access and server architecture.
  2) Backs up remote env files with a timestamp.
  3) Syncs this repo to the server.
  4) Initializes/starts NightPay services.
  5) Runs doctor and health checks.
EOF
}

HOST=""
SSH_KEY=""
REMOTE_DIR="/opt/nightpay"
SKIP_INSTALL=0

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
    --skip-install)
      SKIP_INSTALL=1
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
ssh "${SSH_OPTS[@]}" "root@${HOST}" "REMOTE_DIR='${REMOTE_DIR}' bash -s" <<'REMOTE'
set -euo pipefail

set +e
su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh doctor"
doctor_exit=$?
set -e

echo "doctor_exit=$doctor_exit (non-zero usually means env placeholders still need to be filled)"
echo "MIP availability:"
curl -fsS https://api.nightpay.dev/availability
echo
echo "UI status:"
curl -sS -o /dev/null -w "%{http_code}\n" https://board.nightpay.dev/
REMOTE

echo "done."
echo "next:"
echo "  1) ssh -i '$SSH_KEY' root@'$HOST'"
echo "  2) su - deploy && cd '$REMOTE_DIR'"
echo "  3) edit .agent-playground.env with MASUMI_API_KEY / OPERATOR_ADDRESS / RECEIPT_CONTRACT_ADDRESS / BRIDGE_URL"
echo "  4) bash scripts/agent-playground-setup.sh stop && bash scripts/agent-playground-setup.sh start"
echo "  5) bash scripts/agent-playground-setup.sh doctor"
