#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
require_cmd "$PYTHON_BIN"

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

check_bash_syntax() {
  local rel="$1"
  local abs="$ROOT_DIR/$rel"
  if bash -n "$abs" >/dev/null 2>&1; then
    pass "bash syntax: $rel"
  else
    fail "bash syntax: $rel"
  fi
}

echo "== Shell syntax checks =="
shell_files=(
  "scripts/agent-playground-setup.sh"
  "scripts/load-sim.sh"
  "scripts/server-sync-start.sh"
  "skills/nightpay/scripts/bounty-board.sh"
  "skills/nightpay/scripts/gateway.sh"
  "skills/nightpay/scripts/heartbeat.sh"
  "skills/nightpay/scripts/mip003-server.sh"
  "skills/nightpay/scripts/update-blocklist.sh"
  "test/smoke.sh"
  "test/mip003-strict.sh"
  "test/bridge-runtime.sh"
  "test/server-sync-start-args.sh"
  "test/quality-gate.sh"
)

for rel in "${shell_files[@]}"; do
  if [[ -f "$ROOT_DIR/$rel" ]]; then
    check_bash_syntax "$rel"
  else
    fail "missing file: $rel"
  fi
done

echo
echo "== Python syntax checks =="
python_files=(
  "nightpay_sdk.py"
  "skills/nightpay/scripts/heartbeat.py"
  "test/chaos_stress_suite.py"
)

for rel in "${python_files[@]}"; do
  abs="$ROOT_DIR/$rel"
  if [[ ! -f "$abs" ]]; then
    fail "missing file: $rel"
    continue
  fi
  if "$PYTHON_BIN" -m py_compile "$abs" >/dev/null 2>&1; then
    pass "python compile: $rel"
  else
    fail "python compile: $rel"
  fi
done

tmp_py="$(mktemp)"
cleanup() {
  rm -f "$tmp_py"
}
trap cleanup EXIT

if "$PYTHON_BIN" - "$ROOT_DIR/skills/nightpay/scripts/mip003-server.sh" "$tmp_py" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
marker = "<<'PYCODE'\n"
start = source.find(marker)
if start < 0:
    raise SystemExit(1)
start += len(marker)
end = source.find("\nPYCODE\n", start)
if end < 0:
    raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_text(source[start:end], encoding='utf-8')
PY
then
  if "$PYTHON_BIN" -m py_compile "$tmp_py" >/dev/null 2>&1; then
    pass "python compile: embedded mip003-server block"
  else
    fail "python compile: embedded mip003-server block"
  fi
else
  fail "extract embedded python from mip003-server.sh"
fi

if "$PYTHON_BIN" "$ROOT_DIR/skills/nightpay/scripts/heartbeat.py" --selftest >/dev/null 2>&1; then
  pass "heartbeat.py --selftest"
else
  fail "heartbeat.py --selftest"
fi

echo
echo "== JSON integrity checks =="
if "$PYTHON_BIN" - "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
json_files = [
    root / "skills/nightpay/openclaw-fragment.json",
    root / "skills/nightpay/ontology/ontology.jsonld",
    root / "skills/nightpay/ontology/context.jsonld",
    root / "openclaw.plugin.json",
    root / "ui/public/skill.json",
]

examples_dir = root / "skills/nightpay/ontology/examples"
json_files.extend(sorted(examples_dir.glob("*.jsonld")))

for path in json_files:
    with path.open("r", encoding="utf-8") as fh:
        json.load(fh)
print("ok")
PY
then
  pass "json parse: skill + ontology + plugin payloads"
else
  fail "json parse: skill + ontology + plugin payloads"
fi

echo
echo "== Agent-readable surface alignment =="
# Cross-surface alignment: SKILL.md frontmatter <-> ui/public/skill.md (byte parity)
# <-> ui/public/skill.json (version + requires) <-> openclaw.plugin.json (version)
# <-> plugin.js (REQUIRED_ENV) <-> openclaw-fragment.json (env keys) <-> package.json.
# Run the single source-of-truth audit from docs/architecture.md § Skill distribution.
if "$PYTHON_BIN" "$ROOT_DIR/test/skill-readable.py" >/dev/null 2>&1; then
  pass "skill surface alignment: SKILL.md, skill.md, skill.json, plugin.js, manifests"
else
  fail "skill surface alignment: SKILL.md, skill.md, skill.json, plugin.js, manifests"
  "$PYTHON_BIN" "$ROOT_DIR/test/skill-readable.py" || true
fi

echo
echo "Summary: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
