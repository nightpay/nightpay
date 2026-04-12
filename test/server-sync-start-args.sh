#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/server-sync-start.sh"

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  }
}

require_cmd bash

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '[FAIL] %s\n' "$1"
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

run_capture() {
  local out_file="$TMP_DIR/cmd.out"
  local err_file="$TMP_DIR/cmd.err"
  set +e
  "$@" >"$out_file" 2>"$err_file"
  LAST_RC=$?
  set -e
  LAST_OUT="$(cat "$out_file")"
  LAST_ERR="$(cat "$err_file")"
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

LAST_OUT=""
LAST_ERR=""
LAST_RC=0

echo "== CLI validation checks =="
run_capture bash "$SCRIPT" --help
assert_eq "$LAST_RC" "0" "help exits 0"
assert_contains "$LAST_OUT" "--site-url" "help includes --site-url"
assert_contains "$LAST_OUT" "--api-url" "help includes --api-url"
assert_contains "$LAST_OUT" "--bridge-url" "help includes --bridge-url"
assert_contains "$LAST_OUT" "--require-onchain" "help includes --require-onchain"

run_capture bash "$SCRIPT" --unknown
assert_eq "$LAST_RC" "1" "unknown arg exits 1"
assert_contains "$LAST_ERR" "ERROR: unknown arg --unknown" "unknown arg reports clear error"

run_capture bash "$SCRIPT"
assert_eq "$LAST_RC" "1" "missing required args exits 1"
assert_contains "$LAST_OUT" "Usage:" "missing args prints usage"

run_capture bash "$SCRIPT" --host example.com --ssh-key "$TMP_DIR/does-not-exist"
assert_eq "$LAST_RC" "1" "missing ssh key exits 1"
assert_contains "$LAST_ERR" "ERROR: SSH key not found" "missing ssh key reports clear error"

echo
echo "== Mocked remote execution checks =="

mkdir -p "$TMP_DIR/bin"
SSH_LOG="$TMP_DIR/ssh.log"
cat >"$TMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_SSH_LOG:?MOCK_SSH_LOG required}"
mock_arch="${MOCK_ARCH:-x86_64}"

argc=$#
if (( argc < 2 )); then
  exit 1
fi

# ssh [opts...] user@host "command"
dest="${@: -2:1}"
cmd="${@: -1}"
printf 'dest=%s\tcmd=%s\n' "$dest" "$cmd" >>"$log_file"

if [[ -p /dev/stdin ]]; then
  cat >/dev/null
fi

if [[ "$cmd" == *"uname -m"* ]]; then
  echo "$mock_arch"
  exit 0
fi
if [[ "$cmd" == *"echo connected:"* ]]; then
  echo "connected: mock-host"
  exit 0
fi
if [[ "$cmd" == *"backup_timestamp="* ]]; then
  echo "backup_timestamp=20260314-120000"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP_DIR/bin/ssh"

KEY_PATH="$TMP_DIR/hetzner_ed25519_martin"
printf 'dummy-key\n' >"$KEY_PATH"
chmod 600 "$KEY_PATH"

PATH="$TMP_DIR/bin:$PATH" MOCK_SSH_LOG="$SSH_LOG" run_capture bash "$SCRIPT" \
  --host mock.example \
  --ssh-key "$KEY_PATH" \
  --remote-dir /opt/nightpay \
  --site-url https://board.example.test \
  --api-url https://api.example.test \
  --bridge-url https://bridge.example.test \
  --skip-install \
  --require-onchain

assert_eq "$LAST_RC" "0" "mocked full run exits 0"
assert_contains "$LAST_OUT" "done." "mocked run reaches completion"

ssh_calls="$(cat "$SSH_LOG")"
assert_contains "$ssh_calls" "root@mock.example" "ssh targets configured host"
assert_contains "$ssh_calls" "SITE_URL='https://board.example.test'" "doctor command includes SITE_URL"
assert_contains "$ssh_calls" "API_URL='https://api.example.test'" "doctor command includes API_URL"
assert_contains "$ssh_calls" "BRIDGE_URL='https://bridge.example.test'" "doctor command includes BRIDGE_URL"
assert_contains "$ssh_calls" "REQUIRE_ONCHAIN='1'" "doctor command includes REQUIRE_ONCHAIN"

PATH="$TMP_DIR/bin:$PATH" MOCK_SSH_LOG="$SSH_LOG" MOCK_ARCH="aarch64" run_capture bash "$SCRIPT" \
  --host mock.example \
  --ssh-key "$KEY_PATH" \
  --skip-install
assert_eq "$LAST_RC" "1" "non-x86_64 remote arch fails fast"
assert_contains "$LAST_ERR" "expected x86_64 server" "arch mismatch error is explicit"

echo
echo "Summary: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
