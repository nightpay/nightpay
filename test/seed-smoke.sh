#!/usr/bin/env bash
# seed-smoke.sh — smoke test for the rich seed-corpus feature.
# Covers:
#   1. /briefs (public index) — no auth required, filters by category/tag.
#   2. scripts/seed-corpus.sh — posts briefs through /start_job, records state,
#      re-runs are idempotent (SKIP count grows, no duplicate jobs).
#   3. /briefs/<job_id> auth matrix — anonymous (401) / bogus bearer (401) /
#      operator bearer (200) / unknown job (404).
#   4. GET /jobs projection — seeded jobs expose brief_id/title/category/
#      capability_tags at the top level (no fetch of the full brief needed).
#
# Runs the MIP-003 server directly. No bridge, no Masumi mock. Exits non-zero
# on any assertion failure. Uses the same helpers as voting-smoke.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIP_SCRIPT="$ROOT_DIR/skills/nightpay/scripts/mip003-server.sh"
SEED_SCRIPT="$ROOT_DIR/scripts/seed-corpus.sh"

PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
if [[ -z "$PYTHON_BIN" || "$PYTHON_BIN" == *"WindowsApps"* ]]; then
  PYTHON_BIN="$(command -v python 2>/dev/null || true)"
fi
if [[ -z "$PYTHON_BIN" ]]; then
  echo "ERROR: python3/python is required" >&2
  exit 1
fi

for cmd in bash curl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  }
done

if [[ ! -f "$MIP_SCRIPT" ]]; then
  echo "ERROR: mip003 script not found: $MIP_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$SEED_SCRIPT" ]]; then
  echo "ERROR: seed-corpus script not found: $SEED_SCRIPT" >&2
  exit 1
fi

# Python tempdir so paths round-trip on Git Bash / Windows (see voting-smoke.sh).
TMP_DIR="$("$PYTHON_BIN" - <<'PY'
import tempfile; print(tempfile.mkdtemp(prefix='nightpay-seed-'))
PY
)"
TMP_DIR="${TMP_DIR//\\//}"

PASS_COUNT=0
FAIL_COUNT=0
PIDS=()

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[PASS] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

cleanup() {
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
import sys; sys.stdout.write(str(s.getsockname()[1])); s.close()
PY
}

wait_for_http() {
  local url="$1"; local tries="${2:-120}"; local delay="${3:-0.2}"
  for ((i = 1; i <= tries; i++)); do
    if curl -sf --max-time 2 "$url" >/dev/null 2>&1; then return 0; fi
    sleep "$delay"
  done
  return 1
}

rand_hex64() {
  "$PYTHON_BIN" - <<'PY'
import secrets; print(secrets.token_hex(32))
PY
}

json_get() {
  JSON_INPUT="$1" "$PYTHON_BIN" - "$2" <<'PY'
import json, os, sys
path = sys.argv[1]
data = json.loads(os.environ.get('JSON_INPUT','') or '{}')
cur = data
for part in path.split('.'):
    if part == '':
        continue
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur.get(part) if isinstance(cur, dict) else None
if isinstance(cur, bool):
    sys.stdout.write('true' if cur else 'false')
elif cur is None:
    sys.stdout.write('')
elif isinstance(cur, (dict, list)):
    sys.stdout.write(json.dumps(cur, sort_keys=True, separators=(',', ':')))
else:
    sys.stdout.write(str(cur))
PY
}

http_req() {
  local method="$1"; local url="$2"; shift 2
  local body=""
  if [[ $# -gt 0 ]]; then body="$1"; shift; fi
  local out="$TMP_DIR/http.out"
  local bodyf="$TMP_DIR/http.body"
  : > "$out"
  if [[ -z "$body" ]]; then body='{}'; fi
  printf '%s' "$body" > "$bodyf"
  local args=(-sS -o "$out" -w "%{http_code}" -X "$method" --max-time 10)
  while [[ $# -gt 0 ]]; do args+=(-H "$1"); shift; done
  if [[ "$method" == "POST" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "@$bodyf")
  fi
  local code
  code="$(curl "${args[@]}" "$url" || true)"
  printf '%s\n' "$code"
  cat "$out"
}

# ── Start server ──────────────────────────────────────────────────────────────
section "Start MIP-003 server"
MIP_PORT="$(free_port)"
MIP_BASE="http://127.0.0.1:${MIP_PORT}"
DATA_DIR="$TMP_DIR/data"; mkdir -p "$DATA_DIR"
STATE_FILE="$TMP_DIR/seed-state.json"
JOB_TOKEN_SECRET="$(rand_hex64)"
OPERATOR_SECRET_KEY="$(rand_hex64)"

(
  export DATA_DIR JOB_TOKEN_SECRET OPERATOR_SECRET_KEY
  export OPERATOR_FEE_BPS=200
  export MIP003_MODE=compat
  bash "$MIP_SCRIPT" "$MIP_PORT"
) >"$TMP_DIR/mip.log" 2>&1 &
MIP_PID=$!
PIDS+=("$MIP_PID")

if wait_for_http "$MIP_BASE/availability"; then
  pass "mip003-server booted on :$MIP_PORT"
else
  fail "mip003-server failed to boot — see $TMP_DIR/mip.log"
  exit 1
fi

# ── Public /briefs index (no auth) ────────────────────────────────────────────
section "/briefs public index"
r="$(http_req GET "$MIP_BASE/briefs")"
c="$(printf '%s\n' "$r" | head -n1)"
bd="$(printf '%s\n' "$r" | tail -n +2)"
if [[ "$c" == "200" ]]; then pass "GET /briefs (anonymous) -> 200"; else fail "GET /briefs (anonymous) -> $c $bd"; fi
BRIEF_COUNT="$(json_get "$bd" "count")"
BRIEF_TOTAL="$(json_get "$bd" "total")"
if [[ "$BRIEF_COUNT" == "$BRIEF_TOTAL" && "$BRIEF_COUNT" -ge 20 ]]; then
  pass "/briefs returned $BRIEF_COUNT briefs (total=$BRIEF_TOTAL)"
else
  fail "/briefs count=$BRIEF_COUNT total=$BRIEF_TOTAL (expected count==total and >= 20)"
fi

# Assert the index does not leak body text (public endpoint == metadata only).
HAS_BODY="$("$PYTHON_BIN" - <<PY
import json
d=json.loads('''$bd''')
for b in d.get('briefs', []):
    if 'body' in b:
        print('leak'); raise SystemExit
print('ok')
PY
)"
if [[ "$HAS_BODY" == "ok" ]]; then pass "/briefs does not leak body text"; else fail "/briefs leaks body text on public index"; fi

# Pick a known brief_id for later tests.
SEED_BRIEF_ID="$("$PYTHON_BIN" - <<PY
import json
d=json.loads('''$bd''')
rows=[b for b in d.get('briefs', []) if b.get('category')=='audit']
print(rows[0]['brief_id'] if rows else '')
PY
)"
if [[ -n "$SEED_BRIEF_ID" ]]; then
  pass "picked sample brief_id=$SEED_BRIEF_ID"
else
  fail "no audit brief available in /briefs index"
  exit 1
fi

# ── /briefs?category=audit filter ─────────────────────────────────────────────
section "/briefs category filter"
r="$(http_req GET "$MIP_BASE/briefs?category=audit")"
c="$(printf '%s\n' "$r" | head -n1)"
bd="$(printf '%s\n' "$r" | tail -n +2)"
ONLY_AUDIT="$("$PYTHON_BIN" - <<PY
import json
d=json.loads('''$bd''')
cats={b.get('category') for b in d.get('briefs', [])}
print('ok' if cats == {'audit'} and d.get('count') == len(d.get('briefs', [])) else f'bad:{cats}')
PY
)"
if [[ "$c" == "200" && "$ONLY_AUDIT" == "ok" ]]; then
  pass "/briefs?category=audit returns only audit briefs"
else
  fail "/briefs?category=audit -> $c filter-check=$ONLY_AUDIT"
fi

r="$(http_req GET "$MIP_BASE/briefs?category=bogus")"
c="$(printf '%s\n' "$r" | head -n1)"
if [[ "$c" == "400" ]]; then pass "/briefs bogus category rejected (400)"; else fail "/briefs bogus category -> $c"; fi

# ── Seeder (fresh run) ────────────────────────────────────────────────────────
section "scripts/seed-corpus.sh (fresh run)"
SEED_OUT="$TMP_DIR/seed1.log"
(
  export OPERATOR_SECRET_KEY
  bash "$SEED_SCRIPT" --base-url "$MIP_BASE" --state-file "$STATE_FILE" --only audit --limit 4
) >"$SEED_OUT" 2>&1
SEED_EXIT=$?
if [[ $SEED_EXIT -eq 0 ]]; then
  pass "seeder exit=0 on first run"
else
  fail "seeder first run exit=$SEED_EXIT — see $SEED_OUT"
  cat "$SEED_OUT"
fi
POSTED_LINE="$(grep -E 'DONE posted=' "$SEED_OUT" | tail -n1 || true)"
if [[ "$POSTED_LINE" == *"posted=4"* && "$POSTED_LINE" == *"reused=0"* && "$POSTED_LINE" == *"errors=0"* ]]; then
  pass "seeder first run: $POSTED_LINE"
else
  fail "seeder first run summary unexpected: $POSTED_LINE"
fi

if [[ -f "$STATE_FILE" ]]; then
  STATE_JOB_COUNT="$("$PYTHON_BIN" - <<PY
import json
print(len(json.load(open(r'''$STATE_FILE''')).get('jobs', {})))
PY
)"
  if [[ "$STATE_JOB_COUNT" == "4" ]]; then
    pass "state file recorded 4 jobs"
  else
    fail "state file job count=$STATE_JOB_COUNT (expected 4)"
  fi
else
  fail "state file missing: $STATE_FILE"
fi

# ── Seeder (idempotent re-run) ────────────────────────────────────────────────
section "scripts/seed-corpus.sh (re-run is idempotent)"
SEED_OUT2="$TMP_DIR/seed2.log"
(
  export OPERATOR_SECRET_KEY
  bash "$SEED_SCRIPT" --base-url "$MIP_BASE" --state-file "$STATE_FILE" --only audit --limit 4
) >"$SEED_OUT2" 2>&1
SEED_EXIT2=$?
if [[ $SEED_EXIT2 -eq 0 ]]; then
  pass "seeder exit=0 on re-run"
else
  fail "seeder re-run exit=$SEED_EXIT2 — see $SEED_OUT2"
fi
POSTED_LINE2="$(grep -E 'DONE posted=' "$SEED_OUT2" | tail -n1 || true)"
if [[ "$POSTED_LINE2" == *"posted=0"* && "$POSTED_LINE2" == *"reused=4"* && "$POSTED_LINE2" == *"errors=0"* ]]; then
  pass "seeder re-run reused existing jobs: $POSTED_LINE2"
else
  fail "seeder re-run summary unexpected: $POSTED_LINE2"
fi

# ── Pull a seeded job_id for auth-matrix tests ────────────────────────────────
SEEDED_JOB_ID="$("$PYTHON_BIN" - <<PY
import json
data=json.load(open(r'''$STATE_FILE'''))
jobs=data.get('jobs') or {}
for k,v in sorted(jobs.items()):
    if v.get('job_id'):
        print(v['job_id']); break
PY
)"
if [[ -n "$SEEDED_JOB_ID" ]]; then
  pass "captured seeded job_id=$SEEDED_JOB_ID"
else
  fail "could not find a seeded job_id in state file"
  exit 1
fi

# ── /briefs/<job_id> auth matrix ──────────────────────────────────────────────
section "/briefs/<job_id> auth matrix"

# (a) Anonymous -> 401
r="$(http_req GET "$MIP_BASE/briefs/$SEEDED_JOB_ID")"
c="$(printf '%s\n' "$r" | head -n1)"
if [[ "$c" == "401" ]]; then pass "anonymous -> 401"; else fail "anonymous -> $c"; fi

# (b) Bogus operator bearer -> 401
BAD_BEARER="$(rand_hex64)"
r="$(http_req GET "$MIP_BASE/briefs/$SEEDED_JOB_ID" "" "Authorization: Bearer $BAD_BEARER")"
c="$(printf '%s\n' "$r" | head -n1)"
if [[ "$c" == "401" ]]; then pass "bogus bearer -> 401"; else fail "bogus bearer -> $c"; fi

# (c) Malformed X-Agent-Token -> 401 (fails signature; no fallthrough to 200)
r="$(http_req GET "$MIP_BASE/briefs/$SEEDED_JOB_ID" "" "X-Agent-Token: npaid.bogus.0.deadbeef")"
c="$(printf '%s\n' "$r" | head -n1)"
if [[ "$c" == "401" ]]; then pass "bogus X-Agent-Token -> 401"; else fail "bogus X-Agent-Token -> $c"; fi

# (d) Valid operator bearer -> 200 + full brief
r="$(http_req GET "$MIP_BASE/briefs/$SEEDED_JOB_ID" "" "Authorization: Bearer $OPERATOR_SECRET_KEY")"
c="$(printf '%s\n' "$r" | head -n1)"
bd="$(printf '%s\n' "$r" | tail -n +2)"
if [[ "$c" == "200" ]]; then pass "operator bearer -> 200"; else fail "operator bearer -> $c $bd"; fi
RET_BRIEF_ID="$(json_get "$bd" "brief_id")"
RET_BODY="$(json_get "$bd" "body")"
RET_CAT="$(json_get "$bd" "category")"
if [[ -n "$RET_BRIEF_ID" && -n "$RET_BODY" && "$RET_CAT" == "audit" ]]; then
  pass "full brief returned: brief_id=$RET_BRIEF_ID category=$RET_CAT (body=${#RET_BODY} chars)"
else
  fail "full brief incomplete: brief_id=$RET_BRIEF_ID category=$RET_CAT body_len=${#RET_BODY}"
fi

# (e) Unknown job -> 404 (operator auth passes, no job row matches)
UNKNOWN_JOB="$(rand_hex64)"
r="$(http_req GET "$MIP_BASE/briefs/$UNKNOWN_JOB" "" "Authorization: Bearer $OPERATOR_SECRET_KEY")"
c="$(printf '%s\n' "$r" | head -n1)"
if [[ "$c" == "404" ]]; then pass "unknown job_id -> 404 (after auth)"; else fail "unknown job_id -> $c"; fi

# (f) Bad job_id format -> 400
r="$(http_req GET "$MIP_BASE/briefs/%21nope" "" "Authorization: Bearer $OPERATOR_SECRET_KEY")"
c="$(printf '%s\n' "$r" | head -n1)"
if [[ "$c" == "400" ]]; then pass "invalid job_id shape -> 400"; else fail "invalid job_id shape -> $c"; fi

# ── GET /jobs projects brief_id / title / capability_tags / category ──────────
section "GET /jobs projection"
r="$(http_req GET "$MIP_BASE/jobs?limit=50&visibility=public")"
c="$(printf '%s\n' "$r" | head -n1)"
bd="$(printf '%s\n' "$r" | tail -n +2)"
if [[ "$c" == "200" ]]; then pass "GET /jobs -> 200"; else fail "GET /jobs -> $c"; fi
PROJECT_OK="$("$PYTHON_BIN" - <<PY
import json
d=json.loads('''$bd''')
found=None
for j in d.get('jobs', []):
    if j.get('job_id') == '$SEEDED_JOB_ID':
        found=j
        break
if not found:
    print('not-found'); raise SystemExit
missing=[k for k in ('brief_id','title','category','capability_tags') if k not in found]
if missing:
    print('missing:' + ','.join(missing))
elif found.get('category') != 'audit':
    print('cat-mismatch:' + str(found.get('category')))
elif not isinstance(found.get('capability_tags'), list) or not found['capability_tags']:
    print('tags-missing')
else:
    print('ok')
PY
)"
if [[ "$PROJECT_OK" == "ok" ]]; then
  pass "seeded job projects brief_id/title/category/capability_tags"
else
  fail "projection check: $PROJECT_OK"
fi

# ── /briefs?tag=<tag> filter uses the projected tags ──────────────────────────
section "/briefs tag filter"
SAMPLE_TAG="$("$PYTHON_BIN" - <<PY
import json
d=json.loads('''$bd''')
for j in d.get('jobs', []):
    tags=j.get('capability_tags') or []
    if tags: print(tags[0]); raise SystemExit
print('')
PY
)"
if [[ -n "$SAMPLE_TAG" ]]; then
  r="$(http_req GET "$MIP_BASE/briefs?tag=$SAMPLE_TAG")"
  c="$(printf '%s\n' "$r" | head -n1)"
  bd2="$(printf '%s\n' "$r" | tail -n +2)"
  MATCHES="$("$PYTHON_BIN" - <<PY
import json
d=json.loads('''$bd2''')
bad=[b for b in d.get('briefs', []) if '$SAMPLE_TAG' not in [t.lower() for t in (b.get('capability_tags') or [])]]
print('ok' if not bad and d.get('count',0) > 0 else f'bad:{len(bad)}:count={d.get("count")}')
PY
)"
  if [[ "$c" == "200" && "$MATCHES" == "ok" ]]; then
    pass "/briefs?tag=$SAMPLE_TAG filtered correctly"
  else
    fail "/briefs?tag=$SAMPLE_TAG -> $c check=$MATCHES"
  fi
else
  fail "no sample tag available from seeded job"
fi

# ── /start_job rejects unknown brief_id ───────────────────────────────────────
section "/start_job validates brief_id"
BAD_BODY=$(cat <<JSON
{
  "amount_specks": 1000000,
  "visibility": "public",
  "input_data": {
    "description": "seed-smoke reject-unknown-brief",
    "commitmentHash": "$(rand_hex64)",
    "brief_id": "this-brief-does-not-exist"
  }
}
JSON
)
r="$(http_req POST "$MIP_BASE/start_job" "$BAD_BODY")"
c="$(printf '%s\n' "$r" | head -n1)"
bd="$(printf '%s\n' "$r" | tail -n +2)"
if [[ "$c" == "400" && "$bd" == *"not found in the seed corpus"* ]]; then
  pass "unknown brief_id rejected (400)"
else
  fail "unknown brief_id -> $c $bd"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
section "Summary"
printf 'PASS: %d  FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then exit 1; fi
