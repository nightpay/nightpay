#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash bin/deploy-hetzner-ci.sh \
    --host <hostname-or-ip> \
    --ssh-key <path-to-private-key> \
    [--ssh-port 22] \
    [--remote-dir /opt/nightpay] \
    [--bridge-dir /opt/nightpay-bridge] \
    [--masumi-dir /opt/masumi-services-dev-quickstart] \
    [--ui-port 3333] \
    [--mip-port 8090] \
    [--skip-npm-install] \
    [--skip-proof-recreate] \
    [--skip-masumi-recreate]

This script is intended for CI/CD usage.
It syncs the current committed HEAD to the server, restarts NightPay services,
recreates Docker services, and fails fast on health-check failures.
EOF
}

HOST=""
SSH_KEY=""
SSH_PORT="22"
REMOTE_DIR="/opt/nightpay"
BRIDGE_DIR="/opt/nightpay-bridge"
MASUMI_DIR="/opt/masumi-services-dev-quickstart"
SKIP_NPM_INSTALL=0
SKIP_PROOF_RECREATE=0
SKIP_MASUMI_RECREATE=0
UI_PORT=""
MIP_PORT=""

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
    --ssh-port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --bridge-dir)
      BRIDGE_DIR="${2:-}"
      shift 2
      ;;
    --masumi-dir)
      MASUMI_DIR="${2:-}"
      shift 2
      ;;
    --skip-npm-install)
      SKIP_NPM_INSTALL=1
      shift
      ;;
    --skip-proof-recreate)
      SKIP_PROOF_RECREATE=1
      shift
      ;;
    --skip-masumi-recreate)
      SKIP_MASUMI_RECREATE=1
      shift
      ;;
    --ui-port)
      UI_PORT="${2:-}"
      shift 2
      ;;
    --mip-port)
      MIP_PORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg '$1'" >&2
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
  -p "$SSH_PORT"
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

echo "[1/11] Verify SSH connectivity..."
run_ssh "echo connected: \$(hostname)"

echo "[2/11] Verify server architecture..."
ARCH="$(run_ssh "uname -m")"
if [[ "$ARCH" != "x86_64" ]]; then
  echo "ERROR: expected x86_64 server for Masumi compatibility; found: $ARCH" >&2
  exit 1
fi

echo "[3/11] Backup remote env files..."
run_ssh "\
  set -euo pipefail; \
  mkdir -p '${REMOTE_DIR}/.backups'; \
  ts=\$(date +%Y%m%d-%H%M%S); \
  for f in '${REMOTE_DIR}/.agent-playground.env' '${REMOTE_DIR}/.env' '${BRIDGE_DIR}/.env' '${MASUMI_DIR}/.env'; do \
    if [[ -f \"\$f\" ]]; then cp \"\$f\" '${REMOTE_DIR}/.backups/'\"\$(basename \"\$f\")\"'.'\"\$ts\"; fi; \
  done; \
  echo backup_timestamp=\$ts"

echo "[4/11] Stop NightPay services before sync..."
run_ssh "\
  set -euo pipefail; \
  if [[ ! -d '${REMOTE_DIR}' ]]; then exit 0; fi; \
  if id -u deploy >/dev/null 2>&1; then \
    if [[ -f '${REMOTE_DIR}/scripts/agent-playground-setup.sh' ]]; then \
      su - deploy -c \"cd '${REMOTE_DIR}' && bash scripts/agent-playground-setup.sh stop || true\"; \
    fi; \
    pkill -u deploy -f '${REMOTE_DIR}/skills/nightpay/scripts/mip003-server.sh' || true; \
    pkill -u deploy -f '${REMOTE_DIR}/ui/node_modules/.bin/vite' || true; \
  fi; \
  rm -f '${REMOTE_DIR}/.agent-playground/run/'*.pid || true; \
  rm -rf '${REMOTE_DIR}/ui/.vite' '${REMOTE_DIR}/ui/node_modules/.vite' || true"

echo "[5/11] Sync tracked commit to ${HOST}:${REMOTE_DIR}..."
TMP_SYNC_DIR="$(mktemp -d)"
cleanup_tmp() { rm -rf "$TMP_SYNC_DIR"; }
trap cleanup_tmp EXIT

HAS_UI_PAYLOAD=0
HAS_BRIDGE_PAYLOAD=0

git -C "$ROOT_DIR" archive --format=tar HEAD | tar -xf - -C "$TMP_SYNC_DIR"

# If ui/ exists locally (for example checked-out private submodule), include it in deploy payload.
if [[ -f "$ROOT_DIR/ui/package.json" ]]; then
  HAS_UI_PAYLOAD=1
  mkdir -p "$TMP_SYNC_DIR/ui"
  tar -C "$ROOT_DIR/ui" \
    --exclude=.git \
    --exclude=node_modules \
    --exclude=dist \
    -cf - . | tar -xf - -C "$TMP_SYNC_DIR/ui"
fi

PRESERVE_REMOTE_UI=0
if [[ "$HAS_UI_PAYLOAD" != "1" ]]; then
  PRESERVE_REMOTE_UI=1
  echo "WARN: ui submodule missing in CI payload; preserving existing ${REMOTE_DIR}/ui on server."
fi

tar -C "$TMP_SYNC_DIR" -cf - . \
  | ssh "${SSH_OPTS[@]}" "root@${HOST}" "\
      set -euo pipefail; \
      mkdir -p '${REMOTE_DIR}'; \
      if [[ '${PRESERVE_REMOTE_UI}' == '1' ]]; then \
        find '${REMOTE_DIR}' -mindepth 1 -maxdepth 1 \
          ! -name '.backups' \
          ! -name '.agent-playground' \
          ! -name '.agent-playground.env' \
          ! -name '.env' \
          ! -name 'ui' \
          -exec rm -rf {} +; \
      else \
        find '${REMOTE_DIR}' -mindepth 1 -maxdepth 1 \
          ! -name '.backups' \
          ! -name '.agent-playground' \
          ! -name '.agent-playground.env' \
          ! -name '.env' \
          -exec rm -rf {} +; \
      fi; \
      tar -xf - -C '${REMOTE_DIR}'; \
      if ! id -u deploy >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,docker deploy; fi; \
      chown -R deploy:deploy '${REMOTE_DIR}'; \
      find '${REMOTE_DIR}' -type f -name '*.sh' -exec sed -i 's/\r$//' {} +"

cleanup_tmp
trap - EXIT

echo "[6/11] Sync bridge source to ${HOST}:${BRIDGE_DIR} (if available)..."
if [[ -f "$ROOT_DIR/bridge/package.json" ]]; then
  HAS_BRIDGE_PAYLOAD=1
  TMP_BRIDGE_SYNC_DIR="$(mktemp -d)"
  tar -C "$ROOT_DIR/bridge" \
    --exclude=.git \
    --exclude=node_modules \
    --exclude=dist \
    --exclude=.env \
    -cf - . | tar -xf - -C "$TMP_BRIDGE_SYNC_DIR"

  tar -C "$TMP_BRIDGE_SYNC_DIR" -cf - . \
    | ssh "${SSH_OPTS[@]}" "root@${HOST}" "\
        set -euo pipefail; \
        mkdir -p '${BRIDGE_DIR}'; \
        tar -xf - -C '${BRIDGE_DIR}'; \
        if ! id -u deploy >/dev/null 2>&1; then useradd -m -s /bin/bash -G sudo,docker deploy; fi; \
        chown -R deploy:deploy '${BRIDGE_DIR}'; \
        find '${BRIDGE_DIR}' -type f -name '*.sh' -exec sed -i 's/\r$//' {} +"

  rm -rf "$TMP_BRIDGE_SYNC_DIR"
else
  echo "WARN: bridge submodule missing in CI payload; skipping bridge source sync."
fi

echo "[7/11] Restart NightPay services..."
ssh "${SSH_OPTS[@]}" "root@${HOST}" \
  "REMOTE_DIR='${REMOTE_DIR}' SKIP_NPM_INSTALL='${SKIP_NPM_INSTALL}' UI_PORT='${UI_PORT}' MIP_PORT='${MIP_PORT}' SKIP_MASUMI_RECREATE='${SKIP_MASUMI_RECREATE}' bash -s" <<'REMOTE'
set -euo pipefail

if [[ "$SKIP_NPM_INSTALL" != "1" ]]; then
  su - deploy -c "cd '$REMOTE_DIR' && npm install --no-audit --no-fund"
  if [[ -f "$REMOTE_DIR/ui/package.json" ]]; then
    su - deploy -c "cd '$REMOTE_DIR/ui' && npm install --no-audit --no-fund"
  else
    echo "WARN: $REMOTE_DIR/ui/package.json missing; skipping UI npm install."
  fi
fi

if [[ ! -f "$REMOTE_DIR/.agent-playground.env" ]]; then
  if [[ "$SKIP_MASUMI_RECREATE" == "1" && "$REMOTE_DIR" != "/opt/nightpay" && -f "/opt/nightpay/.agent-playground.env" ]]; then
    cp /opt/nightpay/.agent-playground.env "$REMOTE_DIR/.agent-playground.env"
    chown deploy:deploy "$REMOTE_DIR/.agent-playground.env" || true
  else
    su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh init"
  fi
fi

if [[ "$SKIP_MASUMI_RECREATE" == "1" && -f "/opt/nightpay/.agent-playground.env" ]]; then
  python3 - <<'PY'
from pathlib import Path
import os

remote_env = Path(os.environ["REMOTE_DIR"]) / ".agent-playground.env"
source_env = Path("/opt/nightpay/.agent-playground.env")
if not remote_env.exists() or not source_env.exists():
    raise SystemExit(0)

def parse(lines):
    out = {}
    for line in lines:
        if not line.startswith("export "):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.replace("export ", "", 1).strip()
        out[key] = value.strip().strip('"').strip("'")
    return out

def is_placeholder(value: str) -> bool:
    if not value:
        return True
    lowered = value.lower()
    return ("<fill-in" in lowered) or (value == "your-key")

remote_lines = remote_env.read_text().splitlines()
source_lines = source_env.read_text().splitlines()
remote_vals = parse(remote_lines)
source_vals = parse(source_lines)

remote_key = remote_vals.get("MASUMI_API_KEY", "")
source_key = source_vals.get("MASUMI_API_KEY", "")

if not is_placeholder(remote_key):
    raise SystemExit(0)
if is_placeholder(source_key):
    raise SystemExit(0)

updated = False
out = []
for line in remote_lines:
    if line.startswith("export MASUMI_API_KEY="):
        out.append(f'export MASUMI_API_KEY="{source_key}"')
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f'export MASUMI_API_KEY="{source_key}"')

remote_env.write_text("\n".join(out) + "\n")
PY
  chown deploy:deploy "$REMOTE_DIR/.agent-playground.env" || true
fi

if [[ -n "${UI_PORT:-}" || -n "${MIP_PORT:-}" ]]; then
  python3 - <<'PY'
from pathlib import Path
import os

env_path = Path(os.environ["REMOTE_DIR"]) / ".agent-playground.env"
if not env_path.exists():
    raise SystemExit(f"Missing env file: {env_path}")

ui_port = os.environ.get("UI_PORT", "").strip()
mip_port = os.environ.get("MIP_PORT", "").strip()
updates = {}
if ui_port:
    updates["export UI_PORT"] = f"\"{ui_port}\""
if mip_port:
    updates["export MIP_PORT"] = f"\"{mip_port}\""

if updates:
    lines = env_path.read_text().splitlines()
    out = []
    seen = set()
    for line in lines:
        replaced = False
        for key, value in updates.items():
            if line.startswith(key + "="):
                out.append(f"{key}={value}")
                seen.add(key)
                replaced = True
                break
        if not replaced:
            out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")
    env_path.write_text("\n".join(out) + "\n")
PY
  chown deploy:deploy "$REMOTE_DIR/.agent-playground.env" || true
fi

su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh stop || true"

# Best-effort cleanup for stale processes that survived previous stop operations.
pkill -u deploy -f "$REMOTE_DIR/skills/nightpay/scripts/mip003-server.sh" || true
pkill -u deploy -f "$REMOTE_DIR/ui/node_modules/.bin/vite" || true
rm -f "$REMOTE_DIR/.agent-playground/run/"*.pid || true

mip_port="${MIP_PORT:-8090}"
ui_port="${UI_PORT:-3333}"

# Kill stale listeners by port to avoid bind conflicts on restart.
if command -v ss >/dev/null 2>&1; then
  for port in "$mip_port" "$ui_port"; do
    pids="$(ss -ltnp "( sport = :$port )" 2>/dev/null | awk -F'pid=' 'NR>1 {split($2,a,","); print a[1]}' | sort -u)"
    if [[ -n "$pids" ]]; then
      kill $pids || true
      sleep 1
      pids_after="$(ss -ltnp "( sport = :$port )" 2>/dev/null | awk -F'pid=' 'NR>1 {split($2,a,","); print a[1]}' | sort -u)"
      if [[ -n "$pids_after" ]]; then
        kill -9 $pids_after || true
      fi
    fi
  done
fi

# Clear Vite caches to avoid stale file metadata and permission drift after sync.
rm -rf "$REMOTE_DIR/ui/.vite" "$REMOTE_DIR/ui/node_modules/.vite" || true

su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh start"
su - deploy -c "cd '$REMOTE_DIR' && bash scripts/agent-playground-setup.sh doctor"
REMOTE

echo "[8/11] Build and restart bridge service (if available)..."
if [[ "$HAS_BRIDGE_PAYLOAD" == "1" ]]; then
  ssh "${SSH_OPTS[@]}" "root@${HOST}" \
    "BRIDGE_DIR='${BRIDGE_DIR}' bash -s" <<'REMOTE'
set -euo pipefail

if [[ ! -f "$BRIDGE_DIR/package.json" ]]; then
  echo "bridge package not found at $BRIDGE_DIR; skipping bridge build/restart"
  exit 0
fi

if [[ ! -f "$BRIDGE_DIR/.env" ]]; then
  echo "WARN: $BRIDGE_DIR/.env missing; bridge may start in stub mode."
fi

su - deploy -c "cd '$BRIDGE_DIR' && npm install --no-audit --no-fund"
su - deploy -c "cd '$BRIDGE_DIR' && npm run build"

if command -v systemctl >/dev/null 2>&1; then
  for unit in nightpay-bridge.service bridge.service; do
    if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "$unit"; then
      systemctl restart "$unit"
      if ! systemctl is-active --quiet "$unit"; then
        journalctl -u "$unit" --no-pager -n 80 >&2 || true
        exit 1
      fi
      echo "bridge_service=systemd:$unit"
      exit 0
    fi
  done
fi

# Fallback for hosts without a systemd unit: run bridge as deploy user with .env.
pkill -u deploy -f "$BRIDGE_DIR/dist/server.js" || true
pkill -u deploy -f "node dist/server.js" || true
pkill -u deploy -f "$BRIDGE_DIR/src/server.ts" || true
pkill -u deploy -f "tsx" || true
su - deploy -c "cd '$BRIDGE_DIR' && bash -lc '
  set -euo pipefail
  if [[ -f .bridge.pid ]]; then
    kill \$(cat .bridge.pid) || true
    rm -f .bridge.pid || true
  fi
  set -a
  if [[ -f .env ]]; then source ./.env; fi
  set +a
  nohup node \"$BRIDGE_DIR/dist/server.js\" >> bridge.log 2>&1 &
  echo \$! > .bridge.pid
'"

bridge_port="$(awk -F= '/^BRIDGE_PORT=/{print $2}' "$BRIDGE_DIR/.env" 2>/dev/null | tail -n 1 | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
bridge_port="${bridge_port:-4000}"
for i in $(seq 1 30); do
  if curl -fsS -m 5 "http://127.0.0.1:${bridge_port}/health" >/dev/null; then
    echo "bridge_health=ok"
    break
  fi
  if [[ "$i" == "30" ]]; then
    echo "ERROR: bridge health check failed after restart." >&2
    tail -n 120 "$BRIDGE_DIR/bridge.log" >&2 || true
    exit 1
  fi
  sleep 2
done
echo "bridge_service=nohup:${bridge_port}"
REMOTE
else
  echo "WARN: bridge payload missing in CI workspace; skipping bridge build/restart."
fi

if [[ "$SKIP_PROOF_RECREATE" == "1" ]]; then
  echo "[9/11] Skipping proof-server recreate (--skip-proof-recreate)."
else
  echo "[9/11] Recreate proof-server Docker stack..."
  ssh "${SSH_OPTS[@]}" "root@${HOST}" \
    "BRIDGE_DIR='${BRIDGE_DIR}' bash -s" <<'REMOTE'
set -euo pipefail

if [[ ! -f "$BRIDGE_DIR/docker-compose.yml" ]]; then
  echo "bridge compose not found at $BRIDGE_DIR; skipping proof-server recreate"
  exit 0
fi

cd "$BRIDGE_DIR"
docker compose pull || true

if ! docker compose up -d --force-recreate --pull never; then
  if ! docker image inspect ghcr.io/midnight-ntwrk/proof-server:4.0.0 >/dev/null 2>&1 \
    && docker image inspect midnightnetwork/proof-server:latest >/dev/null 2>&1; then
    docker tag midnightnetwork/proof-server:latest ghcr.io/midnight-ntwrk/proof-server:4.0.0
  fi
  docker compose up -d --force-recreate --pull never
fi
REMOTE
fi

if [[ "$SKIP_MASUMI_RECREATE" == "1" ]]; then
  echo "[10/11] Skipping Masumi recreate (--skip-masumi-recreate)."
else
  echo "[10/11] Recreate Masumi API containers..."
  ssh "${SSH_OPTS[@]}" "root@${HOST}" \
    "MASUMI_DIR='${MASUMI_DIR}' bash -s" <<'REMOTE'
set -euo pipefail

if [[ ! -f "$MASUMI_DIR/docker-compose.yml" ]]; then
  echo "masumi compose not found at $MASUMI_DIR; skipping Masumi recreate"
  exit 0
fi

cd "$MASUMI_DIR"

# SECURITY: force Postgres port bindings to loopback only so DB is not reachable from the public internet.
python3 - <<'PY'
from pathlib import Path
import re
import sys

compose = Path("docker-compose.yml")
text = compose.read_text()

replacements = {
    "3000:3000": "127.0.0.1:3000:3000",
    "3001:3001": "127.0.0.1:3001:3001",
    "13000:3000": "127.0.0.1:13000:3000",
    "13001:3001": "127.0.0.1:13001:3001",
    "5432:5432": "127.0.0.1:5432:5432",
    "5433:5432": "127.0.0.1:5433:5432",
    "15432:5432": "127.0.0.1:15432:5432",
    "15433:5432": "127.0.0.1:15433:5432",
}
for src, dst in replacements.items():
    text = text.replace(f'"{src}"', f'"{dst}"')
    text = text.replace(f"'{src}'", f"'{dst}'")

bad = re.findall(r'(?<!127\.0\.0\.1:)(?:(?:3000|13000):3000|(?:3001|13001):3001|(?:5432|5433|15432|15433):5432)', text)
if bad:
    print("ERROR: docker-compose.yml still contains non-loopback internal port mappings:", sorted(set(bad)), file=sys.stderr)
    sys.exit(1)

compose.write_text(text)
PY

# Keep DB volumes stable; only recreate API containers unless DB services are down.
docker compose up -d postgres-payment postgres-registry
docker compose pull payment-service registry-service || true
docker compose up -d --no-deps --force-recreate payment-service registry-service

for i in $(seq 1 90); do
  p="$(curl -fsS -m 2 http://localhost:3001/api/v1/health || true)"
  r="$(curl -fsS -m 2 http://localhost:3000/api/v1/health || true)"
  if [[ -n "$p" && -n "$r" ]]; then
    echo "masumi_payment=$p"
    echo "masumi_registry=$r"
    exit 0
  fi
  sleep 2
done

echo "ERROR: Masumi health check failed after recreate." >&2
docker compose ps >&2
docker compose logs --tail 80 payment-service registry-service >&2
exit 1
REMOTE
fi

echo "[10.5/11] Verify Masumi DB ports are private..."
run_ssh "\
  set -euo pipefail; \
  if [[ ! -f '${MASUMI_DIR}/docker-compose.yml' ]]; then \
    echo 'masumi_db_ports=skipped'; \
    exit 0; \
  fi; \
  exposed=\$(ss -ltn | awk 'NR>1 && \$4 ~ /:(3000|3001|13000|13001|5432|5433|15432|15433)\$/ && \$4 !~ /^127\\.0\\.0\\.1:/ {print \$4}'); \
  if [[ -n \"\$exposed\" ]]; then \
    echo 'ERROR: Masumi internal ports are publicly reachable:' >&2; \
    echo \"\$exposed\" >&2; \
    exit 1; \
  fi; \
  echo 'masumi_internal_ports=private'"

MIP_PORT_CHECK="${MIP_PORT:-8090}"
UI_PORT_CHECK="${UI_PORT:-3333}"

echo "[11/11] Final health checks..."
run_ssh "\
  set -euo pipefail; \
  ui_enabled='1'; \
  if [[ -f '${REMOTE_DIR}/.agent-playground.env' ]]; then source '${REMOTE_DIR}/.agent-playground.env'; ui_enabled=\${ENABLE_UI:-1}; fi; \
  echo -n 'mip='; curl -fsS http://localhost:${MIP_PORT_CHECK}/availability; echo; \
  if [[ \"\$ui_enabled\" == '1' && -f '${REMOTE_DIR}/ui/package.json' ]]; then \
    ui_code=\$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:${UI_PORT_CHECK}/); \
    echo ui_status=\$ui_code; \
    if [[ \"\$ui_code\" != '200' ]]; then echo 'ERROR: UI health check failed' >&2; exit 1; fi; \
  else \
    echo 'ui_status=skipped'; \
  fi; \
  if [[ -f '${BRIDGE_DIR}/package.json' ]]; then \
    bridge_port=\$(awk -F= '/^BRIDGE_PORT=/{print \$2}' '${BRIDGE_DIR}/.env' 2>/dev/null | tail -n 1 | tr -d '\"' | tr -d \"'\" | tr -d '[:space:]'); \
    bridge_port=\${bridge_port:-4000}; \
    echo -n 'bridge='; curl -fsS http://localhost:\${bridge_port}/health; echo; \
  else \
    echo 'bridge=skipped'; \
  fi; \
  if [[ '${SKIP_MASUMI_RECREATE}' != '1' && -f '${MASUMI_DIR}/docker-compose.yml' ]]; then \
    echo -n 'payment='; curl -fsS http://localhost:3001/api/v1/health; echo; \
    echo -n 'registry='; curl -fsS http://localhost:3000/api/v1/health; echo; \
  fi; \
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"

echo "Deploy completed successfully."
