#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIP_SCRIPT="$ROOT_DIR/skills/nightpay/scripts/mip003-server.sh"

PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
if [[ -z "$PYTHON_BIN" || "$PYTHON_BIN" == *"WindowsApps"* ]]; then
  PYTHON_BIN="$(command -v python 2>/dev/null || true)"
fi

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  }
}

require_cmd bash
require_cmd curl
require_cmd openssl
require_cmd "$PYTHON_BIN"

PASS=0
FAIL=0
PIDS=()

pass() {
  PASS=$((PASS + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '[FAIL] %s\n' "$1"
}

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

free_port() {
  "$PYTHON_BIN" - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_for_http() {
  local url="$1"
  local tries="${2:-120}"
  local delay="${3:-0.2}"
  local i
  for ((i = 1; i <= tries; i++)); do
    if curl -sf --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

json_get() {
  local json_input="$1"
  local path="$2"
  JSON_INPUT="$json_input" "$PYTHON_BIN" - "$path" <<'PY'
import json, os, sys
path = sys.argv[1]
raw = os.environ.get('JSON_INPUT', '')
data = json.loads(raw) if raw else {}
cur = data
for part in path.split('.'):
    if not part:
        continue
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur.get(part)
if isinstance(cur, bool):
    print('true' if cur else 'false', end='')
elif cur is None:
    print('', end='')
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, sort_keys=True, separators=(',', ':')), end='')
else:
    print(str(cur), end='')
PY
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$msg"
  else
    fail "$msg (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (missing '$needle')"
  fi
}

TMP_DIR="$(mktemp -d 2>/dev/null || true)"
if [[ -z "$TMP_DIR" ]]; then
  TMP_DIR="$("$PYTHON_BIN" - <<'PY'
import tempfile
print(tempfile.mkdtemp(prefix='nightpay-mip003-strict-'))
PY
)"
fi

PORT="$(free_port)"
BASE_URL="http://127.0.0.1:${PORT}"

echo "== Start strict MIP-003 server =="
(
  export DATA_DIR="$TMP_DIR/mip-data"
  export JOB_TOKEN_SECRET="$(openssl rand -hex 32)"
  export OPERATOR_SECRET_KEY="$(openssl rand -hex 32)"
  export OPERATOR_FEE_BPS=200
  export MIP003_MODE=strict
  bash "$MIP_SCRIPT" "$PORT"
) >"$TMP_DIR/mip003-strict.log" 2>&1 &
MIP_PID=$!
PIDS+=("$MIP_PID")

if wait_for_http "$BASE_URL/availability"; then
  pass "strict server booted on :$PORT"
else
  fail "strict server failed to boot"
fi

echo
echo "== Strict contract checks =="
schema_json="$(curl -sS --max-time 10 "$BASE_URL/input_schema")"
required_json="$(json_get "$schema_json" "required")"
assert_contains "$required_json" "agentIdentifier" "input_schema requires agentIdentifier in strict mode"
assert_contains "$required_json" "identifier_from_purchaser" "input_schema requires identifier_from_purchaser in strict mode"
assert_contains "$required_json" "input_data" "input_schema requires input_data in strict mode"

start_payload='{"agentIdentifier":"agent.strict.01","identifier_from_purchaser":"buyer.strict.01","input_data":{"description":"strict smoke job","amount_specks":42000}}'
start_json="$(curl -sS --max-time 10 -X POST "$BASE_URL/start_job" -H 'Content-Type: application/json' -d "$start_payload")"
job_id="$(json_get "$start_json" "id")"
job_token="$(json_get "$start_json" "legacy.job_token")"
assert_contains "$job_id" "-" "start_job returns strict id"
if [[ -n "$job_token" ]]; then
  pass "start_job returns legacy job token for private status auth"
else
  fail "start_job returns legacy job token for private status auth (empty token)"
fi

status_json="$(curl -sS --max-time 10 "$BASE_URL/status/$job_id" -H "Authorization: Bearer $job_token")"
schema_hash="$(json_get "$status_json" "input_schema_hash")"
schema_hash_len="${#schema_hash}"
assert_eq "$schema_hash_len" "64" "status exposes 64-char input_schema_hash"

missing_code="$(curl -sS --max-time 10 -o "$TMP_DIR/provide-missing.json" -w '%{http_code}' -X POST "$BASE_URL/provide_input?job_id=$job_id" -H 'Content-Type: application/json' -d "{\"job_id\":\"$job_id\",\"input_data\":{\"work\":\"strict smoke work\"}}")"
assert_eq "$missing_code" "400" "provide_input rejects missing input_schema_hash"
missing_body="$(cat "$TMP_DIR/provide-missing.json")"
assert_contains "$missing_body" "input_schema_hash is required" "missing hash returns explicit error"

wrong_hash="$(printf 'f%.0s' {1..64})"
if [[ "$wrong_hash" == "$schema_hash" ]]; then
  wrong_hash="$(printf 'e%.0s' {1..64})"
fi
wrong_code="$(curl -sS --max-time 10 -o "$TMP_DIR/provide-wrong.json" -w '%{http_code}' -X POST "$BASE_URL/provide_input?job_id=$job_id" -H 'Content-Type: application/json' -d "{\"job_id\":\"$job_id\",\"input_schema_hash\":\"$wrong_hash\",\"input_data\":{\"work\":\"strict smoke work\"}}")"
assert_eq "$wrong_code" "409" "provide_input rejects mismatched input_schema_hash"

status_id="$(json_get "$status_json" "status_id")"
ok_code="$(curl -sS --max-time 10 -o "$TMP_DIR/provide-ok.json" -w '%{http_code}' -X POST "$BASE_URL/provide_input?job_id=$job_id" -H 'Content-Type: application/json' -d "{\"job_id\":\"$job_id\",\"status_id\":\"$status_id\",\"input_schema_hash\":\"$schema_hash\",\"input_data\":{\"work\":\"strict smoke work\",\"artifact\":\"ok\"}}")"
assert_eq "$ok_code" "200" "provide_input accepts strict payload with input_schema_hash"

after_json="$(curl -sS --max-time 10 "$BASE_URL/status/$job_id" -H "Authorization: Bearer $job_token")"
assert_eq "$(json_get "$after_json" "status")" "running" "status remains running externally after provide_input"

echo
echo "Summary: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
