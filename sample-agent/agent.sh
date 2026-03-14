#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_TEMPLATE="${SCRIPT_DIR}/.env.example"
STATE_DIR="${SCRIPT_DIR}/.state"
RATE_LIMIT_DIR="${STATE_DIR}/ratelimit"
GATEWAY_SCRIPT="${ROOT_DIR}/skills/nightpay/scripts/gateway.sh"
BRIDGE_PID_FILE="${STATE_DIR}/bridge.pid"
BRIDGE_LOG_FILE="${STATE_DIR}/bridge.log"

usage() {
  cat <<'EOF'
NightPay sample-agent (isolated environment)

Usage:
  bash sample-agent/agent.sh init [--force]
  bash sample-agent/agent.sh onboard [--no-start-masumi] [--no-start-bridge] [--no-deploy]
  bash sample-agent/agent.sh doctor
  bash sample-agent/agent.sh sync-addresses [--deploy-if-missing]
  bash sample-agent/agent.sh post <amount_specks> [--desc "<description>"]
  bash sample-agent/agent.sh post-checked <amount_specks> [--desc "<description>"]

Notes:
  - If --desc is omitted, description is read from stdin.
  - This script uses sample-agent/.env only (separate from .agent-playground.env).
EOF
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  [[ "$value" == "<ADMIN_KEY>" ]] && return 0
  [[ "$value" == "<bridge-deploy-token>" ]] && return 0
  [[ "$value" == "<64-char-lowercase-hex>" ]] && return 0
  [[ "$value" == *"<fill-in"* ]] && return 0
  return 1
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: missing ${ENV_FILE}. Run: bash sample-agent/agent.sh init" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

upsert_env_var() {
  local key="$1"
  local value="$2"
  python3 - "$ENV_FILE" "$key" "$value" <<'PY'
import re
import sys

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
new_line = f'export {key}="{value}"\n'
pattern = re.compile(rf"^\s*export\s+{re.escape(key)}=")

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

updated = []
replaced = False
for line in lines:
    if pattern.match(line):
        updated.append(new_line)
        replaced = True
    else:
        updated.append(line)

if not replaced:
    if updated and not updated[-1].endswith("\n"):
        updated[-1] += "\n"
    updated.append(new_line)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(updated)
PY
}

info() { echo "INFO: $*"; }
warn() { echo "WARN: $*" >&2; }

mask_value() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    echo "<empty>"
    return 0
  fi
  local len=${#value}
  if (( len <= 8 )); then
    echo "********"
    return 0
  fi
  echo "${value:0:4}...${value:len-4:4}"
}

resolve_existing_dir() {
  local candidate
  for candidate in "$@"; do
    [[ -z "$candidate" ]] && continue
    if [[ -d "$candidate" ]]; then
      (
        cd "$candidate" >/dev/null 2>&1 || exit 1
        pwd
      )
      return 0
    fi
  done
  return 1
}

dotenv_get() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 1
  python3 - "$file" "$key" <<'PY'
import re
import sys

path, key = sys.argv[1], sys.argv[2]
pattern = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')

with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = pattern.match(line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if k != key:
            continue
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        print(v)
        sys.exit(0)
sys.exit(1)
PY
}

set_if_placeholder() {
  local key="$1"
  local value="${2:-}"
  [[ -z "$value" ]] && return 1
  if is_placeholder "$value"; then
    return 1
  fi
  local current="${!key:-}"
  if is_placeholder "$current"; then
    upsert_env_var "$key" "$value"
    export "$key=$value"
    return 0
  fi
  return 1
}

parse_bridge_health_field() {
  local json="$1"
  local field="$2"
  printf '%s' "$json" | python3 - "$field" <<'PY'
import json
import sys

field = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
value = data.get(field)
if value is None:
    sys.exit(1)
print(value)
PY
}

wait_for_http_ok() {
  local url="$1"
  local timeout_seconds="${2:-30}"
  local start_ts now
  start_ts="$(date +%s)"
  while true; do
    if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start_ts >= timeout_seconds )); then
      return 1
    fi
    sleep 1
  done
}

is_pid_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

import_known_local_envs() {
  local bridge_dir masumi_dir playground_env bridge_env masumi_env value bridge_port

  value="${MASUMI_API_KEY:-}"; set_if_placeholder "MASUMI_API_KEY" "$value" && info "MASUMI_API_KEY imported from current shell env"
  value="${BRIDGE_URL:-}"; set_if_placeholder "BRIDGE_URL" "$value" && info "BRIDGE_URL imported from current shell env"
  value="${BRIDGE_ADMIN_TOKEN:-}"; set_if_placeholder "BRIDGE_ADMIN_TOKEN" "$value" && info "BRIDGE_ADMIN_TOKEN imported from current shell env"
  value="${OPERATOR_SECRET_KEY:-}"; set_if_placeholder "BRIDGE_ADMIN_TOKEN" "$value" && info "BRIDGE_ADMIN_TOKEN imported from OPERATOR_SECRET_KEY in current shell env"
  value="${OPERATOR_ADDRESS:-}"; set_if_placeholder "OPERATOR_ADDRESS" "$value" && info "OPERATOR_ADDRESS imported from current shell env"
  value="${RECEIPT_CONTRACT_ADDRESS:-}"; set_if_placeholder "RECEIPT_CONTRACT_ADDRESS" "$value" && info "RECEIPT_CONTRACT_ADDRESS imported from current shell env"

  bridge_dir="$(resolve_existing_dir "${BRIDGE_DIR:-}" "${ROOT_DIR}/../nightpay-ob/nightpay-bridge" "${ROOT_DIR}/../nightpay-bridge" "${ROOT_DIR}/bridge" || true)"
  masumi_dir="$(resolve_existing_dir "${MASUMI_QUICKSTART_DIR:-}" "${ROOT_DIR}/../masumi-services-dev-quickstart" "${ROOT_DIR}/../nightpay-ob/masumi-services-dev-quickstart" || true)"

  if [[ -n "$bridge_dir" ]]; then
    set_if_placeholder "BRIDGE_DIR" "$bridge_dir" && info "BRIDGE_DIR set to ${bridge_dir}"
  fi
  if [[ -n "$masumi_dir" ]]; then
    set_if_placeholder "MASUMI_QUICKSTART_DIR" "$masumi_dir" && info "MASUMI_QUICKSTART_DIR set to ${masumi_dir}"
  fi

  playground_env="${ROOT_DIR}/.agent-playground.env"
  if [[ -f "$playground_env" ]]; then
    value="$(dotenv_get "$playground_env" "MASUMI_API_KEY" || true)"; set_if_placeholder "MASUMI_API_KEY" "$value" && info "MASUMI_API_KEY imported from .agent-playground.env"
    value="$(dotenv_get "$playground_env" "BRIDGE_URL" || true)"; set_if_placeholder "BRIDGE_URL" "$value" && info "BRIDGE_URL imported from .agent-playground.env"
    value="$(dotenv_get "$playground_env" "BRIDGE_ADMIN_TOKEN" || true)"; set_if_placeholder "BRIDGE_ADMIN_TOKEN" "$value" && info "BRIDGE_ADMIN_TOKEN imported from .agent-playground.env"
    value="$(dotenv_get "$playground_env" "OPERATOR_SECRET_KEY" || true)"; set_if_placeholder "BRIDGE_ADMIN_TOKEN" "$value" && info "BRIDGE_ADMIN_TOKEN imported from .agent-playground.env OPERATOR_SECRET_KEY"
    value="$(dotenv_get "$playground_env" "OPERATOR_ADDRESS" || true)"; set_if_placeholder "OPERATOR_ADDRESS" "$value" && info "OPERATOR_ADDRESS imported from .agent-playground.env"
    value="$(dotenv_get "$playground_env" "RECEIPT_CONTRACT_ADDRESS" || true)"; set_if_placeholder "RECEIPT_CONTRACT_ADDRESS" "$value" && info "RECEIPT_CONTRACT_ADDRESS imported from .agent-playground.env"
  fi

  if [[ -n "$bridge_dir" ]]; then
    bridge_env="${bridge_dir}/.env"
    if [[ -f "$bridge_env" ]]; then
      value="$(dotenv_get "$bridge_env" "BRIDGE_URL" || true)"; set_if_placeholder "BRIDGE_URL" "$value" && info "BRIDGE_URL imported from bridge .env"
      bridge_port="$(dotenv_get "$bridge_env" "BRIDGE_PORT" || true)"
      if [[ -n "$bridge_port" ]]; then
        set_if_placeholder "BRIDGE_URL" "http://localhost:${bridge_port}" && info "BRIDGE_URL inferred from bridge .env BRIDGE_PORT=${bridge_port}"
      fi
      value="$(dotenv_get "$bridge_env" "BRIDGE_ADMIN_TOKEN" || true)"; set_if_placeholder "BRIDGE_ADMIN_TOKEN" "$value" && info "BRIDGE_ADMIN_TOKEN imported from bridge .env"
      value="$(dotenv_get "$bridge_env" "OPERATOR_SECRET_KEY" || true)"; set_if_placeholder "BRIDGE_ADMIN_TOKEN" "$value" && info "BRIDGE_ADMIN_TOKEN imported from bridge .env OPERATOR_SECRET_KEY"
      value="$(dotenv_get "$bridge_env" "OPERATOR_ADDRESS" || true)"; set_if_placeholder "OPERATOR_ADDRESS" "$value" && info "OPERATOR_ADDRESS imported from bridge .env"
      value="$(dotenv_get "$bridge_env" "RECEIPT_CONTRACT_ADDRESS" || true)"; set_if_placeholder "RECEIPT_CONTRACT_ADDRESS" "$value" && info "RECEIPT_CONTRACT_ADDRESS imported from bridge .env"
      value="$(dotenv_get "$bridge_env" "MIDNIGHT_NETWORK" || true)"; set_if_placeholder "MIDNIGHT_NETWORK" "$value" && info "MIDNIGHT_NETWORK imported from bridge .env"
    fi
  fi

  if [[ -n "$masumi_dir" ]]; then
    masumi_env="${masumi_dir}/.env"
    if [[ -f "$masumi_env" ]]; then
      value="$(dotenv_get "$masumi_env" "ADMIN_KEY" || true)"
      set_if_placeholder "MASUMI_API_KEY" "$value" && info "MASUMI_API_KEY imported from Masumi .env (ADMIN_KEY)"
    fi
  fi
}

prompt_missing_value() {
  local key="$1"
  local prompt="$2"
  local secret="${3:-0}"
  local current="${!key:-}"
  if ! is_placeholder "$current"; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 1
  fi

  local value=""
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$prompt: " value
    echo
  else
    read -r -p "$prompt: " value
  fi
  [[ -z "$value" ]] && return 1
  upsert_env_var "$key" "$value"
  export "$key=$value"
  info "${key} updated from interactive input ($(mask_value "$value"))"
  return 0
}

start_masumi_if_possible() {
  local payment_health="${MASUMI_PAYMENT_URL%/}/health"
  local registry_health="${MASUMI_REGISTRY_URL%/}/health"
  if curl -sf --max-time 5 "$payment_health" >/dev/null 2>&1 && curl -sf --max-time 5 "$registry_health" >/dev/null 2>&1; then
    info "Masumi is already healthy"
    return 0
  fi

  local masumi_dir
  masumi_dir="$(resolve_existing_dir "${MASUMI_QUICKSTART_DIR:-}" "${ROOT_DIR}/../masumi-services-dev-quickstart" "${ROOT_DIR}/../nightpay-ob/masumi-services-dev-quickstart" || true)"
  if [[ -z "$masumi_dir" ]]; then
    warn "Masumi quickstart directory not found; cannot auto-start Masumi"
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not available; cannot auto-start Masumi"
    return 1
  fi

  info "Starting Masumi via docker compose in ${masumi_dir}"
  (cd "$masumi_dir" && docker compose up -d >/dev/null)

  wait_for_http_ok "$payment_health" 40 || true
  wait_for_http_ok "$registry_health" 40 || true

  if curl -sf --max-time 5 "$payment_health" >/dev/null 2>&1 && curl -sf --max-time 5 "$registry_health" >/dev/null 2>&1; then
    info "Masumi health checks are now passing"
    return 0
  fi
  warn "Masumi health checks are still failing after startup attempt"
  return 1
}

compile_bridge_if_needed() {
  local bridge_dir="$1"
  [[ -d "$bridge_dir" ]] || return 1
  [[ -f "${bridge_dir}/package.json" ]] || return 1
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not available; cannot auto-compile bridge"
    return 1
  fi

  info "Compiling bridge contract artifacts in ${bridge_dir}"
  (cd "$bridge_dir" && npm run compile)
}

start_bridge_if_possible() {
  local bridge_dir="$1"
  [[ -n "${BRIDGE_URL:-}" ]] || return 1

  if curl -sf --max-time 5 "${BRIDGE_URL%/}/health" >/dev/null 2>&1; then
    info "Bridge is already healthy"
    return 0
  fi
  [[ -d "$bridge_dir" ]] || { warn "Bridge directory not found; cannot auto-start bridge"; return 1; }
  if ! command -v npm >/dev/null 2>&1; then
    warn "npm not available; cannot auto-start bridge"
    return 1
  fi

  mkdir -p "$STATE_DIR"
  if is_pid_running "$BRIDGE_PID_FILE"; then
    info "Bridge process already running (pid $(cat "$BRIDGE_PID_FILE"))"
  else
    info "Starting bridge in background from ${bridge_dir}"
    (
      cd "$bridge_dir"
      nohup npm run dev >>"$BRIDGE_LOG_FILE" 2>&1 &
      echo $! >"$BRIDGE_PID_FILE"
    )
  fi

  if wait_for_http_ok "${BRIDGE_URL%/}/health" 45; then
    info "Bridge health checks are now passing"
    return 0
  fi

  warn "Bridge health checks are still failing after startup attempt"
  if [[ -f "$BRIDGE_LOG_FILE" ]]; then
    warn "Bridge log tail:"
    tail -n 20 "$BRIDGE_LOG_FILE" >&2 || true
  fi
  return 1
}

validate_hex64() {
  local label="$1"
  local value="$2"
  if [[ "$value" =~ ^[0-9a-f]{64}$ ]]; then
    return 0
  fi
  echo "FAIL: ${label} must be 64-char lowercase hex" >&2
  return 1
}

init_cmd() {
  local force="${1:-}"
  if [[ "$force" != "" && "$force" != "--force" ]]; then
    echo "ERROR: unknown init option: ${force}" >&2
    usage
    exit 1
  fi

  if [[ -f "$ENV_FILE" && "$force" != "--force" ]]; then
    echo "ERROR: ${ENV_FILE} already exists. Use init --force to regenerate." >&2
    exit 1
  fi

  cp "$ENV_TEMPLATE" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  mkdir -p "$STATE_DIR" "$RATE_LIMIT_DIR"
  echo "created: ${ENV_FILE}"
  echo "next: fill MASUMI_API_KEY, OPERATOR_ADDRESS, RECEIPT_CONTRACT_ADDRESS, BRIDGE_URL"
}

extract_contract_address() {
  python3 - <<'PY'
import json
import re
import sys

HEX64 = re.compile(r"^[0-9a-f]{64}$")

def find_contract(node):
    if isinstance(node, dict):
        for key in (
            "contractAddress",
            "receiptContractAddress",
            "receiptContract",
            "contract",
            "contract_address",
        ):
            val = node.get(key)
            if isinstance(val, str) and HEX64.fullmatch(val):
                return val
        for key, val in node.items():
            if "contract" in str(key).lower() and isinstance(val, str) and HEX64.fullmatch(val):
                return val
        for val in node.values():
            found = find_contract(val)
            if found:
                return found
    elif isinstance(node, list):
        for item in node:
            found = find_contract(item)
            if found:
                return found
    return None

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

address = find_contract(data)
if address:
    print(address)
    sys.exit(0)
sys.exit(1)
PY
}

sync_addresses_cmd() {
  local deploy_if_missing=0
  local soft_fail=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deploy-if-missing)
        deploy_if_missing=1
        ;;
      --soft)
        soft_fail=1
        ;;
      *)
        echo "ERROR: unknown option: ${1}" >&2
        echo "Usage: bash sample-agent/agent.sh sync-addresses [--deploy-if-missing] [--soft]" >&2
        exit 1
        ;;
    esac
    shift
  done

  load_env
  is_placeholder "${BRIDGE_URL:-}" && { echo "ERROR: BRIDGE_URL is not configured in ${ENV_FILE}" >&2; exit 1; }

  local operator_json operator_address health_json contract_address
  operator_json="$(curl -sf --max-time 15 "${BRIDGE_URL%/}/operator-address" 2>/dev/null || true)"
  operator_address=""
  if [[ -n "$operator_json" ]]; then
    operator_address="$(printf '%s' "$operator_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || true)"
    if [[ "$operator_address" =~ ^[0-9a-f]{64}$ ]]; then
      upsert_env_var "OPERATOR_ADDRESS" "$operator_address"
      export OPERATOR_ADDRESS="$operator_address"
      info "synced OPERATOR_ADDRESS from bridge"
    elif [[ "$soft_fail" -eq 0 ]]; then
      echo "ERROR: bridge returned invalid operator address format" >&2
      exit 1
    else
      warn "bridge /operator-address did not return a valid 64-char hex address"
    fi
  elif [[ "$soft_fail" -eq 0 ]]; then
    echo "ERROR: bridge /operator-address failed (${BRIDGE_URL%/}/operator-address)" >&2
    exit 1
  else
    warn "bridge /operator-address request failed"
  fi

  health_json="$(curl -sf --max-time 15 "${BRIDGE_URL%/}/health" 2>/dev/null || true)"
  contract_address=""
  if [[ -n "$health_json" ]]; then
    contract_address="$(printf '%s' "$health_json" | extract_contract_address 2>/dev/null || true)"
  fi

  if [[ -z "$contract_address" && "$deploy_if_missing" -eq 1 ]]; then
    if is_placeholder "${BRIDGE_ADMIN_TOKEN:-}" && ! is_placeholder "${OPERATOR_SECRET_KEY:-}"; then
      BRIDGE_ADMIN_TOKEN="${OPERATOR_SECRET_KEY}"
    fi
    is_placeholder "${BRIDGE_ADMIN_TOKEN:-}" && {
      echo "ERROR: BRIDGE_ADMIN_TOKEN required for --deploy-if-missing" >&2
      exit 1
    }
    local deploy_contract_path deploy_zk_path deploy_fee_bps deploy_payload deploy_json
    deploy_contract_path="${DEPLOY_CONTRACT_PATH:-skills/nightpay/contracts/receipt.js}"
    deploy_zk_path="${DEPLOY_ZK_PATH:-skills/nightpay/contracts/receipt.zk}"
    deploy_fee_bps="${OPERATOR_FEE_BPS:-200}"
    deploy_payload="$(python3 -c "import json,sys; print(json.dumps({'contractPath':sys.argv[1],'zkPath':sys.argv[2],'operatorFeeBps':int(sys.argv[3])}))" "$deploy_contract_path" "$deploy_zk_path" "$deploy_fee_bps")"
    deploy_json="$(curl -sf --max-time 30 -X POST "${BRIDGE_URL%/}/deploy" \
      -H "Authorization: Bearer ${BRIDGE_ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$deploy_payload")" || {
      echo "ERROR: bridge /deploy failed; check BRIDGE_ADMIN_TOKEN and deploy paths" >&2
      exit 1
    }
    contract_address="$(printf '%s' "$deploy_json" | extract_contract_address 2>/dev/null || true)"
  fi

  if [[ -n "$contract_address" ]]; then
    upsert_env_var "RECEIPT_CONTRACT_ADDRESS" "$contract_address"
    export RECEIPT_CONTRACT_ADDRESS="$contract_address"
    info "synced RECEIPT_CONTRACT_ADDRESS from bridge"
  else
    warn "could not resolve RECEIPT_CONTRACT_ADDRESS from bridge /health"
    warn "hint: rerun with --deploy-if-missing after setting BRIDGE_ADMIN_TOKEN"
    if [[ "$soft_fail" -eq 0 ]]; then
      return 1
    fi
  fi

  if [[ "$soft_fail" -eq 0 ]]; then
    if ! [[ "${OPERATOR_ADDRESS:-}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: OPERATOR_ADDRESS still missing/invalid after sync" >&2
      return 1
    fi
    if ! [[ "${RECEIPT_CONTRACT_ADDRESS:-}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: RECEIPT_CONTRACT_ADDRESS still missing/invalid after sync" >&2
      return 1
    fi
  fi
}

doctor_cmd() {
  local failures=0
  local warnings=0

  pass() { echo "PASS: $1"; }
  fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
  warn() { echo "WARN: $1"; warnings=$((warnings + 1)); }

  command -v bash >/dev/null 2>&1 && pass "tool: bash" || fail "tool: bash"
  command -v curl >/dev/null 2>&1 && pass "tool: curl" || fail "tool: curl"
  command -v python3 >/dev/null 2>&1 && pass "tool: python3" || fail "tool: python3"
  [[ -f "$GATEWAY_SCRIPT" ]] && pass "gateway script present" || fail "gateway script present"

  if [[ -f "$ENV_FILE" ]]; then
    pass "env file present"
    load_env
  else
    fail "env file present"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    is_placeholder "${MASUMI_API_KEY:-}" && fail "MASUMI_API_KEY configured" || pass "MASUMI_API_KEY configured"
    is_placeholder "${OPERATOR_ADDRESS:-}" && fail "OPERATOR_ADDRESS configured" || pass "OPERATOR_ADDRESS configured"
    is_placeholder "${RECEIPT_CONTRACT_ADDRESS:-}" && fail "RECEIPT_CONTRACT_ADDRESS configured" || pass "RECEIPT_CONTRACT_ADDRESS configured"
    is_placeholder "${BRIDGE_URL:-}" && fail "BRIDGE_URL configured" || pass "BRIDGE_URL configured"
    [[ "${MIDNIGHT_NETWORK:-}" == "preprod" || "${MIDNIGHT_NETWORK:-}" == "mainnet" ]] && \
      pass "MIDNIGHT_NETWORK set (${MIDNIGHT_NETWORK})" || warn "MIDNIGHT_NETWORK is not preprod/mainnet"

    validate_hex64 "OPERATOR_ADDRESS" "${OPERATOR_ADDRESS:-}" || failures=$((failures + 1))
    validate_hex64 "RECEIPT_CONTRACT_ADDRESS" "${RECEIPT_CONTRACT_ADDRESS:-}" || failures=$((failures + 1))
  fi

  if [[ -n "${MASUMI_PAYMENT_URL:-}" ]]; then
    if curl -sf --max-time 10 "${MASUMI_PAYMENT_URL%/}/health" >/dev/null; then
      pass "Masumi payment health (${MASUMI_PAYMENT_URL%/}/health)"
    else
      fail "Masumi payment health (${MASUMI_PAYMENT_URL%/}/health)"
    fi
  fi

  if [[ -n "${MASUMI_REGISTRY_URL:-}" ]]; then
    if curl -sf --max-time 10 "${MASUMI_REGISTRY_URL%/}/health" >/dev/null; then
      pass "Masumi registry health (${MASUMI_REGISTRY_URL%/}/health)"
    else
      fail "Masumi registry health (${MASUMI_REGISTRY_URL%/}/health)"
    fi
  fi

  if [[ -n "${BRIDGE_URL:-}" ]]; then
    if curl -sf --max-time 10 "${BRIDGE_URL%/}/health" >/dev/null; then
      pass "Midnight bridge health (${BRIDGE_URL%/}/health)"
    else
      fail "Midnight bridge health (${BRIDGE_URL%/}/health)"
    fi

    local bridge_operator_json
    if bridge_operator_json="$(curl -sf --max-time 10 "${BRIDGE_URL%/}/operator-address" 2>/dev/null)"; then
      local bridge_operator
      bridge_operator="$(printf '%s' "$bridge_operator_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || true)"
      if [[ "$bridge_operator" =~ ^[0-9a-f]{64}$ ]]; then
        pass "bridge operator address format"
        if [[ -n "${OPERATOR_ADDRESS:-}" && "$bridge_operator" != "$OPERATOR_ADDRESS" ]]; then
          warn "OPERATOR_ADDRESS does not match bridge /operator-address (wallet mismatch)"
        else
          pass "OPERATOR_ADDRESS matches bridge /operator-address"
        fi
      else
        fail "bridge operator address format"
      fi
    else
      fail "bridge operator-address endpoint (${BRIDGE_URL%/}/operator-address)"
    fi
  fi

  if (( failures > 0 )); then
    echo "doctor: FAILED (${failures} failures, ${warnings} warnings)" >&2
    return 1
  fi

  echo "doctor: OK (${warnings} warnings)"
}

onboard_cmd() {
  local skip_masumi=0
  local skip_deploy=0
  local skip_start_bridge=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-start-masumi)
        skip_masumi=1
        ;;
      --no-start-bridge)
        skip_start_bridge=1
        ;;
      --no-deploy)
        skip_deploy=1
        ;;
      *)
        echo "ERROR: unknown option: $1" >&2
        echo "Usage: bash sample-agent/agent.sh onboard [--no-start-masumi] [--no-start-bridge] [--no-deploy]" >&2
        return 1
        ;;
    esac
    shift
  done

  if [[ ! -f "$ENV_FILE" ]]; then
    info "sample-agent/.env missing; running init first"
    init_cmd
  fi

  load_env
  import_known_local_envs
  load_env

  # Interactive fallback for missing secrets when running in a TTY.
  prompt_missing_value "MASUMI_API_KEY" "Enter MASUMI_API_KEY (Masumi ADMIN_KEY)" 1 || true
  if [[ "$skip_deploy" -eq 0 ]]; then
    prompt_missing_value "BRIDGE_ADMIN_TOKEN" "Enter BRIDGE_ADMIN_TOKEN (optional, used for auto-deploy)" 1 || true
  fi
  load_env

  if [[ "$skip_masumi" -eq 0 ]]; then
    start_masumi_if_possible || true
  fi

  local bridge_dir bridge_health init_error
  bridge_dir="$(resolve_existing_dir "${BRIDGE_DIR:-}" "${ROOT_DIR}/../nightpay-ob/nightpay-bridge" "${ROOT_DIR}/../nightpay-bridge" "${ROOT_DIR}/bridge" || true)"

  if [[ "$skip_start_bridge" -eq 0 && -n "$bridge_dir" ]]; then
    start_bridge_if_possible "$bridge_dir" || true
  fi

  bridge_health="$(curl -sf --max-time 10 "${BRIDGE_URL%/}/health" 2>/dev/null || true)"
  init_error="$(parse_bridge_health_field "$bridge_health" "initError" 2>/dev/null || true)"

  if [[ "$init_error" == *"Compiled contract not found"* && -n "$bridge_dir" ]]; then
    compile_bridge_if_needed "$bridge_dir" || true
    if [[ "$skip_start_bridge" -eq 0 ]]; then
      start_bridge_if_possible "$bridge_dir" || true
    fi
    bridge_health="$(curl -sf --max-time 10 "${BRIDGE_URL%/}/health" 2>/dev/null || true)"
    init_error="$(parse_bridge_health_field "$bridge_health" "initError" 2>/dev/null || true)"
  fi

  local sync_args=(--soft)
  if [[ "$skip_deploy" -eq 0 ]] && ! is_placeholder "${BRIDGE_ADMIN_TOKEN:-}"; then
    sync_args+=(--deploy-if-missing)
  fi
  sync_addresses_cmd "${sync_args[@]}" || true
  load_env

  info "onboard summary:"
  if is_placeholder "${MASUMI_API_KEY:-}"; then warn "MASUMI_API_KEY: missing"; else info "MASUMI_API_KEY: configured ($(mask_value "${MASUMI_API_KEY:-}"))"; fi
  if [[ "${OPERATOR_ADDRESS:-}" =~ ^[0-9a-f]{64}$ ]]; then info "OPERATOR_ADDRESS: configured"; else warn "OPERATOR_ADDRESS: missing/invalid"; fi
  if [[ "${RECEIPT_CONTRACT_ADDRESS:-}" =~ ^[0-9a-f]{64}$ ]]; then info "RECEIPT_CONTRACT_ADDRESS: configured"; else warn "RECEIPT_CONTRACT_ADDRESS: missing/invalid"; fi

  if [[ -n "$init_error" ]]; then
    warn "Bridge initError: ${init_error}"
    if [[ "$init_error" == *"WALLET_SEED not set"* ]]; then
      warn "Set WALLET_SEED in bridge .env, then restart bridge."
    fi
    if [[ "$init_error" == *"OPERATOR_ADDRESS not set"* ]]; then
      warn "Set OPERATOR_ADDRESS in bridge .env (64-char lowercase hex), then restart bridge."
    fi
    if [[ "$init_error" == *"RECEIPT_CONTRACT_ADDRESS not set"* ]]; then
      warn "Contract not deployed on bridge yet; rerun onboard without --no-deploy once token is set."
    fi
  fi

  if is_placeholder "${BRIDGE_ADMIN_TOKEN:-}" && [[ "$skip_deploy" -eq 0 ]]; then
    warn "BRIDGE_ADMIN_TOKEN missing. Auto-deploy skipped."
    warn "Set BRIDGE_ADMIN_TOKEN (or OPERATOR_SECRET_KEY in bridge .env), then rerun onboard."
  fi

  doctor_cmd
}

post_cmd() {
  local amount="${1:-}"
  if [[ -z "$amount" ]]; then
    echo "Usage: bash sample-agent/agent.sh post <amount_specks> [--desc \"<description>\"]" >&2
    exit 1
  fi
  if ! [[ "$amount" =~ ^[0-9]+$ ]]; then
    echo "ERROR: amount_specks must be a positive integer" >&2
    exit 1
  fi

  shift || true
  local description=""
  if [[ "${1:-}" == "--desc" ]]; then
    description="${2:-}"
    if [[ -z "$description" ]]; then
      echo "ERROR: --desc requires a non-empty value" >&2
      exit 1
    fi
  else
    echo "Enter bounty description (single line, not saved by this script):" >&2
    IFS= read -r description
  fi

  if [[ -z "$description" ]]; then
    echo "ERROR: description is required" >&2
    exit 1
  fi

  load_env
  mkdir -p "$RATE_LIMIT_DIR"
  export RATE_LIMIT_DIR
  export ALLOW_LOCAL_URLS="${ALLOW_LOCAL_URLS:-1}"

  bash "$GATEWAY_SCRIPT" post-bounty "$description" "$amount"
}

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  init)
    init_cmd "${1:-}"
    ;;
  onboard)
    onboard_cmd "$@"
    ;;
  doctor)
    doctor_cmd
    ;;
  sync-addresses)
    sync_addresses_cmd "$@"
    ;;
  post)
    post_cmd "$@"
    ;;
  post-checked)
    doctor_cmd
    post_cmd "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "ERROR: unknown command: ${COMMAND}" >&2
    usage
    exit 1
    ;;
esac
