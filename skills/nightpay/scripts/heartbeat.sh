#!/usr/bin/env bash
# NightPay OpenClaw heartbeat — runs HEARTBEAT.md checks (see skills/nightpay/HEARTBEAT.md).
#
# Env:
#   NIGHTPAY_API_URL   — MIP-003 base (default https://api.nightpay.dev)
#   BRIDGE_URL         — optional; when set, probes GET .../health
#   NIGHTPAY_SKILL_ROOT — directory containing SKILL.md (default: parent of scripts/)
#   NIGHTPAY_HEARTBEAT_STATE — override state JSON path
#   XDG_STATE_HOME     — default state: $XDG_STATE_HOME/nightpay/heartbeat-state.json
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NIGHTPAY_SKILL_ROOT="${NIGHTPAY_SKILL_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHON="${PYTHON:-python3}"
exec "$PYTHON" "$SCRIPT_DIR/heartbeat.py" "$@"
