#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.agent-playground.env"
STATE_DIR="${ROOT_DIR}/.agent-playground"
RUN_DIR="${STATE_DIR}/run"
LOG_DIR="${STATE_DIR}/logs"
MIP_PID_FILE="${RUN_DIR}/mip003.pid"
UI_PID_FILE="${RUN_DIR}/ui.pid"
MIP_LOG_FILE="${LOG_DIR}/mip003.log"
UI_LOG_FILE="${LOG_DIR}/ui.log"

PYTHON_CMD=()

usage() {
  cat <<'EOF'
Usage:
  bash scripts/agent-playground-setup.sh init [--force] [--dummy]
  bash scripts/agent-playground-setup.sh start
  bash scripts/agent-playground-setup.sh stop
  bash scripts/agent-playground-setup.sh doctor
  bash scripts/agent-playground-setup.sh status
  bash scripts/agent-playground-setup.sh ops-token [minutes]

  init --dummy  — fills MASUMI_API_KEY, OPERATOR_ADDRESS, RECEIPT_CONTRACT_ADDRESS,
                  BRIDGE_ADMIN_TOKEN with random 64-char hex so gateway/MIP start and
                  doctor pass format checks. Replace MASUMI_API_KEY with Masumi ADMIN_KEY
                  before real registry/payment calls; replace addresses from the bridge
                  when going on-chain.
EOF
}

detect_python() {
  if command -v python3 >/dev/null 2>&1; then
    local py3
    py3="$(command -v python3)"
    if [[ "$py3" != *"WindowsApps"* ]]; then
      PYTHON_CMD=(python3)
      return 0
    fi
  fi
  if command -v python >/dev/null 2>&1; then
    PYTHON_CMD=(python)
    return 0
  fi
  if command -v py >/dev/null 2>&1; then
    PYTHON_CMD=(py -3)
    return 0
  fi
  return 1
}

generate_hex_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 | tr -d '[:space:]'
    return 0
  fi

  detect_python || {
    echo "ERROR: openssl or python3/python/py is required to generate secrets." >&2
    exit 1
  }

  "${PYTHON_CMD[@]}" - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

ensure_dirs() {
  mkdir -p "$RUN_DIR" "$LOG_DIR"
}

is_pid_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

stop_pid() {
  local name="$1"
  local pid_file="$2"
  if ! [[ -f "$pid_file" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    echo "stopped: $name (pid $pid)"
  fi
  rm -f "$pid_file"
}

start_process() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  shift 3

  if is_pid_running "$pid_file"; then
    local running_pid
    running_pid="$(cat "$pid_file")"
    echo "already running: $name (pid $running_pid)"
    return 0
  fi

  nohup "$@" >>"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" >"$pid_file"
  sleep 1

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: failed to start $name. Check log: $log_file" >&2
    tail -n 40 "$log_file" >&2 || true
    rm -f "$pid_file"
    exit 1
  fi

  echo "started: $name (pid $pid)"
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  [[ "$value" == *"<fill-in:"* ]] && return 0
  [[ "$value" == *"<fill-in "* ]] && return 0
  [[ "$value" == "<64-char-lowercase-hex>" ]] && return 0
  [[ "$value" == "your-key" ]] && return 0
  return 1
}

load_env() {
  [[ -f "$ENV_FILE" ]] || {
    echo "ERROR: missing $ENV_FILE. Run: bash scripts/agent-playground-setup.sh init" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

init_cmd() {
  local force=0
  local dummy=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --dummy) dummy=1 ;;
      *)
        echo "ERROR: unknown init option: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  if [[ -f "$ENV_FILE" && "$force" -ne 1 ]]; then
    echo "ERROR: $ENV_FILE already exists. Use init --force to regenerate." >&2
    exit 1
  fi

  ensure_dirs

  local job_token_secret
  local operator_secret_key
  job_token_secret="$(generate_hex_32)"
  operator_secret_key="$(generate_hex_32)"

  local masumi_api_key
  if [[ ! -f "${ROOT_DIR}/ui/package.json" ]]; then
    echo "WARN: ui/ submodule missing. Run: bash scripts/submodule-init.sh" >&2
  fi
  if [[ ! -f "${ROOT_DIR}/bridge/package.json" ]]; then
    echo "WARN: bridge/ submodule missing. Run: bash scripts/submodule-init.sh" >&2
  fi

  local operator_address
  local receipt_contract_address
  local bridge_admin_token
  local dummy_banner=""

  if [[ "$dummy" -eq 1 ]]; then
    masumi_api_key="$(generate_hex_32)"
    operator_address="$(generate_hex_32)"
    receipt_contract_address="$(generate_hex_32)"
    bridge_admin_token="$(generate_hex_32)"
    dummy_banner="# DUMMY init: MASUMI_API_KEY is random hex — replace with Masumi ADMIN_KEY for real API auth.
# Replace OPERATOR_ADDRESS / RECEIPT_CONTRACT_ADDRESS / BRIDGE_ADMIN_TOKEN from the bridge when going on-chain."
  else
    masumi_api_key="<fill-in: your ADMIN_KEY from Masumi .env>"
    operator_address="<fill-in: 64-char hex from bridge /operator-address>"
    receipt_contract_address="<fill-in: 64-char hex from bridge /deploy>"
    bridge_admin_token="<fill-in: deploy bearer token for bridge /deploy>"
  fi

  cat >"$ENV_FILE" <<EOF
# NightPay agent playground environment
# Generated by scripts/agent-playground-setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
${dummy_banner}
export MIDNIGHT_NETWORK="preprod"
export MIP_PORT="8090"
export UI_PORT="3333"
export ENABLE_UI="1"
export JOB_TOKEN_SECRET="${job_token_secret}"
export OPERATOR_SECRET_KEY="${operator_secret_key}"
export MASUMI_PAYMENT_URL="http://127.0.0.1:3001/api/v1"
export MASUMI_REGISTRY_URL="http://127.0.0.1:3000/api/v1"
export MASUMI_API_KEY="${masumi_api_key}"
export OPERATOR_ADDRESS="${operator_address}"
export RECEIPT_CONTRACT_ADDRESS="${receipt_contract_address}"
export BRIDGE_URL="http://localhost:4000"
export NIGHTPAY_API_URL="http://localhost:\${MIP_PORT}"
export BRIDGE_ADMIN_TOKEN="${bridge_admin_token}"
export ALLOW_LOCAL_URLS="1"
EOF

  chmod 600 "$ENV_FILE" 2>/dev/null || true
  echo "created: $ENV_FILE"
  if [[ "$dummy" -eq 1 ]]; then
    echo "dummy mode: env loads and doctor can pass; set MASUMI_API_KEY to Masumi ADMIN_KEY before hire/pay."
  else
    echo "next: edit MASUMI_API_KEY, OPERATOR_ADDRESS, RECEIPT_CONTRACT_ADDRESS, BRIDGE_URL as needed"
  fi
}

start_cmd() {
  ensure_dirs
  load_env

  command -v bash >/dev/null 2>&1 || { echo "ERROR: bash not found in PATH" >&2; exit 1; }
  command -v node >/dev/null 2>&1 || { echo "ERROR: node not found in PATH" >&2; exit 1; }
  command -v npm >/dev/null 2>&1 || { echo "ERROR: npm not found in PATH" >&2; exit 1; }

  local mip_port="${MIP_PORT:-8090}"
  local ui_port="${UI_PORT:-3333}"
  local ui_enabled="${ENABLE_UI:-1}"
  local ui_package="${ROOT_DIR}/ui/package.json"

  start_process \
    "mip003-server" \
    "$MIP_PID_FILE" \
    "$MIP_LOG_FILE" \
    bash "$ROOT_DIR/skills/nightpay/scripts/mip003-server.sh" "$mip_port"

  if [[ "$ui_enabled" == "1" ]]; then
    if [[ -f "$ui_package" ]]; then
      start_process \
        "ui-dev-server" \
        "$UI_PID_FILE" \
        "$UI_LOG_FILE" \
        npm run dev --prefix "$ROOT_DIR/ui" -- --host 0.0.0.0 --port "$ui_port"
    else
      echo "WARN: ui/ missing at $ROOT_DIR/ui; skipping UI start (set ENABLE_UI=0 to silence)."
      rm -f "$UI_PID_FILE"
    fi
  else
    echo "UI start skipped (ENABLE_UI=$ui_enabled)."
    rm -f "$UI_PID_FILE"
  fi

  echo "logs:"
  echo "  $MIP_LOG_FILE"
  if [[ "$ui_enabled" == "1" && -f "$ui_package" ]]; then
    echo "  $UI_LOG_FILE"
  fi
}

stop_cmd() {
  stop_pid "ui-dev-server" "$UI_PID_FILE"
  stop_pid "mip003-server" "$MIP_PID_FILE"
}

status_cmd() {
  if is_pid_running "$MIP_PID_FILE"; then
    echo "mip003: running (pid $(cat "$MIP_PID_FILE"))"
  else
    echo "mip003: stopped"
  fi
  if is_pid_running "$UI_PID_FILE"; then
    echo "ui: running (pid $(cat "$UI_PID_FILE"))"
  else
    echo "ui: stopped"
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
  command -v node >/dev/null 2>&1 && pass "tool: node" || fail "tool: node"
  command -v npm >/dev/null 2>&1 && pass "tool: npm" || fail "tool: npm"
  detect_python && pass "tool: python3" || fail "tool: python3"

  if [[ -f "$ENV_FILE" ]]; then
    pass "env file present"
    load_env
  else
    fail "env file present"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    is_placeholder "${JOB_TOKEN_SECRET:-}" && fail "JOB_TOKEN_SECRET" || pass "JOB_TOKEN_SECRET"
    is_placeholder "${OPERATOR_SECRET_KEY:-}" && fail "OPERATOR_SECRET_KEY" || pass "OPERATOR_SECRET_KEY"
    is_placeholder "${MASUMI_API_KEY:-}" && fail "MASUMI_API_KEY" || pass "MASUMI_API_KEY"

    local mip_port="${MIP_PORT:-8090}"
    local ui_port="${UI_PORT:-3333}"
    local ui_enabled="${ENABLE_UI:-1}"
    local ui_package="${ROOT_DIR}/ui/package.json"
    local code

    curl -fsS --max-time 5 "http://localhost:${mip_port}/availability" >/dev/null \
      && pass "MIP endpoint: /availability" || fail "MIP endpoint: /availability"
    curl -fsS --max-time 5 "http://localhost:${mip_port}/input_schema" >/dev/null \
      && pass "MIP endpoint: /input_schema" || fail "MIP endpoint: /input_schema"
    curl -fsS --max-time 5 "http://localhost:${mip_port}/ontology" >/dev/null \
      && pass "MIP endpoint: /ontology" || fail "MIP endpoint: /ontology"

    if [[ "$ui_enabled" != "1" ]]; then
      pass "UI endpoint: skipped (ENABLE_UI=$ui_enabled)"
    elif [[ ! -f "$ui_package" ]]; then
      warn "UI endpoint skipped (ui/ submodule missing)"
    else
      code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${ui_port}/" || echo "000")"
      if [[ "$code" == "200" ]]; then
        pass "UI endpoint: /"
      else
        fail "UI endpoint: /"
      fi
    fi

    curl -fsS --max-time 5 "http://localhost:3001/docs" >/dev/null \
      && pass "Masumi payment API" || warn "Masumi payment API"
    curl -fsS --max-time 5 "http://localhost:3000/docs" >/dev/null \
      && pass "Masumi registry API" || warn "Masumi registry API"
  fi

  # Public surface checks (Caddy + TLS + DNS). Activated automatically on production
  # deploys when .agent-playground.env overrides BRIDGE_URL / NIGHTPAY_API_URL / *_URL
  # to https://*.nightpay.dev (or equivalent). Local playground keeps using localhost
  # paths only — no behavior change. This directly surfaces ERR_SSL_PROTOCOL_ERROR,
  # cert expiry, Caddy not running, firewall blocks on 443, etc.
  local did_public_check=0
  check_public() {
    local label="$1"
    local url="$2"
    [[ -z "$url" ]] && return 0
    if [[ "$url" =~ ^https?://(localhost|127\.0\.0\.1) ]]; then return 0; fi
    did_public_check=1
    local code err
    code="$(curl -sS -L --max-time 15 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
    if [[ "$code" == "200" ]]; then
      pass "public: $label"
    else
      err="$(curl -sS -L --max-time 15 -o /dev/null -w '%{errormsg}' "$url" 2>&1 || true)"
      if [[ "$err" =~ (SSL|certificate|handshake|protocol|verify|timed? ?out) || "$code" == "000" ]]; then
        fail "public: $label — TLS/SSL or connect error: $err (HTTP $code) url=$url"
      else
        fail "public: $label — HTTP $code url=$url"
      fi
    fi
  }

  check_public "API /availability (Caddy TLS)" "${NIGHTPAY_API_URL:+${NIGHTPAY_API_URL%/}/availability}"
  check_public "Bridge /health (Caddy TLS)" "${BRIDGE_URL:+${BRIDGE_URL%/}/health}"
  if [[ -n "${SITE_URL:-}" ]]; then
    check_public "Site root (Caddy static + TLS)" "$SITE_URL"
  fi
  if [[ -n "${BOARD_URL:-}" ]]; then
    check_public "Board (Caddy static + TLS)" "$BOARD_URL"
  fi
  if [[ $did_public_check -eq 1 ]]; then
    pass "public TLS surface exercised via Caddy (nightpay.dev etc)"
  fi

  if [[ "$failures" -gt 0 ]]; then
    echo "doctor result: FAIL (${failures} failures, ${warnings} warnings)"
    exit 1
  fi

  echo "doctor result: PASS (${warnings} warnings)"
}

ops_token_cmd() {
  load_env
  [[ -n "${OPERATOR_SECRET_KEY:-}" ]] || {
    echo "ERROR: OPERATOR_SECRET_KEY not set in $ENV_FILE" >&2
    exit 1
  }
  local minutes="${1:-15}"
  if ! [[ "$minutes" =~ ^[0-9]+$ ]] || [[ "$minutes" -lt 1 ]] || [[ "$minutes" -gt 1440 ]]; then
    echo "ERROR: minutes must be 1–1440 (default 15)" >&2
    exit 1
  fi
  detect_python || {
    echo "ERROR: python3/python required for ops-token" >&2
    exit 1
  }
  local token
  token="$("${PYTHON_CMD[@]}" - "$minutes" "$OPERATOR_SECRET_KEY" <<'PY'
import hmac, hashlib, time, sys
minutes = int(sys.argv[1])
secret = sys.argv[2]
expiry = int(time.time()) + 60 * minutes
msg = f"ops:{expiry}"
sig = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(f"ops.{expiry}.{sig}")
PY
)"
  echo "$token"
  echo "" >&2
  echo "Paste the line above into the site at /ops (valid ${minutes} min). Do not share." >&2
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    init)
      shift
      init_cmd "$@"
      ;;
    start)
      start_cmd
      ;;
    stop)
      stop_cmd
      ;;
    doctor)
      doctor_cmd
      ;;
    status)
      status_cmd
      ;;
    ops-token)
      shift
      ops_token_cmd "${1:-15}"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "ERROR: unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
