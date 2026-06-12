#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_step() {
  local label="$1"
  local script="$2"
  echo
  echo "==== $label ===="
  if [[ ! -f "$ROOT_DIR/$script" ]] && git -C "$ROOT_DIR" check-ignore -q "$script" 2>/dev/null; then
    echo "[PASS] skipped (gitignored private): $script"
    return 0
  fi
  bash "$ROOT_DIR/$script"
}

echo "NightPay quality gate"
echo "root: $ROOT_DIR"

run_step "Script sanity" "test/script-sanity.sh"
run_step "Server sync CLI" "test/server-sync-start-args.sh"
run_step "MIP-003 strict mode" "test/mip003-strict.sh"
run_step "Smoke suite" "test/smoke.sh"
run_step "Bridge runtime" "test/bridge-runtime.sh"

echo
echo "Quality gate PASSED"
