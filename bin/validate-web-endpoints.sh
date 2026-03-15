#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash bin/validate-web-endpoints.sh \
    --env-name <production|staging> \
    --site-url <https-url> \
    --board-url <https-url> \
    --api-url <https://.../availability> \
    --bridge-url <https://.../health>
EOF
}

ENV_NAME=""
SITE_URL=""
BOARD_URL=""
API_URL=""
BRIDGE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-name)
      ENV_NAME="${2:-}"
      shift 2
      ;;
    --site-url)
      SITE_URL="${2:-}"
      shift 2
      ;;
    --board-url)
      BOARD_URL="${2:-}"
      shift 2
      ;;
    --api-url)
      API_URL="${2:-}"
      shift 2
      ;;
    --bridge-url)
      BRIDGE_URL="${2:-}"
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

if [[ -z "$ENV_NAME" || -z "$SITE_URL" || -z "$BOARD_URL" || -z "$API_URL" || -z "$BRIDGE_URL" ]]; then
  echo "ERROR: missing required args." >&2
  usage
  exit 1
fi

failures=0

check_page_200() {
  local label="$1"
  local url="$2"
  local code
  code="$(curl -sS -L --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)"
  if [[ "$code" != "200" ]]; then
    echo "FAIL: ${label} expected 200, got ${code} (${url})" >&2
    failures=$((failures + 1))
  else
    echo "PASS: ${label} returned 200 (${url})"
  fi
}

check_json_field() {
  local label="$1"
  local url="$2"
  local field="$3"

  local tmp_body code
  tmp_body="$(mktemp)"
  code="$(curl -sS --max-time 20 -o "$tmp_body" -w '%{http_code}' "$url" || true)"

  if [[ "$code" != "200" ]]; then
    echo "FAIL: ${label} expected 200, got ${code} (${url})" >&2
    failures=$((failures + 1))
    rm -f "$tmp_body"
    return
  fi

  if ! python - "$field" "$tmp_body" <<'PY'
import json
import sys

field = sys.argv[1]
path = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
payload = json.loads(raw)
if field not in payload:
    raise SystemExit(1)
PY
  then
    echo "FAIL: ${label} returned invalid JSON or missing field '${field}' (${url})" >&2
    failures=$((failures + 1))
    rm -f "$tmp_body"
    return
  fi

  rm -f "$tmp_body"
  echo "PASS: ${label} returned 200 with JSON field '${field}' (${url})"
}

echo "Validating public web endpoints for ${ENV_NAME}..."
check_page_200 "site" "$SITE_URL"
check_page_200 "board" "$BOARD_URL"
check_json_field "api availability" "$API_URL" "status"
check_json_field "bridge health" "$BRIDGE_URL" "status"

if [[ "$failures" -gt 0 ]]; then
  echo "Web validation failed for ${ENV_NAME}: ${failures} check(s) failed." >&2
  exit 1
fi

echo "Web validation passed for ${ENV_NAME}."
