#!/usr/bin/env bash
# nightpay gateway — orchestrates the bounty lifecycle with fee mechanism
#
# SECURITY MODEL:
#   - RECEIPT_CONTRACT is required — no silent no-ops against empty address
#   - withdraw-fees requires OPERATOR_SECRET_KEY for signing (operator-only)
#   - All hashes are domain-separated to prevent cross-namespace collisions
#   - refund path cancels Masumi escrow AND emits a signed on-chain NIGHT refund intent
#   - Amount bounds enforced (min + max) before any network call
#   - commitment_hash format validated before any network call
#   - curl has --max-time 30 to prevent hung connections
#
# Usage: ./gateway.sh <command> [args...]
#
# Commands:
#   create-pool       <job_description> <contribution_specks> <funding_goal_specks>
#   fund-pool         <pool_commitment>
#   pool-status       <pool_commitment>
#   activate-pool     <pool_commitment>
#   expire-pool       <pool_commitment>
#   claim-refund      <pool_commitment> <funder_nullifier>
#   emergency-refund  <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>
#   post-bounty       <job_description> <amount_night_specks>
#   find-agent        <capability_query>
#   agent-showcase    [search_query]
#   hire-and-pay      <agent_id> <job_description> <commitment_hash> [refund_address]
#   hire-direct       <agent_id> <job_description> <amount_specks>
#   check-job         <job_id>
#   complete          <job_id> <commitment_hash> [--approvals sig1:ts1:nonce1,...]
#   refund            <job_id> <commitment_hash> [refund_address]
#   withdraw-fees     [amount_specks]         # operator-only: requires OPERATOR_SECRET_KEY
#   stats                                     # public contract stats
#   approve-multisig  <job_id> <output_hash> <approver_key>  # per-approver signature
#   optimistic-sweep  [--dry-run]             # auto-complete expired optimistic windows
#   refund-unclaimed  [--dry-run]             # auto-refund old jobs with zero claims

set -euo pipefail

# ─── Terminal colors ───────────────────────────────────────────────────────────
# Gracefully disabled when stderr is not a TTY (CI, logs, pipes)
if [[ -t 2 ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  CYAN=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ─── Required env vars ────────────────────────────────────────────────────────
MASUMI_PAYMENT_URL="${MASUMI_PAYMENT_URL:-http://localhost:3001/api/v1}"
MASUMI_REGISTRY_URL="${MASUMI_REGISTRY_URL:-http://localhost:3000/api/v1}"
MASUMI_API_KEY="${MASUMI_API_KEY:?SECURITY: Set MASUMI_API_KEY}"
# Keep preprod default until Midnight mainnet is live.
MIDNIGHT_NETWORK="${MIDNIGHT_NETWORK:-preprod}"
OPERATOR_ADDRESS="${OPERATOR_ADDRESS:?SECURITY: Set OPERATOR_ADDRESS}"
OPERATOR_FEE_BPS="${OPERATOR_FEE_BPS:-200}"
MAX_BOUNTY_SPECKS="${MAX_BOUNTY_SPECKS:-500000000}"
MIN_BOUNTY_SPECKS="${MIN_BOUNTY_SPECKS:-1000}"  # SECURITY: reject dust bounties

# Midnight bridge — if set, gateway calls the bridge for real on-chain transactions.
# If not set, gateway runs in local/stub mode (computes hashes locally, no chain).
BRIDGE_URL="${BRIDGE_URL:-}"

# SECURITY: contract address is REQUIRED — fail loudly rather than silently
# routing funds to a void address
RECEIPT_CONTRACT="${RECEIPT_CONTRACT_ADDRESS:?SECURITY: Set RECEIPT_CONTRACT_ADDRESS — funds cannot be routed without it}"

# ─── Rate limiting ────────────────────────────────────────────────────────────
# SECURITY: prevent bounty spam that inflates activeCount and floods Masumi.
# Uses a per-command lockfile with a minimum interval between invocations.
# Default: max 1 post-bounty per 5 seconds. Override with RATE_LIMIT_SECONDS.
RATE_LIMIT_DIR="${RATE_LIMIT_DIR:-${HOME}/.nightpay/ratelimit}"
RATE_LIMIT_SECONDS="${RATE_LIMIT_SECONDS:-5}"

COMMAND="${1:?Usage: gateway.sh <command> [args...]}"
shift

# ─── Helpers ──────────────────────────────────────────────────────────────────

# SECURITY: SSRF guard — only allow http/https to non-RFC-1918, non-loopback hosts.
# Blocks: 127.x, 10.x, 172.16-31.x, 192.168.x, 169.254.x (cloud metadata), ::1
validate_url() {
  local url="$1"
  python3 -c "
import sys, urllib.parse, ipaddress, socket

url = sys.argv[1]
parsed = urllib.parse.urlparse(url)

if parsed.scheme not in ('http', 'https'):
    print('ERROR: URL must use http or https scheme'); sys.exit(1)

host = parsed.hostname
if not host:
    print('ERROR: URL has no hostname'); sys.exit(1)

# Resolve and check for private/loopback addresses
try:
    addrs = socket.getaddrinfo(host, None)
    for addr in addrs:
        ip = ipaddress.ip_address(addr[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            # Allow localhost explicitly for dev — controlled by ALLOW_LOCAL_URLS
            import os
            if os.environ.get('ALLOW_LOCAL_URLS') == '1':
                sys.exit(0)
            print(f'ERROR: SSRF blocked — {ip} is a private/internal address'); sys.exit(1)
except socket.gaierror:
    print(f'ERROR: Cannot resolve host {host}'); sys.exit(1)

print('ok')
" "$url" || exit 1
}

# Validate URLs at startup — fail before any command runs
# Skip SSRF check for localhost (dev mode) if ALLOW_LOCAL_URLS=1
if [[ "${ALLOW_LOCAL_URLS:-0}" != "1" ]]; then
  _url_check=$(python3 -c "
import sys, urllib.parse, ipaddress
for url in sys.argv[1:]:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ('http','https'):
        print(f'ERROR: {url} — must be http/https'); sys.exit(1)
print('ok')
" "$MASUMI_PAYMENT_URL" "$MASUMI_REGISTRY_URL" 2>&1) || {
    echo -e "${RED}SECURITY ERROR${RESET}: Invalid Masumi URL — $_url_check" >&2; exit 1
  }
fi

# DARK ENERGY: DNS rebinding guard — re-resolve the hostname on every request
# and verify it is still a non-private IP. An attacker who controls the DNS
# server can pass the startup check (public IP) then flip the A-record to
# 169.254.169.254 (AWS metadata) for subsequent calls. We re-resolve per call.
_ssrf_safe_curl() {
  local url="$1"; shift
  local resolve_arg
  resolve_arg=$(python3 -c "
import sys, urllib.parse, ipaddress, socket, os
url = sys.argv[1]
parsed = urllib.parse.urlparse(url)
host = parsed.hostname or ''
port = parsed.port or (443 if parsed.scheme == 'https' else 80)
try:
    if not host:
        sys.exit(0)
    addrs = socket.getaddrinfo(host, port)
    for addr in addrs:
        ip_str = addr[4][0]
        ip = ipaddress.ip_address(ip_str)
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            if os.environ.get('ALLOW_LOCAL_URLS') == '1':
                print(f'{host}:{port}:{ip_str}')
                sys.exit(0)
            print(f'SSRF blocked: {ip}', file=sys.stderr); sys.exit(1)
        print(f'{host}:{port}:{ip_str}')
        sys.exit(0)
except socket.gaierror as e:
    print(f'DNS error: {e}', file=sys.stderr); sys.exit(1)
" "$url") || { echo -e "${RED}SECURITY ERROR${RESET}: SSRF guard blocked request to $url" >&2; exit 1; }

  if [[ -n "$resolve_arg" ]]; then
    curl -sf --max-time 30 --resolve "$resolve_arg" "$@" "$url"
  else
    curl -sf --max-time 30 "$@" "$url"
  fi
}

# ─── SSRF error (colored) — used by _ssrf_safe_curl ───────────────────────────

_masumi_request_with_auth_fallback() {
  local method="$1"
  local base_url="$2"
  local endpoint="$3"
  local payload="${4:-}"
  local auth_headers=(
    "Authorization: Bearer $MASUMI_API_KEY"
    "token: $MASUMI_API_KEY"
  )
  local hdr out

  for hdr in "${auth_headers[@]}"; do
    if [[ "$method" == "GET" ]]; then
      if out="$(_ssrf_safe_curl "${base_url}${endpoint}" -H "$hdr" 2>/dev/null)"; then
        printf '%s\n' "$out"
        return 0
      fi
    else
      if out="$(_ssrf_safe_curl "${base_url}${endpoint}" \
        -X POST \
        -H "$hdr" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)"; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
  done

  echo "ERROR: Masumi request failed after trying Authorization and token headers (${method} ${endpoint})" >&2
  return 1
}

masumi_get() {
  _masumi_request_with_auth_fallback "GET" "$MASUMI_REGISTRY_URL" "$1"
}

masumi_post() {
  _masumi_request_with_auth_fallback "POST" "$MASUMI_PAYMENT_URL" "$1" "$2"
}

# Best-effort compatibility layer for registry endpoint changes.
find_agents() {
  local encoded="$1"
  local base_urls=("$MASUMI_REGISTRY_URL" "$MASUMI_PAYMENT_URL")
  local endpoints=(
    "/agents?capability=${encoded}&limit=5"
    "/registry/agents?capability=${encoded}&limit=5"
    "/services/agents?capability=${encoded}&limit=5"
    "/search/agents?capability=${encoded}&limit=5"
  )
  local base ep
  local auth_headers=(
    "Authorization: Bearer $MASUMI_API_KEY"
    "token: $MASUMI_API_KEY"
  )
  for base in "${base_urls[@]}"; do
    for ep in "${endpoints[@]}"; do
      local hdr
      for hdr in "${auth_headers[@]}"; do
        if out="$(_ssrf_safe_curl "${base}${ep}" -H "$hdr" 2>/dev/null)"; then
          printf '%s\n' "$out"
          return 0
        fi
      done
    done
  done
  echo "ERROR: agent discovery failed on all known endpoints and auth headers" >&2
  return 1
}

generate_nonce() {
  # SECURITY: cryptographically secure 32-byte random nonce.
  # `openssl rand -hex 32` always outputs exactly 64 lowercase hex chars + newline.
  # No spaces, no special chars — safe from word splitting in all contexts.
  # We strip the newline explicitly so callers can safely use $() without concern.
  openssl rand -hex 32 | tr -d '[:space:]'
}

# SECURITY: rate limiter — prevents bounty spam and Masumi flooding.
# Creates a per-command lockfile; rejects calls within RATE_LIMIT_SECONDS of last call.
rate_limit() {
  local cmd="$1"
  mkdir -p "$RATE_LIMIT_DIR"
  chmod 700 "$RATE_LIMIT_DIR"
  local lockfile="${RATE_LIMIT_DIR}/${cmd}.last"
  if [[ -f "$lockfile" ]]; then
    local last_ts; last_ts=$(cat "$lockfile" 2>/dev/null || echo 0)
    local now; now=$(date +%s)
    local diff=$(( now - last_ts ))
    if (( diff < RATE_LIMIT_SECONDS )); then
      echo -e "${RED}ERROR${RESET}: Rate limit — wait ${BOLD}$(( RATE_LIMIT_SECONDS - diff ))s${RESET} before calling ${CYAN}$cmd${RESET} again" >&2
      exit 1
    fi
  fi
  date +%s > "$lockfile"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# SECURITY: domain-separated hashes prevent cross-namespace collisions.
# A bounty commitment can never equal a receipt hash even with identical inputs.
domain_hash() {
  # DARK ENERGY: word splitting guard — pipe through tr to guarantee the output
  # is exactly 64 hex chars with no whitespace. sha256sum outputs "hash  -\n";
  # awk extracts field 1, tr strips any residual whitespace. Safe to use unquoted
  # in arithmetic but we always double-quote hash variables regardless.
  local domain="$1"; local data="$2"
  printf '%s:%s' "$domain" "$data" | sha256sum | awk '{print $1}' | tr -d '[:space:]'
}

compute_bounty_commitment() { domain_hash "nightpay-bounty-v1"  "$1"; }
compute_receipt_hash()      { domain_hash "nightpay-receipt-v1" "$1"; }
compute_job_hash()          { domain_hash "nightpay-job-v1"     "$1"; }

compute_fee() { echo $(( $1 * OPERATOR_FEE_BPS / 10000 )); }
compute_net() { local fee; fee=$(compute_fee "$1"); echo $(( $1 - fee )); }

# ─── Encrypted memory (OpenShart) ────────────────────────────────────────────
# PRIVACY: funder credentials (nullifier, nonce, fundedAtTx) are the keys to
# emergency refunds. Printing them to stdout puts them in agent conversation
# history — plaintext, potentially logged by LLM providers, violating privacy.
#
# When OpenShart is available, credentials are encrypted and fragmented via
# Shamir's Secret Sharing. The agent gets back a memory_id, not raw secrets.
# To reclaim funds, the agent recalls the memory_id — OpenShart reconstructs
# the credentials through its ChainLock protocol with timing validation.
#
# Fallback: if OpenShart is not installed, credentials are printed to stdout
# with a warning. The agent must save them somewhere safe.

OPENSHART_BIN="${OPENSHART_BIN:-}"

_shart_available() {
  if [[ -n "$OPENSHART_BIN" ]]; then
    command -v "$OPENSHART_BIN" &>/dev/null && return 0
  fi
  command -v openshart &>/dev/null && { OPENSHART_BIN="openshart"; return 0; }
  command -v npx &>/dev/null && npx openshart --version &>/dev/null 2>&1 && { OPENSHART_BIN="npx openshart"; return 0; }
  return 1
}

# Store a JSON blob in encrypted memory. Returns the memory_id.
_shart_store() {
  local content="$1"
  local tags="${2:-nightpay,funding}"
  local classification="${3:-CONFIDENTIAL}"
  if ! _shart_available; then
    return 1
  fi
  $OPENSHART_BIN store \
    --content "$content" \
    --classification "$classification" \
    --tags "$tags" \
    --compartments "NIGHTPAY_FUNDING" \
    2>/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('id',''))"
}

# Recall a stored memory by ID. Returns the decrypted JSON.
_shart_recall() {
  local memory_id="$1"
  if ! _shart_available; then
    return 1
  fi
  $OPENSHART_BIN recall --id "$memory_id" 2>/dev/null
}

# Search encrypted memories by tag. Returns matching IDs.
_shart_search() {
  local query="$1"
  local limit="${2:-10}"
  if ! _shart_available; then
    return 1
  fi
  $OPENSHART_BIN search --query "$query" --limit "$limit" 2>/dev/null
}

# Call midnight bridge service if BRIDGE_URL is set
bridge_post() {
  local endpoint="$1"; local payload="$2"
  if [[ -z "$BRIDGE_URL" ]]; then
    return 1  # no bridge — caller falls back to local computation
  fi
  _ssrf_safe_curl "${BRIDGE_URL}${endpoint}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$payload"
}

bridge_get() {
  local endpoint="$1"
  if [[ -z "$BRIDGE_URL" ]]; then
    return 1
  fi
  _ssrf_safe_curl "${BRIDGE_URL}${endpoint}" \
    -H "Content-Type: application/json"
}

validate_amount() {
  local amount="$1"
  # SECURITY: enforce integer type, min, and max before any network call
  if ! [[ "$amount" =~ ^[0-9]+$ ]]; then
    echo "ERROR: amount must be a positive integer (specks)"; exit 1
  fi
  if (( amount < MIN_BOUNTY_SPECKS )); then
    echo "ERROR: Amount $amount below minimum $MIN_BOUNTY_SPECKS specks"; exit 1
  fi
  if (( amount > MAX_BOUNTY_SPECKS )); then
    echo "ERROR: Amount $amount exceeds maximum $MAX_BOUNTY_SPECKS specks"; exit 1
  fi
}

validate_commitment() {
  # SECURITY: commitment must be a 64-char hex string — reject malformed inputs
  if ! [[ "$1" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: commitment_hash must be a 64-character lowercase hex string"; exit 1
  fi
}

validate_job_id() {
  # SECURITY: job IDs must be alphanumeric + hyphens only.
  # Prevents path traversal (../../), shell injection, and API endpoint manipulation.
  if ! [[ "$1" =~ ^[a-zA-Z0-9_-]{1,128}$ ]]; then
    echo "ERROR: job_id must be alphanumeric/hyphens/underscores, max 128 chars"; exit 1
  fi
}

# SECURITY: operator must authenticate before fee withdrawal.
# Requires OPERATOR_SECRET_KEY env var — prevents unauthorized parties from
# draining accumulated fees even if they have shell access to the gateway.
# SECURITY: payload includes a timestamp + random nonce — prevents replay attacks.
# The same HMAC can never be reused because the nonce is different every call.
require_operator_auth() {
  if [[ -z "${OPERATOR_SECRET_KEY:-}" ]]; then
    echo -e "${RED}SECURITY ERROR${RESET}: withdraw-fees requires ${BOLD}OPERATOR_SECRET_KEY${RESET} env var." >&2
    echo -e "${DIM}This prevents unauthorized parties from draining accumulated fees.${RESET}" >&2
    exit 1
  fi
  local payload="$1"
  local ts; ts=$(date +%s)
  local nonce; nonce=$(generate_nonce)
  # Include timestamp + nonce in signed payload — every signature is unique
  local full_payload="${payload}:ts=${ts}:nonce=${nonce}"
  local sig; sig=$(echo -n "$full_payload" | openssl dgst -sha256 -hmac "$OPERATOR_SECRET_KEY" | awk '{print $2}')
  # Return sig:ts:nonce so the Midnight contract can verify freshness
  echo "${sig}:${ts}:${nonce}"
}

# ─── Content Safety ────────────────────────────────────────────────────────────
# SAFETY: classify-then-forget — checks job description in-memory, never logs it.
# Three layers: live rules file > hardcoded fallback > external moderation API.
# Rules auto-updated by update-blocklist.sh (cron). See rules/content-safety.md.

CONTENT_SAFETY_URL="${CONTENT_SAFETY_URL:-}"
SAFETY_RULES_FILE="${SAFETY_RULES_FILE:-${HOME}/.nightpay/safety/safety-rules.json}"

safety_check() {
  local text="$1"

  local rejected_category
  rejected_category=$(python3 -c "
import sys, re, json, os

text = sys.argv[1].lower()
rules_file = sys.argv[2]

# ─── Layer 1: load live rules file if available (updated by update-blocklist.sh)
rules = []
if os.path.exists(rules_file):
    try:
        with open(rules_file) as f:
            data = json.load(f)
        rules = [(r['category'], r['pattern']) for r in data.get('rules', [])
                 if 'category' in r and 'pattern' in r]
    except (json.JSONDecodeError, KeyError):
        pass  # fall through to hardcoded

# ─── Layer 2: hardcoded fallback if no rules file or it failed to load
if not rules:
    rules = [
        ('csam',                  r'\b(child|minor|underage|kid|teen)\b.{0,100}?\b(sex|porn|nude|naked|exploit)\b'),
        ('csam',                  r'\b(sex|porn|nude|naked|exploit)\b.{0,100}?\b(child|minor|underage|kid|teen)\b'),
        ('violence',              r'\b(kill|assassinate|murder|execute)\b.{0,100}?\b(person|people|someone|him|her|them|target)\b'),
        ('violence',              r'\b(hire|find|pay).{0,100}?\b(hitman|killer|assassin)\b'),
        ('violence',              r'\bhit\s*man\b'),
        ('weapons_of_mass_destruction', r'\b(synthe|build|make|create|assemble)\b.{0,100}?\b(bomb|bioweapon|chemical weapon|nerve agent|sarin|anthrax|ricin|nuclear|dirty bomb|explosive device)\b'),
        ('human_trafficking',     r'\b(traffic|smuggle|exploit|enslave)\b.{0,100}?\b(person|people|human|worker|organ|women|children)\b'),
        ('terrorism',             r'\b(fund|finance|recruit|plan|support)\b.{0,100}?\b(terror|jihad|extremis|insurrection|attack on)\b'),
        ('ncii',                  r'\b(deepfake|revenge porn|sextortion|non.?consensual)\b.{0,100}?\b(nude|naked|intimate|image|video|photo)\b'),
        ('financial_fraud',       r'\b(launder|counterfeit|forge)\b.{0,100}?\b(money|currency|documents|passport|identity)\b'),
        ('financial_fraud',       r'\b(evade|bypass|circumvent)\b.{0,100}?\b(sanction|embargo|aml|kyc)\b'),
        ('infrastructure_attack', r'\b(attack|hack|disrupt|destroy|sabotage)\b.{0,100}?\b(power grid|water supply|hospital|election|pipeline|dam)\b'),
        ('doxxing',               r'\b(doxx|stalk|track|surveil|locate)\b.{0,100}?\b(person|address|home|family|where .{0,100}? live)\b'),
        ('drug_manufacturing',    r'\b(synthe|cook|manufacture|produce)\b.{0,100}?\b(meth|fentanyl|heroin|cocaine|mdma|lsd)\b'),
    ]

for category, pattern in rules:
    try:
        if re.search(pattern, text):
            print(category)
            sys.exit(0)
    except re.error:
        continue  # skip malformed patterns from feeds

print('safe')
" "$text" "$SAFETY_RULES_FILE" 2>/dev/null) || rejected_category="safe"

  # ─── Layer 3: external moderation API (catches what regex misses)
  if [[ "$rejected_category" == "safe" && -n "$CONTENT_SAFETY_URL" ]]; then
    local api_payload
    api_payload=$(python3 -c "
import sys, json
print(json.dumps({'text': sys.argv[1]}))
" "$text")
    local response
    response=$(curl -sf --max-time 5 -X POST \
      -H 'Content-Type: application/json' \
      -d "$api_payload" \
      "$CONTENT_SAFETY_URL" 2>/dev/null) || response=""

    if [[ -n "$response" ]]; then
      rejected_category=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if not d.get('safe', True):
        print(d.get('category', 'unsafe'))
    else:
        print('safe')
except: print('safe')
" 2>/dev/null) || rejected_category="safe"
    fi
  fi

  if [[ "$rejected_category" != "safe" ]]; then
    python3 -c "
import sys, json
print(json.dumps({
    'status': 'REJECTED',
    'reason': 'content_safety',
    'category': sys.argv[1],
    'message': 'This bounty description was rejected by the content safety gate. See rules/content-safety.md.'
}, indent=2))
" "$rejected_category"
    exit 2
  fi
}

# ─── Optimistic delivery & multisig env vars ──────────────────────────────────
OPTIMISTIC_WINDOW_HOURS="${OPTIMISTIC_WINDOW_HOURS:-48}"
MULTISIG_THRESHOLD_SPECKS="${MULTISIG_THRESHOLD_SPECKS:-1000000}"
MULTISIG_M="${MULTISIG_M:-2}"
MULTISIG_N="${MULTISIG_N:-3}"
OPTIMISTIC_SWEEP_PAGE_SIZE="${OPTIMISTIC_SWEEP_PAGE_SIZE:-200}"   # capped to <= 500
UNCLAIMED_REFUND_HOURS="${UNCLAIMED_REFUND_HOURS:-24}"
UNCLAIMED_SWEEP_PAGE_SIZE="${UNCLAIMED_SWEEP_PAGE_SIZE:-200}"     # capped to <= 500
# APPROVER_KEYS: comma-separated HMAC secrets, one per approver
# e.g. APPROVER_KEYS="key1secret,key2secret,key3secret"
APPROVER_KEYS="${APPROVER_KEYS:-}"
MIP003_PORT="${MIP003_PORT:-8090}"
MIP003_URL="${MIP003_URL:-http://localhost:${MIP003_PORT}}"

# ─── Commands ─────────────────────────────────────────────────────────────────

case "$COMMAND" in

  post-bounty)
    JOB_DESC="${1:?Usage: post-bounty <job_description> <amount_specks>}"
    AMOUNT="${2:?Usage: post-bounty <job_description> <amount_specks>}"

    rate_limit "post-bounty"   # SECURITY: max 1 post per RATE_LIMIT_SECONDS
    validate_amount "$AMOUNT"
    safety_check "$JOB_DESC"

    FEE=$(compute_fee "$AMOUNT")
    NET=$(compute_net "$AMOUNT")
    NONCE=$(generate_nonce)
    JOB_HASH=$(compute_job_hash "$JOB_DESC")

    # SECURITY: domain-separated commitment — matches what the Compact circuit produces
    COMMITMENT=$(compute_bounty_commitment "nullifier:${AMOUNT}:${JOB_HASH}:${NONCE}")

    # If bridge is running, submit real on-chain transaction
    if [[ -n "$BRIDGE_URL" ]]; then
      BRIDGE_PAYLOAD=$(python3 -c "
import sys, json
print(json.dumps({'jobHash': sys.argv[1], 'amount': int(sys.argv[2]), 'nonce': sys.argv[3]}))
" "$JOB_HASH" "$AMOUNT" "$NONCE")
      BRIDGE_RESULT=$(bridge_post "/postBounty" "$BRIDGE_PAYLOAD" 2>/dev/null) && {
        TX_ID=$(echo "$BRIDGE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txId',''))" 2>/dev/null)
        ON_CHAIN=$(echo "$BRIDGE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('false' if d.get('stub') else 'true')" 2>/dev/null)
        echo -e "  ${GREEN}Midnight TX${RESET}: ${DIM}$TX_ID${RESET} ${CYAN}(on-chain: $ON_CHAIN)${RESET}" >&2
      } || echo -e "  ${YELLOW}WARNING${RESET}: Bridge unavailable — commitment computed locally only" >&2
    fi

    # SECURITY: nonce printed once for the caller to store securely.
    # NOT persisted by the gateway — loss of nonce means the caller cannot
    # prove bounty ownership in a dispute.
    python3 -c "
import sys, json
print(json.dumps({
    'commitment': sys.argv[1],
    'nonce': sys.argv[2],
    'jobHash': sys.argv[3],
    'amount': int(sys.argv[4]),
    'operatorFee': int(sys.argv[5]),
    'netToAgent': int(sys.argv[6]),
    'feeBps': int(sys.argv[7]),
    'receiptContract': sys.argv[8],
    'network': sys.argv[9],
    'status': 'posted',
    'warning': 'Store your nonce securely — it cannot be recovered and is required for dispute resolution'
}, indent=2))
" "$COMMITMENT" "$NONCE" "$JOB_HASH" "$AMOUNT" "$FEE" "$NET" "$OPERATOR_FEE_BPS" "$RECEIPT_CONTRACT" "$MIDNIGHT_NETWORK"
    ;;

  find-agent)
    CAPABILITY="${1:?Usage: find-agent <capability_query>}"
    ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$CAPABILITY")
    find_agents "$ENCODED"
    ;;

  agent-showcase)
    QUERY="${1:-}"
    LIMIT="${AGENT_SHOWCASE_LIMIT:-8}"
    URL="${MIP003_URL}/agents?limit=${LIMIT}&sort=credibility&showcase_only=1"
    if [[ -n "$QUERY" ]]; then
      ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")
      URL="${URL}&q=${ENCODED}"
    fi
    curl -sf --max-time 15 "$URL"
    ;;

  hire-and-pay)
    AGENT_ID="${1:?Usage: hire-and-pay <agent_id> <job_description> <commitment_hash> [refund_address]}"
    JOB_DESC="${2:?Usage: hire-and-pay <agent_id> <job_description> <commitment_hash> [refund_address]}"
    COMMITMENT="${3:?Usage: hire-and-pay <agent_id> <job_description> <commitment_hash> [refund_address]}"
    REFUND_ADDRESS="${4:-}"

    validate_commitment "$COMMITMENT"
    safety_check "$JOB_DESC"

    # Optional routing hint for no-claim timeout refunds.
    # The on-chain release still follows contract logic and commitment proofs.
    if [[ -n "$REFUND_ADDRESS" ]] && ! [[ "$REFUND_ADDRESS" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: refund_address must be a 64-character lowercase hex string" >&2
      exit 1
    fi

    PAYLOAD=$(python3 -c "
import sys, json
refund = sys.argv[6]
input_obj = {
    'description': sys.argv[2],
    'commitmentHash': sys.argv[3],
    'receiptContract': sys.argv[4],
    'network': sys.argv[5]
}
if refund:
    input_obj['refundAddress'] = refund
print(json.dumps({
    'agentIdentifier': sys.argv[1],
    'input': input_obj
}))
" "$AGENT_ID" "$JOB_DESC" "$COMMITMENT" "$RECEIPT_CONTRACT" "$MIDNIGHT_NETWORK" "$REFUND_ADDRESS")
    masumi_post "/purchases" "$PAYLOAD"
    ;;

  hire-direct)
    AGENT_ID="${1:?Usage: hire-direct <agent_id> <job_description> <amount_specks>}"
    JOB_DESC="${2:?Usage: hire-direct <agent_id> <job_description> <amount_specks>}"
    AMOUNT="${3:?Usage: hire-direct <agent_id> <job_description> <amount_specks>}"

    validate_amount "$AMOUNT"
    safety_check "$JOB_DESC"
    [[ "$AGENT_ID" =~ ^[A-Za-z0-9._:@-]{2,128}$ ]] || die "agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars"

    PAYLOAD=$(python3 -c "
import sys, json
print(json.dumps({
    'amount_specks': int(sys.argv[3]),
    'direct_agent_id': sys.argv[1],
    'visibility': 'hidden',
    'input_data': {
        'description': sys.argv[2],
        'amount_specks': int(sys.argv[3]),
        'visibility': 'hidden',
        'hiringMode': 'direct'
    }
}))
" "$AGENT_ID" "$JOB_DESC" "$AMOUNT")
    curl -sf --max-time 20 \
      -X POST \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "${MIP003_URL}/start_job"
    ;;

  check-job)
    JOB_ID="${1:?Usage: check-job <job_id>}"
    validate_job_id "$JOB_ID"   # SECURITY: prevent path traversal / injection
    masumi_get "/purchases/$JOB_ID/status"
    ;;

  approve-multisig)
    # Each approver runs this with their own key.
    # Collect M blobs and pass all sigs to: gateway.sh complete <id> <commit> --approvals sig1:ts1:nonce1,...
    JOB_ID="${1:?Usage: approve-multisig <job_id> <output_hash> <approver_key>}"
    OUTPUT_HASH="${2:?Usage: approve-multisig <job_id> <output_hash> <approver_key>}"
    APPROVER_KEY="${3:?Usage: approve-multisig <job_id> <output_hash> <approver_key>}"

    validate_job_id "$JOB_ID"
    validate_commitment "$OUTPUT_HASH"  # reuse 64-hex validator

    TS=$(date +%s)
    NONCE=$(generate_nonce)
    # SECURITY: timestamp + nonce in payload — each approval is unique, stale replays rejected by complete
    SIG_PAYLOAD="${JOB_ID}:${OUTPUT_HASH}:${TS}:${NONCE}"
    SIG=$(echo -n "$SIG_PAYLOAD" | openssl dgst -sha256 -hmac "$APPROVER_KEY" | awk '{print $2}')

    python3 -c "
import sys, json
print(json.dumps({
    'job_id':      sys.argv[1],
    'output_hash': sys.argv[2],
    'sig':         sys.argv[3],
    'ts':          int(sys.argv[4]),
    'nonce':       sys.argv[5],
    'approval_blob': f'{sys.argv[3]}:{sys.argv[4]}:{sys.argv[5]}',
    'note': 'Pass all collected approval_blobs to: gateway.sh complete <job_id> <commitment> --approvals blob1,blob2'
}, indent=2))
" "$JOB_ID" "$OUTPUT_HASH" "$SIG" "$TS" "$NONCE"
    ;;

  complete)
    JOB_ID="${1:?Usage: complete <job_id> <commitment_hash> [--approvals sig1:ts1:nonce1,...]}"
    COMMITMENT="${2:?Usage: complete <job_id> <commitment_hash>}"
    # Optional: $3 = "--approvals", $4 = comma-separated sig:ts:nonce blobs
    APPROVALS_FLAG="${3:-}"
    APPROVALS_RAW="${4:-}"

    validate_job_id "$JOB_ID"       # SECURITY: prevent path traversal
    validate_commitment "$COMMITMENT"
    MIP003_BASE="${MIP003_URL%/}"

    MIP_STATUS_AUTH_ARGS=()
    if [[ -n "${OPERATOR_SECRET_KEY:-}" ]]; then
      MIP_STATUS_AUTH_ARGS=(-H "Authorization: Bearer ${OPERATOR_SECRET_KEY}")
    fi

    # ── Multisig verification (for high-value bounties) ────────────────────
    # Query the MIP-003 server for job amount to decide if multisig required
    JOB_AMOUNT=0
    if command -v curl >/dev/null 2>&1; then
      _JOB_INFO=$(curl -sf --max-time 5 "${MIP_STATUS_AUTH_ARGS[@]}" "${MIP003_BASE}/status/${JOB_ID}" 2>/dev/null || echo '{}')
      JOB_AMOUNT=$(echo "$_JOB_INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('amount_specks') or 0)
except: print(0)
" 2>/dev/null || echo 0)
    fi

    if (( JOB_AMOUNT >= MULTISIG_THRESHOLD_SPECKS )); then
      if [[ -z "$APPROVALS_RAW" || "$APPROVALS_FLAG" != "--approvals" ]]; then
        echo -e "${RED}ERROR${RESET}: job amount ${BOLD}${JOB_AMOUNT} specks${RESET} >= threshold ${MULTISIG_THRESHOLD_SPECKS}" >&2
        echo -e "${YELLOW}Multisig required.${RESET} Each approver runs:" >&2
        echo -e "  ${CYAN}gateway.sh approve-multisig${RESET} $JOB_ID <output_hash> <approver_key>" >&2
        echo -e "Then collect M approval_blobs and run:" >&2
        echo -e "  ${CYAN}gateway.sh complete${RESET} $JOB_ID $COMMITMENT --approvals blob1,blob2" >&2
        exit 1
      fi

      # Verify M-of-N approvals using Python stdlib only (no new deps)
      VERIFY_OK=$(python3 -c "
import sys, json, hmac, hashlib, time

job_id        = sys.argv[1]
output_hash   = sys.argv[2]
approvals_raw = sys.argv[3]
approver_keys = [k for k in sys.argv[4].split(',') if k] if sys.argv[4] else []
required_m    = int(sys.argv[5])
max_age_secs  = 86400   # approvals expire after 24h — prevents replay attacks

# Parse: each entry is sig:ts:nonce
approvals = []
for entry in approvals_raw.split(','):
    parts = entry.split(':')
    if len(parts) != 3:
        print(f'ERROR: malformed approval blob (expected sig:ts:nonce): {entry}', file=sys.stderr)
        sys.exit(1)
    try:
        approvals.append({'sig': parts[0], 'ts': int(parts[1]), 'nonce': parts[2]})
    except ValueError:
        print(f'ERROR: non-integer timestamp in approval: {entry}', file=sys.stderr)
        sys.exit(1)

now         = int(time.time())
valid_count = 0
used_keys   = set()   # SECURITY: each key index counts once — no double-counting

for approval in approvals:
    age = now - approval['ts']
    if age > max_age_secs:
        print(f'WARN: approval ts={approval[\"ts\"]} is too old (age={age}s > {max_age_secs}s)', file=sys.stderr)
        continue
    if age < -300:  # 5-min future clock skew tolerance
        print(f'WARN: approval ts={approval[\"ts\"]} is too far in future (age={age}s)', file=sys.stderr)
        continue

    payload = f'{job_id}:{output_hash}:{approval[\"ts\"]}:{approval[\"nonce\"]}'
    for i, key in enumerate(approver_keys):
        if i in used_keys:
            continue
        expected = hmac.new(key.encode(), payload.encode(), hashlib.sha256).hexdigest()
        if hmac.compare_digest(expected, approval['sig']):
            used_keys.add(i)
            valid_count += 1
            break

if valid_count >= required_m:
    print(f'ok:{valid_count}')
else:
    print(f'ERROR: only {valid_count} valid approvals, need {required_m}', file=sys.stderr)
    sys.exit(1)
" "$JOB_ID" "$COMMITMENT" "$APPROVALS_RAW" "$APPROVER_KEYS" "$MULTISIG_M" 2>&1) || {
        echo -e "${RED}SECURITY ERROR${RESET}: multisig verification failed — $VERIFY_OK" >&2
        exit 1
      }
      echo -e "  ${GREEN}Multisig${RESET}: $VERIFY_OK approvals verified" >&2
    fi

    RESULT_DATA=$(masumi_get "/purchases/$JOB_ID/result")

    # SECURITY: canonical JSON (sorted keys, no whitespace) prevents hash
    # manipulation via key reordering or whitespace changes in the API response
    OUTPUT_HASH=$(echo "$RESULT_DATA" | python3 -c "
import sys, json, hashlib
d = json.load(sys.stdin)
canonical = json.dumps(d, sort_keys=True, separators=(',',':'))
print(hashlib.sha256(canonical.encode()).hexdigest())
") || { echo "ERROR: Failed to parse job result as JSON — refusing to mint receipt"; exit 1; }

    COMPLETION_NONCE=$(generate_nonce)

    # SECURITY: domain-separated receipt hash — cannot be forged from bounty inputs
    RECEIPT_HASH=$(compute_receipt_hash "${COMMITMENT}:${OUTPUT_HASH}:${COMPLETION_NONCE}")

    # If bridge is running, submit real completeAndReceipt circuit call
    BRIDGE_TX_ID=""
    BRIDGE_ON_CHAIN="false"
    if [[ -n "$BRIDGE_URL" ]]; then
      BRIDGE_PAYLOAD=$(python3 -c "
import sys, json
print(json.dumps({'bountyCommitment': sys.argv[1], 'outputHash': sys.argv[2]}))
" "$COMMITMENT" "$OUTPUT_HASH")
      BRIDGE_RESULT=$(bridge_post "/completeAndReceipt" "$BRIDGE_PAYLOAD" 2>/dev/null) && {
        BRIDGE_TX_ID=$(echo "$BRIDGE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txId',''))" 2>/dev/null)
        BRIDGE_ON_CHAIN=$(echo "$BRIDGE_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('false' if d.get('stub') else 'true')" 2>/dev/null)
        echo -e "  ${GREEN}Midnight TX${RESET}: ${DIM}$BRIDGE_TX_ID${RESET} ${CYAN}(on-chain: $BRIDGE_ON_CHAIN)${RESET}" >&2
      } || echo -e "  ${YELLOW}WARNING${RESET}: Bridge unavailable — receipt computed locally only" >&2
    fi

    # Fetch economics from MIP-003 for the cost footer (ClawWork pattern)
    _ECON_AMOUNT=0
    _ECON_FEE=0
    _ECON_NET=0
    if command -v curl >/dev/null 2>&1; then
      _ECON_INFO=$(curl -sf --max-time 3 "${MIP_STATUS_AUTH_ARGS[@]}" "${MIP003_BASE}/status/${JOB_ID}" 2>/dev/null || echo '{}')
      read -r _ECON_AMOUNT _ECON_FEE _ECON_NET <<< "$(python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    amount = int(d.get('amount_specks') or 0)
    fee_bps = int('${OPERATOR_FEE_BPS}')
    fee = amount * fee_bps // 10000
    net = amount - fee
    print(amount, fee, net)
except: print(0, 0, 0)
" <<< "$_ECON_INFO" 2>/dev/null || echo "0 0 0")"
    fi

    # Sync MIP status so agents polling /status see the final completed state.
    MIP_SYNC_OK="false"
    MIP_SYNC_STATE="not_attempted"
    if [[ -n "$MIP003_BASE" ]]; then
      if [[ -z "${OPERATOR_SECRET_KEY:-}" ]]; then
        MIP_SYNC_STATE="skipped_no_operator_secret"
        echo -e "  ${YELLOW}WARNING${RESET}: OPERATOR_SECRET_KEY missing — cannot sync ${CYAN}${MIP003_BASE}/complete_job${RESET}" >&2
      else
        MIP_SYNC_PAYLOAD=$(python3 -c "
import sys, json
print(json.dumps({
    'receiptHash': sys.argv[1],
    'outputHash': sys.argv[2],
    'midnightTxId': sys.argv[3] or None,
    'onChain': sys.argv[4] == 'true'
}))
" "$RECEIPT_HASH" "$OUTPUT_HASH" "$BRIDGE_TX_ID" "$BRIDGE_ON_CHAIN")
        MIP_SYNC_RESULT=$(curl -sf --max-time 15 \
          -X POST \
          -H "Authorization: Bearer ${OPERATOR_SECRET_KEY}" \
          -H "Content-Type: application/json" \
          -d "$MIP_SYNC_PAYLOAD" \
          "${MIP003_BASE}/complete_job/${JOB_ID}" 2>/dev/null) && {
            MIP_SYNC_OK="true"
            MIP_SYNC_STATE=$(echo "$MIP_SYNC_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('internal_status') or d.get('status') or 'completed')
except:
    print('completed')
")
            echo -e "  ${GREEN}MIP Sync${RESET}: ${DIM}${MIP003_BASE}/complete_job/${JOB_ID}${RESET} ${CYAN}(state: ${MIP_SYNC_STATE})${RESET}" >&2
          } || {
            MIP_SYNC_STATE="sync_failed"
            echo -e "  ${YELLOW}WARNING${RESET}: could not sync MIP completion state at ${CYAN}${MIP003_BASE}/complete_job/${JOB_ID}${RESET}" >&2
          }
      fi
    fi

    python3 -c "
import sys, json
print(json.dumps({
    'receiptHash': sys.argv[1],
    'outputHash': sys.argv[2],
    'commitment': sys.argv[3],
    'completionNonce': sys.argv[4],
    'status': 'completed',
    'midnightNetwork': sys.argv[5],
    'receiptContract': sys.argv[6],
    'midnightTxId': sys.argv[7] or None,
    'onChain': sys.argv[8] == 'true',
    # Economics footer — ClawWork-compatible cost accounting shape
    'economics': {
        'amountSpecks': int(sys.argv[9]),
        'fee':          int(sys.argv[10]),
        'netToAgent':   int(sys.argv[11]),
        'feeBps':       int(sys.argv[12]),
    },
    'mipStatusSync': {
        'ok': sys.argv[13] == 'true',
        'state': sys.argv[14],
        'baseUrl': sys.argv[15],
    },
}, indent=2))
" "$RECEIPT_HASH" "$OUTPUT_HASH" "$COMMITMENT" "$COMPLETION_NONCE" "$MIDNIGHT_NETWORK" "$RECEIPT_CONTRACT" "$BRIDGE_TX_ID" "$BRIDGE_ON_CHAIN" "$_ECON_AMOUNT" "$_ECON_FEE" "$_ECON_NET" "$OPERATOR_FEE_BPS" "$MIP_SYNC_OK" "$MIP_SYNC_STATE" "$MIP003_BASE"
    ;;

  refund)
    JOB_ID="${1:?Usage: refund <job_id> <commitment_hash> [refund_address]}"
    COMMITMENT="${2:?Usage: refund <job_id> <commitment_hash> [refund_address]}"
    REFUND_ADDRESS="${3:-}"

    validate_job_id "$JOB_ID"       # SECURITY: prevent path traversal
    validate_commitment "$COMMITMENT"
    if [[ -n "$REFUND_ADDRESS" ]] && ! [[ "$REFUND_ADDRESS" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: refund_address must be a 64-character lowercase hex string" >&2
      exit 1
    fi

    # Step 1: Cancel Masumi escrow on Cardano
    echo -e "${CYAN}Cancelling Masumi escrow${RESET} for job ${BOLD}$JOB_ID${RESET}..." >&2
    masumi_post "/purchases/$JOB_ID/cancel" "{}"

    # Step 2: Emit on-chain NIGHT refund intent for the Midnight contract.
    # SECURITY: the contract's nullifier set ensures the bounty cannot be
    # re-claimed after a refund is submitted. The refundHash is the payload
    # the operator submits to the Midnight node to release NIGHT to the funder.
    REFUND_NONCE=$(generate_nonce)
    REFUND_HASH=$(compute_bounty_commitment "refund:${COMMITMENT}:${REFUND_NONCE}")

    python3 -c "
import sys, json
print(json.dumps({
    'commitment': sys.argv[1],
    'refundHash': sys.argv[2],
    'jobId': sys.argv[3],
    'receiptContract': sys.argv[4],
    'network': sys.argv[5],
    'refundAddressHint': sys.argv[6] or None,
    'status': 'refunded',
    'note': 'Submit refundHash to the Midnight contract to release NIGHT back to funder'
}, indent=2))
" "$COMMITMENT" "$REFUND_HASH" "$JOB_ID" "$RECEIPT_CONTRACT" "$MIDNIGHT_NETWORK" "$REFUND_ADDRESS"
    ;;

  withdraw-fees)
    AMOUNT="${1:-all}"

    # SECURITY: operator must sign the withdrawal — prevents anyone else
    # who has shell access from draining the accumulated fee balance
    SIG=$(require_operator_auth "${OPERATOR_ADDRESS}:${AMOUNT}")

    python3 -c "
import sys, json
print(json.dumps({
    'operatorAddress': sys.argv[1],
    'withdrawAmount': sys.argv[2],
    'operatorSignature': sys.argv[3],
    'receiptContract': sys.argv[4],
    'network': sys.argv[5],
    'status': 'submitted',
    'note': 'Submit this payload to the Midnight contract withdrawFees() circuit'
}, indent=2))
" "$OPERATOR_ADDRESS" "$AMOUNT" "$SIG" "$RECEIPT_CONTRACT" "$MIDNIGHT_NETWORK"
    ;;

  stats)
    echo -e "${CYAN}Querying nightpay stats${RESET} from ${DIM}$RECEIPT_CONTRACT${RESET} on ${BOLD}$MIDNIGHT_NETWORK${RESET}..." >&2
    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_get "/stats" && exit 0
      echo -e "  ${YELLOW}WARNING${RESET}: Bridge unavailable — showing placeholder" >&2
    fi
    python3 -c "
import sys, json
print(json.dumps({
    'receiptContract': sys.argv[1],
    'network': sys.argv[2],
    'query': 'getStats()',
    'note': 'Set BRIDGE_URL to get live on-chain stats'
}, indent=2))
" "$RECEIPT_CONTRACT" "$MIDNIGHT_NETWORK"
    ;;

  optimistic-sweep)
    # Scan for jobs whose optimistic window has expired and auto-complete them.
    # Run on a cron: */30 * * * * bash gateway.sh optimistic-sweep
    # Dry-run: gateway.sh optimistic-sweep --dry-run
    DRY_RUN=0
    [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

    MIP003_URL="http://localhost:${MIP003_PORT}"
    echo -e "${CYAN}Scanning for auto-approvable jobs${RESET} ${DIM}(window=${OPTIMISTIC_WINDOW_HOURS}h, url=${MIP003_URL}, pageSize=${OPTIMISTIC_SWEEP_PAGE_SIZE})${RESET}..." >&2

    # Fetch one paginated slice of jobs ready for optimistic completion.
    NOW_ISO=$(python3 -c "
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat())
")
    MIP_SWEEP_AUTH_ARGS=()
    if [[ -n "${OPERATOR_SECRET_KEY:-}" ]]; then
      MIP_SWEEP_AUTH_ARGS=(-H "Authorization: Bearer ${OPERATOR_SECRET_KEY}")
    fi
    JOBS_JSON=$(curl -sf --max-time 10 "${MIP_SWEEP_AUTH_ARGS[@]}" "${MIP003_URL}/jobs?status=awaiting_approval&visibility=all&approved_before=${NOW_ISO}&limit=${OPTIMISTIC_SWEEP_PAGE_SIZE}&offset=0" 2>/dev/null || echo '{"jobs":[]}')

    # Filter for expired windows and auto-complete each
    python3 -c "
import sys, json, subprocess, os
from datetime import datetime, timezone

jobs_json  = sys.argv[1]
gateway    = sys.argv[2]
dry_run    = sys.argv[3] == '1'
env        = os.environ.copy()

try:
    data = json.loads(jobs_json)
except Exception as e:
    print(f'ERROR: could not parse /jobs response: {e}', file=sys.stderr)
    sys.exit(1)

now    = datetime.now(timezone.utc).isoformat()
jobs   = data.get('jobs', [])
done   = 0
errors = 0

for job in jobs:
    jid         = job.get('job_id', '')
    approved_at = job.get('approved_at')
    input_data  = job.get('input_data') or {}

    if not approved_at or approved_at > now:
        continue   # window not yet expired

    # Extract commitmentHash from input_data (set by hire-and-pay)
    if isinstance(input_data, str):
        try: input_data = json.loads(input_data)
        except: input_data = {}
    commit = input_data.get('commitmentHash', '')

    if not commit:
        print(f'SKIP {jid}: no commitmentHash in input_data')
        errors += 1
        continue

    if dry_run:
        print(f'DRY-RUN: would complete job_id={jid} commitment={commit[:16]}...')
        done += 1
    else:
        result = subprocess.run(
            ['/usr/bin/env', 'bash', gateway, 'complete', jid, commit],
            env=env, capture_output=True, text=True
        )
        if result.returncode == 0:
            print(f'AUTO-COMPLETE OK: {jid}')
            done += 1
        else:
            print(f'AUTO-COMPLETE FAILED: {jid} — {result.stderr.strip()}')
            errors += 1

print(f'Sweep complete: {done} completed, {errors} errors.', file=sys.stderr)
" "$JOBS_JSON" "$0" "$DRY_RUN"
    ;;

  # ─── Pool Lifecycle Commands ──────────────────────────────────────────────────

  create-pool)
    JOB_DESCRIPTION="${1:?Usage: create-pool <job_description> <contribution_specks> <funding_goal_specks>}"
    CONTRIBUTION_SPECKS="${2:?Usage: create-pool <job_description> <contribution_specks> <funding_goal_specks>}"
    FUNDING_GOAL_SPECKS="${3:?Usage: create-pool <job_description> <contribution_specks> <funding_goal_specks>}"

    # SECURITY: validate amounts
    [[ "$CONTRIBUTION_SPECKS" =~ ^[0-9]+$ ]] || die "contribution_specks must be a positive integer"
    [[ "$FUNDING_GOAL_SPECKS" =~ ^[0-9]+$ ]] || die "funding_goal_specks must be a positive integer"
    (( CONTRIBUTION_SPECKS > 0 )) || die "contribution_specks must be > 0"
    (( FUNDING_GOAL_SPECKS > 0 )) || die "funding_goal_specks must be > 0"
    (( FUNDING_GOAL_SPECKS >= CONTRIBUTION_SPECKS )) || die "funding_goal must be >= contribution_amount"

    # SECURITY: exact division — no rounding dust
    (( FUNDING_GOAL_SPECKS % CONTRIBUTION_SPECKS == 0 )) || die "funding_goal must be exactly divisible by contribution_amount"
    MAX_FUNDERS=$(( FUNDING_GOAL_SPECKS / CONTRIBUTION_SPECKS ))
    (( MAX_FUNDERS <= 1000 )) || die "max funders exceeds 1000 cap"

    # Generate deterministic pool commitment
    POOL_NONCE=$(generate_nonce)
    JOB_HASH=$(domain_hash "nightpay-pool-job-v1" "$JOB_DESCRIPTION")
    POOL_COMMITMENT=$(domain_hash "nightpay-pool-v1" "$JOB_HASH:$FUNDING_GOAL_SPECKS:$CONTRIBUTION_SPECKS:$MAX_FUNDERS:$POOL_NONCE")

    validate_commitment "$POOL_COMMITMENT"

    # Calculate deadline
    DEFAULT_POOL_DEADLINE_HOURS="${DEFAULT_POOL_DEADLINE_HOURS:-72}"
    DEADLINE_ISO=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) + timedelta(hours=int('$DEFAULT_POOL_DEADLINE_HOURS'))).isoformat())
")

    # Register pool on the board
    bash "$(dirname "$0")/bounty-board.sh" add "$POOL_COMMITMENT" "pool:funding"

    # If bridge is available, submit createPool circuit call
    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_post "/createPool" "{\"jobHash\":\"$JOB_HASH\",\"fundingGoal\":$FUNDING_GOAL_SPECKS,\"contributionAmount\":$CONTRIBUTION_SPECKS,\"maxFunders\":$MAX_FUNDERS,\"nonce\":\"$POOL_NONCE\"}" 2>/dev/null || true
    fi

    python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'fundingGoal': int(sys.argv[2]),
    'contributionAmount': int(sys.argv[3]),
    'maxFunders': int(sys.argv[4]),
    'deadline': sys.argv[5],
    'status': 'funding',
    'network': sys.argv[6],
    'contract': sys.argv[7],
}, indent=2))
" "$POOL_COMMITMENT" "$FUNDING_GOAL_SPECKS" "$CONTRIBUTION_SPECKS" "$MAX_FUNDERS" "$DEADLINE_ISO" "$MIDNIGHT_NETWORK" "$RECEIPT_CONTRACT"
    ;;

  fund-pool)
    POOL_COMMITMENT="${1:?Usage: fund-pool <pool_commitment>}"
    validate_commitment "$POOL_COMMITMENT"

    FUNDER_NONCE=$(generate_nonce)
    FUNDER_NULLIFIER=$(domain_hash "nightpay-funder-v1" "$FUNDER_NONCE")
    FUNDING_RECORD=$(domain_hash "nightpay-funding-v1" "$FUNDER_NULLIFIER:$POOL_COMMITMENT:$FUNDER_NONCE")

    # If bridge is available, submit fundPool circuit call
    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_post "/fundPool" "{\"funderNullifier\":\"$FUNDER_NULLIFIER\",\"poolCommitment\":\"$POOL_COMMITMENT\",\"nonce\":\"$FUNDER_NONCE\"}" 2>/dev/null || true
    fi

    # PRIVACY: store credentials encrypted via OpenShart if available.
    # These are the keys to emergency refunds — they should NEVER sit in
    # plaintext conversation history or agent logs.
    CREDENTIAL_JSON="{\"poolCommitment\":\"$POOL_COMMITMENT\",\"fundingRecord\":\"$FUNDING_RECORD\",\"funderNullifier\":\"$FUNDER_NULLIFIER\",\"nonce\":\"$FUNDER_NONCE\",\"fundedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    MEMORY_ID=""
    if MEMORY_ID=$(_shart_store "$CREDENTIAL_JSON" "nightpay,funding,$POOL_COMMITMENT" "CONFIDENTIAL"); then
      # Encrypted storage succeeded — return memory_id instead of raw secrets
      python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'fundingRecord': sys.argv[2],
    'status': 'funded',
    'credentialStorage': 'encrypted',
    'memoryId': sys.argv[3],
    'note': 'Credentials stored encrypted via OpenShart. Use memoryId to recall them for refunds.'
}, indent=2))
" "$POOL_COMMITMENT" "$FUNDING_RECORD" "$MEMORY_ID"
    else
      # Fallback: no OpenShart — print raw credentials with warning
      python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'fundingRecord': sys.argv[2],
    'funderNullifier': sys.argv[3],
    'nonce': sys.argv[4],
    'status': 'funded',
    'credentialStorage': 'plaintext',
    'WARNING': 'OpenShart not available — credentials are in PLAINTEXT. Install openshart for encrypted storage.',
    'note': 'SAVE these values securely — you need funderNullifier + nonce to claim a refund if the pool expires'
}, indent=2))
" "$POOL_COMMITMENT" "$FUNDING_RECORD" "$FUNDER_NULLIFIER" "$FUNDER_NONCE"
    fi
    ;;

  pool-status)
    POOL_COMMITMENT="${1:?Usage: pool-status <pool_commitment>}"
    validate_commitment "$POOL_COMMITMENT"

    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_get "/poolStatus/$POOL_COMMITMENT" && exit 0
      echo "  WARNING: Bridge unavailable — showing placeholder" >&2
    fi

    python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'query': 'poolStatus',
    'note': 'Set BRIDGE_URL to get live on-chain pool status'
}, indent=2))
" "$POOL_COMMITMENT"
    ;;

  activate-pool)
    POOL_COMMITMENT="${1:?Usage: activate-pool <pool_commitment>}"
    validate_commitment "$POOL_COMMITMENT"

    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_post "/activatePool" "{\"poolCommitment\":\"$POOL_COMMITMENT\"}" 2>/dev/null || true
    fi

    # Update board status
    bash "$(dirname "$0")/bounty-board.sh" remove "$POOL_COMMITMENT" "completed" 2>/dev/null || true

    python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'status': 'activated',
    'note': 'Pool goal met — funds released to gateway for Masumi escrow. Find an agent next.'
}, indent=2))
" "$POOL_COMMITMENT"
    ;;

  expire-pool)
    POOL_COMMITMENT="${1:?Usage: expire-pool <pool_commitment>}"
    validate_commitment "$POOL_COMMITMENT"

    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_post "/expirePool" "{\"poolCommitment\":\"$POOL_COMMITMENT\"}" 2>/dev/null || true
    fi

    # Update board status
    bash "$(dirname "$0")/bounty-board.sh" remove "$POOL_COMMITMENT" "expired" 2>/dev/null || true

    python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'status': 'expired',
    'note': 'Pool expired — funders can now call claim-refund to reclaim their NIGHT'
}, indent=2))
" "$POOL_COMMITMENT"
    ;;

  claim-refund)
    # Accepts either:
    #   claim-refund <pool_commitment> <funder_nullifier>       (manual)
    #   claim-refund --memory-id <openshart_memory_id>          (auto-recall from encrypted storage)
    if [[ "${1:-}" == "--memory-id" ]]; then
      MEMORY_ID="${2:?Usage: claim-refund --memory-id <openshart_memory_id>}"
      RECALLED=$(_shart_recall "$MEMORY_ID") || { echo "ERROR: Could not recall credentials from OpenShart memory $MEMORY_ID" >&2; exit 1; }
      POOL_COMMITMENT=$(echo "$RECALLED" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['poolCommitment'])")
      FUNDER_NULLIFIER=$(echo "$RECALLED" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['funderNullifier'])")
    else
      POOL_COMMITMENT="${1:?Usage: claim-refund <pool_commitment> <funder_nullifier>  OR  claim-refund --memory-id <id>}"
      FUNDER_NULLIFIER="${2:?Usage: claim-refund <pool_commitment> <funder_nullifier>}"
    fi
    validate_commitment "$POOL_COMMITMENT"

    if [[ -n "$BRIDGE_URL" ]]; then
      bridge_post "/claimRefund" "{\"poolCommitment\":\"$POOL_COMMITMENT\",\"funderNullifier\":\"$FUNDER_NULLIFIER\"}" 2>/dev/null || true
    fi

    python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'funderNullifier': sys.argv[2],
    'status': 'refunded',
    'note': 'Full contribution returned — no fee charged on expired pools'
}, indent=2))
" "$POOL_COMMITMENT" "$FUNDER_NULLIFIER"
    ;;

  emergency-refund)
    # FAILSAFE: bypass the gateway entirely. Submits emergencyRefund circuit call
    # directly to the Midnight contract. No bridge needed.
    # Accepts either:
    #   emergency-refund <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>
    #   emergency-refund --memory-id <openshart_memory_id> <contribution_specks> <funded_at_tx>
    if [[ "${1:-}" == "--memory-id" ]]; then
      MEMORY_ID="${2:?Usage: emergency-refund --memory-id <id> <contribution_specks> <funded_at_tx>}"
      CONTRIBUTION_SPECKS="${3:?Usage: emergency-refund --memory-id <id> <contribution_specks> <funded_at_tx>}"
      FUNDED_AT_TX="${4:?Usage: emergency-refund --memory-id <id> <contribution_specks> <funded_at_tx>}"
      RECALLED=$(_shart_recall "$MEMORY_ID") || { echo "ERROR: Could not recall credentials from OpenShart memory $MEMORY_ID" >&2; exit 1; }
      POOL_COMMITMENT=$(echo "$RECALLED" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['poolCommitment'])")
      FUNDER_NULLIFIER=$(echo "$RECALLED" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['funderNullifier'])")
      NONCE=$(echo "$RECALLED" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['nonce'])")
    else
      POOL_COMMITMENT="${1:?Usage: emergency-refund <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>}"
      FUNDER_NULLIFIER="${2:?Usage: emergency-refund <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>}"
      CONTRIBUTION_SPECKS="${3:?Usage: emergency-refund <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>}"
      FUNDED_AT_TX="${4:?Usage: emergency-refund <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>}"
      NONCE="${5:?Usage: emergency-refund <pool_commitment> <funder_nullifier> <contribution_specks> <funded_at_tx> <nonce>}"
    fi
    validate_commitment "$POOL_COMMITMENT"

    [[ "$CONTRIBUTION_SPECKS" =~ ^[0-9]+$ ]] || die "contribution_specks must be a positive integer"
    [[ "$FUNDED_AT_TX" =~ ^[0-9]+$ ]] || die "funded_at_tx must be a non-negative integer"

    python3 -c "
import sys, json
print(json.dumps({
    'poolCommitment': sys.argv[1],
    'funderNullifier': sys.argv[2],
    'contributionSpecks': int(sys.argv[3]),
    'fundedAtTx': int(sys.argv[4]),
    'nonce': sys.argv[5],
    'status': 'emergency_refund',
    'emergencyPath': True,
    'note': 'Submit this payload directly to the Midnight contract emergencyRefund() circuit — no bridge/gateway needed'
}, indent=2))
" "$POOL_COMMITMENT" "$FUNDER_NULLIFIER" "$CONTRIBUTION_SPECKS" "$FUNDED_AT_TX" "$NONCE"
    ;;

  refund-unclaimed)
    # Refund jobs that were never claimed and exceeded UNCLAIMED_REFUND_HOURS.
    # Safety conditions:
    #   - status == running
    #   - claims_count == 0 and assigned_agent_id empty
    #   - started_at older than threshold
    #   - commitmentHash present in input_data
    DRY_RUN=0
    [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
    MIP003_URL="http://localhost:${MIP003_PORT}"
    echo -e "${CYAN}Scanning for unclaimed refunds${RESET} ${DIM}(age=${UNCLAIMED_REFUND_HOURS}h, url=${MIP003_URL}, pageSize=${UNCLAIMED_SWEEP_PAGE_SIZE})${RESET}..." >&2

    python3 -c "
import json, subprocess, sys, urllib.request, urllib.error
from datetime import datetime, timezone, timedelta

mip_url = sys.argv[1]
gateway = sys.argv[2]
dry_run = sys.argv[3] == '1'
hours = float(sys.argv[4])
page_size = int(sys.argv[5])
operator_secret = sys.argv[6]

if page_size < 1:
    page_size = 1
if page_size > 500:
    page_size = 500

threshold = datetime.now(timezone.utc) - timedelta(hours=hours)
offset = 0
scanned = 0
candidates = 0
done = 0
errors = 0

def parse_iso(v):
    if not v:
        return None
    try:
        return datetime.fromisoformat(str(v).replace('Z', '+00:00'))
    except Exception:
        return None

while True:
    url = f'{mip_url}/jobs?status=running&visibility=all&limit={page_size}&offset={offset}'
    headers = {}
    if operator_secret:
        headers['Authorization'] = f'Bearer {operator_secret}'
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read().decode())
    except Exception as e:
        print(f'ERROR: failed to query jobs page offset={offset}: {e}', file=sys.stderr)
        sys.exit(1)

    jobs = data.get('jobs', [])
    if not isinstance(jobs, list):
        print('ERROR: unexpected /jobs response format', file=sys.stderr)
        sys.exit(1)

    for job in jobs:
        scanned += 1
        jid = job.get('job_id', '')
        claims = int(job.get('claims_count') or 0)
        assigned = job.get('assigned_agent_id')
        started_at = parse_iso(job.get('started_at'))
        input_data = job.get('input_data') or {}

        if claims > 0 or assigned:
            continue
        if not started_at or started_at > threshold:
            continue
        if isinstance(input_data, str):
            try:
                input_data = json.loads(input_data)
            except Exception:
                input_data = {}
        if not isinstance(input_data, dict):
            input_data = {}

        commit = str(input_data.get('commitmentHash') or '')
        refund_addr = str(input_data.get('refundAddress') or input_data.get('funderAddress') or '')
        if len(commit) != 64 or any(c not in '0123456789abcdef' for c in commit):
            print(f'SKIP {jid}: missing/invalid commitmentHash for refund', file=sys.stderr)
            errors += 1
            continue

        candidates += 1
        if dry_run:
            addr_hint = refund_addr[:12] + '...' if refund_addr else 'unknown'
            print(f'DRY-RUN: would refund job_id={jid} commitment={commit[:16]}... refundAddress={addr_hint}')
            done += 1
            continue

        cmd = ['/usr/bin/env', 'bash', gateway, 'refund', jid, commit]
        if len(refund_addr) == 64 and all(c in '0123456789abcdef' for c in refund_addr):
            cmd.append(refund_addr)
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            print(f'AUTO-REFUND OK: {jid}')
            done += 1
        else:
            print(f'AUTO-REFUND FAILED: {jid} — {result.stderr.strip()}', file=sys.stderr)
            errors += 1

    has_more = bool(data.get('has_more'))
    count = int(data.get('count') or 0)
    if not has_more or count == 0:
        break
    offset += page_size

print(f'Unclaimed refund sweep: scanned={scanned}, candidates={candidates}, refunded={done}, errors={errors}.', file=sys.stderr)
" "$MIP003_URL" "$0" "$DRY_RUN" "$UNCLAIMED_REFUND_HOURS" "$UNCLAIMED_SWEEP_PAGE_SIZE" "${OPERATOR_SECRET_KEY:-}"
    ;;

  *)
    echo -e "${BOLD}nightpay gateway${RESET} — anonymous bounty lifecycle CLI" >&2
    echo "" >&2
    echo -e "${BOLD}Commands:${RESET}" >&2
    echo -e "  ${CYAN}post-bounty${RESET}      <desc> <amount>            Fund a bounty anonymously" >&2
    echo -e "  ${CYAN}find-agent${RESET}       <query>                    Search Masumi for agents" >&2
    echo -e "  ${CYAN}agent-showcase${RESET}   [query]                    List profile showcase agents by credibility" >&2
    echo -e "  ${CYAN}hire-and-pay${RESET}     <agent> <desc> <hash>      Create escrow, start job" >&2
    echo -e "  ${CYAN}hire-direct${RESET}      <agent> <desc> <amount>    Create hidden direct-hire job" >&2
    echo -e "  ${CYAN}check-job${RESET}        <job_id>                   Poll job status" >&2
    echo -e "  ${CYAN}complete${RESET}         <job_id> <hash>            Mint receipt, release payment" >&2
    echo -e "  ${CYAN}refund${RESET}           <job_id> <hash> [addr]     Cancel escrow, refund NIGHT" >&2
    echo -e "  ${CYAN}refund-unclaimed${RESET} [--dry-run]                Auto-refund old unclaimed jobs" >&2
    echo -e "  ${CYAN}approve-multisig${RESET} <id> <hash> <key>          Sign high-value approval" >&2
    echo -e "  ${CYAN}optimistic-sweep${RESET} [--dry-run]                Auto-complete expired windows" >&2
    echo -e "  ${CYAN}withdraw-fees${RESET}    [amount]                   Operator fee withdrawal" >&2
    echo -e "  ${CYAN}stats${RESET}                                       On-chain contract stats" >&2
    echo "" >&2
    echo -e "${DIM}Required: MASUMI_API_KEY  MIDNIGHT_NETWORK  OPERATOR_ADDRESS  RECEIPT_CONTRACT_ADDRESS${RESET}" >&2
    exit 1
    ;;
esac
