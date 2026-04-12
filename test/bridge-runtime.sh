#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/bridge"

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

require_cmd curl
require_cmd node
require_cmd npm
require_cmd "$PYTHON_BIN"

if [[ ! -d "$BRIDGE_DIR" || ! -f "$BRIDGE_DIR/package.json" ]]; then
  echo "[SKIP] bridge runtime checks (bridge/ not present)"
  exit 0
fi

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
  local delay="${3:-0.25}"
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

TMP_DIR="$(mktemp -d 2>/dev/null || true)"
if [[ -z "$TMP_DIR" ]]; then
  TMP_DIR="$("$PYTHON_BIN" - <<'PY'
import tempfile
print(tempfile.mkdtemp(prefix='nightpay-bridge-runtime-'))
PY
)"
fi

echo "== Bridge build =="
if (cd "$BRIDGE_DIR" && npm run build >"$TMP_DIR/bridge-build.log" 2>&1); then
  pass "bridge build succeeds"
else
  fail "bridge build succeeds"
fi

echo
echo "== Bridge runtime =="
PORT="$(free_port)"
BRIDGE_URL="http://127.0.0.1:${PORT}"

(
  cd "$BRIDGE_DIR"
  BRIDGE_PORT="$PORT" \
  BRIDGE_FORCE_STUB=1 \
  BRIDGE_INIT_TIMEOUT_MS=1000 \
  node dist/server.js
) >"$TMP_DIR/bridge-runtime.log" 2>&1 &
BRIDGE_PID=$!
PIDS+=("$BRIDGE_PID")

if wait_for_http "$BRIDGE_URL/health"; then
  pass "bridge server booted on :$PORT"
else
  fail "bridge server failed to boot"
fi

health_json="$(curl -sS --max-time 10 "$BRIDGE_URL/health")"
assert_eq "$(json_get "$health_json" "status")" "ok" "bridge /health status ok"
assert_eq "$(json_get "$health_json" "stub")" "true" "bridge /health reports stub mode"

stats_json="$(curl -sS --max-time 10 "$BRIDGE_URL/stats")"
assert_eq "$(json_get "$stats_json" "stub")" "true" "bridge /stats reports stub mode"

op_json="$(curl -sS --max-time 10 "$BRIDGE_URL/operator-address")"
assert_eq "$(json_get "$op_json" "network")" "preprod" "bridge /operator-address returns default network"

echo
echo "Summary: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
