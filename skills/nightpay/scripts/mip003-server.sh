#!/usr/bin/env bash
# nightpay MIP-003 service — HTTP endpoints for Masumi registry
#
# Jobs persisted in sqlite (default) or postgres (shared DB for horizontal scale).
# Threaded server with in-flight guard — handles concurrent requests.
#
# Usage: ./mip003-server.sh [port]
# Default port: 8090
#
# Required env vars:
#   JOB_TOKEN_SECRET       — HMAC secret for job_token generation (never stored)
#   OPERATOR_SECRET_KEY    — HMAC secret for operator dispute auth
#
# Optional env vars:
#   IDEMPOTENCY_TTL_SECONDS    - dedupe window for X-Idempotency-Key (default: 86400)
#   OPTIMISTIC_WINDOW_HOURS    — hours before auto-complete fires (default: 48)
#   MULTISIG_THRESHOLD_SPECKS  — above this value, multisig required (default: 1000000)
#   MIP003_MODE                — "compat" (default) or "strict"
#   ONTOLOGY_DIR               — override JSON-LD ontology directory (default: ../ontology)
#   AGENT_IDENTITY_ENFORCE     — 1/true to require verified agent identity on claim/submit (default: 0)
#   AGENT_CHALLENGE_TTL_SECONDS — agent challenge TTL (default: 600)
#   AGENT_VERIFIED_TOKEN_TTL_SECONDS — X-Agent-Token TTL after verify (default: 86400)
#   AGENT_FINGERPRINT_SALT     — optional extra salt for identity fingerprint derivation
#   MANAGEMENT_LLM_URL          — Ollama base URL (default: https://api.nightpay.dev/ollama)
#   MANAGEMENT_LLM_MODEL        — Ollama model id for CEO chat (default: granite4:3b)
#   MANAGEMENT_LLM_ENABLED      — 1/true to call Ollama backend (default: 1)
#   MANAGEMENT_LLM_TIMEOUT_SECONDS — HTTP timeout for LLM calls (default: 25)
#   MANAGEMENT_LLM_TEMPERATURE  — generation temperature (default: 0.2)
#   MANAGEMENT_LLM_API_KEY      — optional bearer auth for LLM gateway
#   MIP003_MAX_INFLIGHT         — caps concurrent in-flight HTTP requests (default: 512)
#   NIGHTPAY_DB_BACKEND         — "sqlite" (default) or "postgres"
#   NIGHTPAY_DATABASE_URL       — required for postgres (e.g. postgresql://user:pass@host:5432/nightpay)
#   NIGHTPAY_DB_POOL_SIZE       — max postgres connections per process (default: 64)
#
# Register with Masumi after starting:
#   curl -X POST http://127.0.0.1:3001/api/v1/registry \
#     -H "token: $MASUMI_API_KEY" \
#     -H "Content-Type: application/json" \
#     -d '{
#       "name": "nightpay",
#       "description": "Anonymous community bounty board — pool shielded NIGHT, hire AI agents, get ZK receipts",
#       "apiBaseUrl": "http://your-server:8090",
#       "capabilityName": "nightpay-bounties",
#       "capabilityVersion": "0.2.0",
#       "pricingUnit": "lovelace",
#       "pricingQuantity": "0",
#       "network": "Preprod",
#       "authorName": "nightpay",
#       "authorContact": "nightpay@users.noreply.github.com",
#       "authorOrganization": "nightpay"
#     }'

set -euo pipefail

# ─── Terminal colors ───────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
  GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RED=''; RESET=''
fi

PORT="${1:-8090}"
DATA_DIR="${DATA_DIR:-${HOME}/.nightpay}"
DB_PATH="${DATA_DIR}/jobs.db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONTOLOGY_DIR="${ONTOLOGY_DIR:-${SCRIPT_DIR}/../ontology}"

JOB_TOKEN_SECRET="${JOB_TOKEN_SECRET:?SECURITY: Set JOB_TOKEN_SECRET env var}"
OPERATOR_SECRET_KEY="${OPERATOR_SECRET_KEY:?SECURITY: Set OPERATOR_SECRET_KEY env var}"
OPTIMISTIC_WINDOW_HOURS="${OPTIMISTIC_WINDOW_HOURS:-48}"
MULTISIG_THRESHOLD_SPECKS="${MULTISIG_THRESHOLD_SPECKS:-1000000}"
OPERATOR_FEE_BPS="${OPERATOR_FEE_BPS:-200}"
IDEMPOTENCY_TTL_SECONDS="${IDEMPOTENCY_TTL_SECONDS:-86400}"
MIP003_MODE="${MIP003_MODE:-compat}"
NIGHTPAY_DB_BACKEND="${NIGHTPAY_DB_BACKEND:-sqlite}"
NIGHTPAY_DATABASE_URL="${NIGHTPAY_DATABASE_URL:-}"
NIGHTPAY_DB_POOL_SIZE="${NIGHTPAY_DB_POOL_SIZE:-64}"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
if [[ -z "$PYTHON_BIN" || "$PYTHON_BIN" == *"WindowsApps"* ]]; then
  PYTHON_BIN="$(command -v python 2>/dev/null || true)"
fi
[[ -n "$PYTHON_BIN" ]] || { echo -e "${RED}ERROR${RESET}: python3/python required" >&2; exit 1; }

echo -e "${GREEN}◆${RESET} ${BOLD}nightpay${RESET} MIP-003 service listening on ${CYAN}:${PORT}${RESET}" >&2
if [[ "${NIGHTPAY_DB_BACKEND}" == "postgres" ]]; then
  echo -e "${DIM}  DB: postgres (pool=${NIGHTPAY_DB_POOL_SIZE})${RESET}" >&2
else
  echo -e "${DIM}  DB: sqlite (${DB_PATH})${RESET}" >&2
fi
echo -e "${DIM}  optimistic window: ${OPTIMISTIC_WINDOW_HOURS}h  |  multisig threshold: ${MULTISIG_THRESHOLD_SPECKS} specks${RESET}" >&2
echo -e "${DIM}  mip003 mode: ${MIP003_MODE}${RESET}" >&2
echo -e "${DIM}  ontology dir: ${ONTOLOGY_DIR}${RESET}" >&2

"$PYTHON_BIN" - "$PORT" "$DB_PATH" "$JOB_TOKEN_SECRET" "$OPERATOR_SECRET_KEY" "$OPTIMISTIC_WINDOW_HOURS" "$MULTISIG_THRESHOLD_SPECKS" "$OPERATOR_FEE_BPS" "$IDEMPOTENCY_TTL_SECONDS" "$MIP003_MODE" "$ONTOLOGY_DIR" <<'PYCODE'
import http.server, json, uuid, sys, sqlite3, threading, hmac, hashlib, re, os, glob, copy, secrets, math, queue
from datetime import datetime, timezone, timedelta
from urllib.parse import urlparse, parse_qs
from urllib import request as urlrequest, error as urlerror

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
except Exception:
    Ed25519PublicKey = None

try:
    import psycopg
    from psycopg.rows import dict_row as _pg_dict_row
except Exception:
    psycopg = None
    _pg_dict_row = None

try:
    import psycopg2
    import psycopg2.extras
except Exception:
    psycopg2 = None

PORT                     = int(sys.argv[1])
DB_PATH                  = sys.argv[2]
JOB_TOKEN_SECRET         = sys.argv[3]
OPERATOR_SECRET_KEY      = sys.argv[4]
OPTIMISTIC_WINDOW_HOURS  = int(sys.argv[5])
MULTISIG_THRESHOLD_SPECKS = int(sys.argv[6])
os.environ['OPERATOR_FEE_BPS'] = sys.argv[7]
IDEMPOTENCY_TTL_SECONDS  = int(sys.argv[8])
MIP003_MODE              = str(sys.argv[9] or 'compat').strip().lower()
ONTOLOGY_DIR             = sys.argv[10]
if MIP003_MODE not in ('compat', 'strict'):
    MIP003_MODE = 'compat'

def _coerce_int_env(name, default):
    try:
        return int(str(os.environ.get(name, default)).strip())
    except Exception:
        return int(default)

def _coerce_bool_env(name, default=False):
    raw = str(os.environ.get(name, '1' if default else '0')).strip().lower()
    return raw in ('1', 'true', 'yes', 'on')

def _coerce_float_env(name, default):
    try:
        return float(str(os.environ.get(name, default)).strip())
    except Exception:
        return float(default)

DB_BACKEND = str(os.environ.get('NIGHTPAY_DB_BACKEND', 'sqlite')).strip().lower() or 'sqlite'
if DB_BACKEND not in ('sqlite', 'postgres'):
    DB_BACKEND = 'sqlite'

DATABASE_URL = str(os.environ.get('NIGHTPAY_DATABASE_URL', '')).strip()
DB_POOL_SIZE = _coerce_int_env('NIGHTPAY_DB_POOL_SIZE', 64)
if DB_POOL_SIZE < 1:
    DB_POOL_SIZE = 1

if DB_BACKEND == 'postgres' and not DATABASE_URL:
    raise RuntimeError('NIGHTPAY_DATABASE_URL is required when NIGHTPAY_DB_BACKEND=postgres')

def _normalize_management_llm_url(raw):
    base = str(raw or '').strip()
    if not base:
        base = 'https://api.nightpay.dev/ollama'
    if '://' not in base:
        base = f'https://{base}'
    return base.rstrip('/')

AGENT_IDENTITY_ENFORCE = _coerce_bool_env('AGENT_IDENTITY_ENFORCE', False)
AGENT_CHALLENGE_TTL_SECONDS = _coerce_int_env('AGENT_CHALLENGE_TTL_SECONDS', 600)
AGENT_VERIFIED_TOKEN_TTL_SECONDS = _coerce_int_env('AGENT_VERIFIED_TOKEN_TTL_SECONDS', 86400)
AGENT_FINGERPRINT_SALT = str(os.environ.get('AGENT_FINGERPRINT_SALT', JOB_TOKEN_SECRET)).strip() or JOB_TOKEN_SECRET
MIP003_MAX_INFLIGHT = _coerce_int_env('MIP003_MAX_INFLIGHT', 512)
MANAGEMENT_LLM_ENABLED = _coerce_bool_env('MANAGEMENT_LLM_ENABLED', True)
MANAGEMENT_LLM_URL = _normalize_management_llm_url(os.environ.get('MANAGEMENT_LLM_URL', 'https://api.nightpay.dev/ollama'))
MANAGEMENT_LLM_MODEL = str(os.environ.get('MANAGEMENT_LLM_MODEL', 'granite4:3b')).strip() or 'granite4:3b'
MANAGEMENT_LLM_TIMEOUT_SECONDS = _coerce_int_env('MANAGEMENT_LLM_TIMEOUT_SECONDS', 25)
if MANAGEMENT_LLM_TIMEOUT_SECONDS < 5:
    MANAGEMENT_LLM_TIMEOUT_SECONDS = 5
if MANAGEMENT_LLM_TIMEOUT_SECONDS > 120:
    MANAGEMENT_LLM_TIMEOUT_SECONDS = 120
MANAGEMENT_LLM_TEMPERATURE = _coerce_float_env('MANAGEMENT_LLM_TEMPERATURE', 0.2)
if MANAGEMENT_LLM_TEMPERATURE < 0.0:
    MANAGEMENT_LLM_TEMPERATURE = 0.0
if MANAGEMENT_LLM_TEMPERATURE > 1.0:
    MANAGEMENT_LLM_TEMPERATURE = 1.0
MANAGEMENT_LLM_API_KEY = str(os.environ.get('MANAGEMENT_LLM_API_KEY', '')).strip()
if AGENT_CHALLENGE_TTL_SECONDS < 30:
    AGENT_CHALLENGE_TTL_SECONDS = 30
if AGENT_VERIFIED_TOKEN_TTL_SECONDS < 60:
    AGENT_VERIFIED_TOKEN_TTL_SECONDS = 60
if MIP003_MAX_INFLIGHT < 32:
    MIP003_MAX_INFLIGHT = 32

KNOWN_STATUSES = ('running', 'awaiting_approval', 'multisig_pending', 'disputed', 'completed')
MAX_ATTACHMENT_BYTES = 256 * 1024  # .md or .txt attachment at start_job (authenticated only)
MIP003_STATUSES = ('awaiting_payment', 'awaiting_input', 'running', 'completed', 'failed')

ID_RE = re.compile(r'^[A-Za-z0-9._:@-]{2,128}$')

POTENTIAL_USE_CASES = [
    {
        'id': 'governance-fact-check',
        'title': 'Governance claim fact-check pools',
        'starter_bounty': 'Fact-check proposal XYZ against 10 cited sources and return a claim-by-claim evidence matrix with risk tags.',
        'sources': [
            'https://arxiv.org/abs/2407.02226',
            'https://nightpay.dev/',
        ],
    },
    {
        'id': 'oss-issue-acceleration',
        'title': 'Open-source issue acceleration pools',
        'starter_bounty': 'Resolve issue #123 with passing tests, migration notes, and a short benchmark diff before and after the fix.',
        'sources': [
            'https://github.com/marketplace/bountyhub-app',
            'https://githoney.io/',
            'https://collaborators.build/',
        ],
    },
    {
        'id': 'security-triage',
        'title': 'Security bug triage and reproduction',
        'starter_bounty': 'Reproduce auth bypass in target service, submit minimal PoC, impact analysis, and patch guidance checklist.',
        'sources': [
            'https://bounty.github.com/',
            'https://arxiv.org/abs/2408.10648',
        ],
    },
    {
        'id': 'crypto-rnd',
        'title': 'Cryptography and privacy R&D tasks',
        'starter_bounty': 'Implement and benchmark operation-level optimization in FHE module X, including reproducible scripts and tests.',
        'sources': [
            'https://github.com/zama-ai/bounty-program',
            'https://arxiv.org/abs/2401.01204',
        ],
    },
    {
        'id': 'multi-agent-eval',
        'title': 'Multi-agent benchmark and routing evaluations',
        'starter_bounty': 'Compare orchestration strategy A vs B on 20 tasks and deliver success rate, cost, latency, and failure taxonomy.',
        'sources': [
            'https://arxiv.org/abs/2512.20973',
            'https://arxiv.org/abs/2504.00587',
        ],
    },
]

MANAGEMENT_CHAT_MODES = ('general', 'onboarding', 'troubleshooting', 'deploy', 'security')

def _contains_any(haystack, needles):
    return any(needle in haystack for needle in needles)

def build_management_chat_payload(message, mode, base_url):
    clean_mode = str(mode or 'general').strip().lower()
    if clean_mode not in MANAGEMENT_CHAT_MODES:
        clean_mode = 'general'

    text = ' '.join(str(message or '').strip().lower().split())
    intent = 'general_onboarding'
    references = ['docs/AGENT_PLAYGROUND.md', 'docs/architecture.md', 'README.md']
    actions = [
        {
            'title': 'Run health checks',
            'command': 'bash scripts/agent-playground-setup.sh doctor',
            'why': 'Confirms UI, MIP-003, and required env values in one pass.',
        },
        {
            'title': 'Check API availability',
            'command': f'curl -sS {base_url}/availability | python3 -m json.tool',
            'why': 'Verifies your public API host is reachable and returning JSON.',
        },
    ]
    reply = (
        'I am the NightPay CEO assistant. I can help onboard external agents, set up operator infrastructure, and troubleshoot deployments. '
        'Let me know what kind of agent you want to onboard or what your current blocker is.'
    )

    if _contains_any(text, ('domain', 'dns', 'caddy', 'subdomain', 'nightpay.dev', 'api.nightpay.dev', 'bridge.nightpay.dev', 'docs.nightpay.dev', 'ceo.nightpay.dev')):
        intent = 'domain_routing'
        references = ['README.md', 'docs/HETZNER_X86_RUNBOOK.md', 'docs/SERVER_BOOTSTRAP_COPYPASTE.md']
        actions = [
            {
                'title': 'Verify public hosts',
                'command': 'dig +short nightpay.dev api.nightpay.dev bridge.nightpay.dev docs.nightpay.dev ceo.nightpay.dev',
                'why': 'All hosts should resolve to your VPS public IP before TLS provisioning.',
            },
            {
                'title': 'Caddy smoke test',
                'command': 'curl -I https://nightpay.dev && curl -I https://api.nightpay.dev/availability && curl -I https://bridge.nightpay.dev/health',
                'why': 'Checks that UI, MIP-003 API, and bridge are correctly routed.',
            },
        ]
        reply = (
            'Use five public hosts: nightpay.dev, api.nightpay.dev, bridge.nightpay.dev, docs.nightpay.dev, and ceo.nightpay.dev. '
            'Keep only 80/443 public and reverse-proxy internal ports (3333/8090/4000). '
            'Route docs.nightpay.dev to your docs page and ceo.nightpay.dev to the CEO assistant UI.'
        )
    elif _contains_any(text, ('start', 'bootstrap', 'init', 'onboard', 'setup', 'install')):
        intent = 'operator_onboarding'
        references = ['docs/AGENT_PLAYGROUND.md', 'docs/SERVER_BOOTSTRAP_COPYPASTE.md']
        actions = [
            {
                'title': 'Initialize runtime',
                'command': 'bash scripts/agent-playground-setup.sh init',
                'why': 'Creates .agent-playground env and runtime folders.',
            },
            {
                'title': 'Start services',
                'command': 'bash scripts/agent-playground-setup.sh start',
                'why': 'Starts UI and MIP-003 service with your current env.',
            },
            {
                'title': 'Validate setup',
                'command': 'bash scripts/agent-playground-setup.sh doctor',
                'why': 'Detects missing MASUMI_API_KEY, OPERATOR_ADDRESS, contract address, and URL wiring.',
            },
        ]
        reply = (
            'Onboarding path: init runtime, set env values, start services, then run doctor. '
            'If doctor fails, paste the exact failing check and I will narrow it to one fix.'
        )
    elif _contains_any(text, ('agent', 'worker', 'external', 'skill', 'openclaw', 'claude')):
        intent = 'agent_onboarding'
        references = ['AGENTS.md', 'docs/AGENT_PLAYGROUND.md']
        actions = [
            {
                'title': 'Read AGENTS.md instructions',
                'command': 'cat AGENTS.md',
                'why': 'Crucial for coding instructions and understanding the Midnight and Masumi ecosystems.',
            },
            {
                'title': 'Run Gateway Find Agent',
                'command': 'bash skills/nightpay/scripts/gateway.sh find-agent',
                'why': 'Searches the network for available external agents compatible with your jobs.',
            },
            {
                'title': 'List API Endpoints for Agents',
                'command': f'curl -sS {base_url}/input_schema | python3 -m json.tool',
                'why': 'Shows the expected payload schemas that external agents need to comply with.',
            },
        ]
        reply = (
            'To onboard external agents, ensure they read AGENTS.md for ecosystem rules. '
            'External agents interact via the MIP-003 API (e.g., /start_job, /claim_job, /provide_result). '
            'Use the find-agent command to discover active workers on the network.'
        )
    elif _contains_any(text, ('navigate', 'knowledge graph', 'rag', 'structure', 'explain site', 'ontology')):
        intent = 'site_navigation'
        references = ['docs/NIGHTPAY_ONTOLOGY.md', 'docs/architecture.md']
        actions = [
            {
                'title': 'Fetch Site Knowledge Graph (Ontology)',
                'command': f'curl -sS {base_url}/ontology | python3 -m json.tool',
                'why': 'Returns the JSON-LD ontology which acts as the semantic knowledge graph of NightPay.',
            },
            {
                'title': 'Read Knowledge Graph Examples',
                'command': f'curl -sS {base_url}/ontology/examples | python3 -m json.tool',
                'why': 'Provides specific knowledge graph examples for workflows like pool funding and job delegation.',
            },
            {
                'title': 'Review Available Pages',
                'command': 'ls -1 ui/src/pages/',
                'why': 'Shows the structure of the UI: Board (tasks), CEO (management), Stats, Post, Agents.',
            },
        ]
        reply = (
            'I use a Knowledge Graph (JSON-LD ontology) and Retrieval-Augmented Generation (RAG) approaches to map the site. '
            'External agents can navigate NightPay by fetching our ontology endpoints. '
            'Key UI pages include: Board (/board) for jobs, Post (/post) to fund, and Agents (/agents) for the worker directory.'
        )
    elif _contains_any(text, ('bridge', 'proof', '6300', 'operator_address', 'receipt_contract_address', 'deploy contract')):
        intent = 'bridge_onchain'
        references = ['docs/AGENT_PLAYGROUND.md', 'docs/architecture.md']
        actions = [
            {
                'title': 'Read operator address',
                'command': 'curl -sS "$BRIDGE_URL/operator-address" | python3 -m json.tool',
                'why': 'Returns the 64-char lowercase OPERATOR_ADDRESS required by gateway initialize.',
            },
            {
                'title': 'Deploy receipt contract',
                'command': 'curl -sS -X POST "$BRIDGE_URL/deploy" -H "Authorization: Bearer $BRIDGE_ADMIN_TOKEN" -H "Content-Type: application/json" -d \'{"contractPath":"skills/nightpay/contracts/receipt.js","zkPath":"skills/nightpay/contracts/receipt.zk","operatorFeeBps":200}\' | python3 -m json.tool',
                'why': 'Returns RECEIPT_CONTRACT_ADDRESS used by gateway commands.',
            },
        ]
        reply = (
            'For on-chain mode, set BRIDGE_URL first, then fetch OPERATOR_ADDRESS, then deploy to get RECEIPT_CONTRACT_ADDRESS. '
            'Keep proof server local at 127.0.0.1:6300 and leave MIDNIGHT_NETWORK as preprod until mainnet checklist approval.'
        )
    elif _contains_any(text, ('refund', 'dispute', 'stuck', 'failed', 'error', 'claim', 'multisig', 'job')):
        intent = 'job_troubleshooting'
        references = ['README.md', 'docs/AGENT_PLAYGROUND.md', 'docs/architecture.md']
        actions = [
            {
                'title': 'Inspect job status',
                'command': f'curl -sS {base_url}/status?job_id=<job_id> | python3 -m json.tool',
                'why': 'Shows current lifecycle state and whether it is eligible for complete/dispute/refund paths.',
            },
            {
                'title': 'Dry-run unclaimed refunds',
                'command': './skills/nightpay/scripts/gateway.sh refund-unclaimed --dry-run',
                'why': 'Safely lists running jobs eligible for no-agent refund without applying changes.',
            },
            {
                'title': 'Check runtime logs',
                'command': 'tail -n 100 .agent-playground/logs/mip003.log && tail -n 100 .agent-playground/logs/ui.log',
                'why': 'Fastest way to identify 4xx/5xx causes and malformed payloads.',
            },
        ]
        reply = (
            'Troubleshooting should start with current job status, then route by state: running/unclaimed -> refund sweep; '
            'awaiting_approval or multisig_pending -> approval/dispute path; disputed -> operator resolution flow.'
        )
    elif _contains_any(text, ('secret', 'api key', 'token', 'seed', 'mnemonic', '.env', 'credential')):
        intent = 'security_hardening'
        references = ['AGENTS.md', 'docs/AGENT_PLAYGROUND.md']
        actions = [
            {
                'title': 'Audit leaked secrets in repo',
                'command': 'rg -n "WALLET_SEED|MASUMI_API_KEY|OPERATOR_SECRET_KEY|JOB_TOKEN_SECRET|mnemonic" .',
                'why': 'Confirms no sensitive material is committed in plaintext.',
            },
            {
                'title': 'Rotate runtime secrets',
                'command': 'bash scripts/agent-playground-setup.sh init',
                'why': 'Regenerates local operator and job token secrets when needed.',
            },
        ]
        reply = (
            'Never share wallet seeds, mnemonics, operator keys, or raw funding nullifiers in chat or logs. '
            'Use environment variables and rotate secrets if exposure is suspected.'
        )

    return {
        'status': 'ok',
        'agent': 'nightpay-ceo',
        'mode': clean_mode,
        'intent': intent,
        'reply': reply,
        'actions': actions,
        'references': references,
        'timestamp': datetime.now(timezone.utc).isoformat(),
    }

def _sanitize_management_history(raw):
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw[-8:]:
        if not isinstance(item, dict):
            continue
        role = str(item.get('role', '')).strip().lower()
        if role not in ('user', 'assistant'):
            continue
        content = str(item.get('content', '')).strip()
        if not content:
            continue
        out.append({
            'role': role,
            'content': content[:1200],
        })
    return out

def _management_system_prompt(mode, fallback_payload):
    references = ', '.join(fallback_payload.get('references', [])[:4])
    actions = fallback_payload.get('actions', [])
    action_text = '\n'.join([
        f"- {a.get('title')}: {a.get('command')}" for a in actions if a.get('title') and a.get('command')
    ])[:2500]
    return (
        "You are NightPay CEO assistant for operators onboarding other agents.\n"
        "Be concise and action-oriented.\n"
        "Do not invent architecture, commands, files, ports, hostnames, or secrets.\n"
        "If details are missing, say so explicitly instead of guessing.\n"
        "Never request or expose secrets: WALLET_SEED, MASUMI_API_KEY, OPERATOR_SECRET_KEY, JOB_TOKEN_SECRET, private keys, mnemonics, funding nullifiers.\n"
        "Use NightPay conventions: keep ports 3333/8090/4000 private behind Caddy, public hosts for nightpay/api/bridge/docs/ceo, and preprod defaults.\n"
        "Known host mapping: nightpay/docs/ceo -> 3333, api -> 8090, bridge -> 4000.\n"
        f"Current mode: {mode}.\n"
        f"Reference docs: {references}\n"
        "Return plain text only, max 10 short bullet lines.\n"
        "Use only command snippets present in Suggested actions unless user explicitly asks for alternatives.\n"
        "Suggested actions:\n"
        f"{action_text}"
    )

def _llm_reply_safe_for_ops(reply):
    text = str(reply or '').strip()
    if not text:
        return False
    if len(text) > 1800:
        return False
    lowered = text.lower()
    banned_fragments = (
        'route 53',
        '/var/log/',
        'systemctl',
        'root *',
        'catchall',
        'youremail@',
        'cname',
    )
    if any(fragment in lowered for fragment in banned_fragments):
        return False
    if '```' in text:
        return False

    allowed_ports = {'80', '443', '3333', '4000', '6300', '8090'}
    for match in re.finditer(r':(\d{2,5})', text):
        if match.group(1) not in allowed_ports:
            return False
    return True

def _ollama_headers():
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
    }
    if MANAGEMENT_LLM_API_KEY:
        headers['Authorization'] = f'Bearer {MANAGEMENT_LLM_API_KEY}'
    return headers

def _ollama_available_models():
    endpoint = f'{MANAGEMENT_LLM_URL}/api/tags'
    req = urlrequest.Request(endpoint, headers=_ollama_headers(), method='GET')
    with urlrequest.urlopen(req, timeout=MANAGEMENT_LLM_TIMEOUT_SECONDS) as resp:
        raw = resp.read().decode('utf-8', errors='replace')
        parsed = json.loads(raw) if raw else {}
    models = parsed.get('models') if isinstance(parsed, dict) else None
    if not isinstance(models, list):
        return []
    names = []
    for item in models:
        if isinstance(item, dict):
            name = str(item.get('name', '')).strip()
            if name:
                names.append(name)
    def _rank(name):
        lowered = name.lower()
        score = 100
        if 'embed' in lowered or 'embedding' in lowered or 'ocr' in lowered:
            score += 200
        if 'flash' in lowered or 'small' in lowered or 'nano' in lowered:
            score -= 25
        m = re.search(r':(\d+(?:\.\d+)?)b\b', lowered)
        if m:
            try:
                size = float(m.group(1))
                score += int(size * 3)
            except Exception:
                pass
        if 'latest' in lowered:
            score += 10
        return score
    return sorted(names, key=_rank)

def _ollama_chat_once(endpoint, req_body):
    req = urlrequest.Request(
        endpoint,
        data=json.dumps(req_body, ensure_ascii=False).encode('utf-8'),
        headers=_ollama_headers(),
        method='POST',
    )
    with urlrequest.urlopen(req, timeout=MANAGEMENT_LLM_TIMEOUT_SECONDS) as resp:
        raw = resp.read().decode('utf-8', errors='replace')
        parsed = json.loads(raw) if raw else {}

    content = ''
    if isinstance(parsed, dict):
        msg_obj = parsed.get('message')
        if isinstance(msg_obj, dict):
            content = str(msg_obj.get('content', '')).strip()
        if not content:
            content = str(parsed.get('response', '')).strip()
    if not content:
        raise RuntimeError('ollama response missing message.content')
    return content[:6000]

def _call_management_llm(mode, message, history, fallback_payload):
    endpoint = f'{MANAGEMENT_LLM_URL}/api/chat'
    messages = [{'role': 'system', 'content': _management_system_prompt(mode, fallback_payload)}]
    messages.extend(history)
    messages.append({'role': 'user', 'content': str(message or '').strip()[:4000]})

    def _request_with_model(model_name):
        req_body = {
            'model': model_name,
            'messages': messages,
            'stream': False,
            'options': {
                'temperature': MANAGEMENT_LLM_TEMPERATURE,
            },
        }
        return _ollama_chat_once(endpoint, req_body)

    configured_model = str(MANAGEMENT_LLM_MODEL or '').strip()
    discovered_models = []
    try:
        discovered_models = _ollama_available_models()
    except Exception:
        discovered_models = []

    models_to_try = []
    if configured_model:
        models_to_try.append(configured_model)
    for name in discovered_models:
        if name not in models_to_try:
            models_to_try.append(name)
    models_to_try = models_to_try[:8]

    if not models_to_try:
        return '', 'ollama has no available models', configured_model

    errors = []
    for model_name in models_to_try:
        try:
            return _request_with_model(model_name), '', model_name
        except urlerror.HTTPError as exc:
            err_raw = ''
            try:
                err_raw = exc.read().decode('utf-8', errors='replace')
            except Exception:
                err_raw = ''
            short = err_raw[:220] if err_raw else ''
            errors.append(f'{model_name}: http {exc.code} {short}'.strip())
        except Exception as exc:
            errors.append(f'{model_name}: {exc}')

    joined = ' | '.join(errors[:3])
    return '', f'ollama failed for models: {joined}', models_to_try[0]

def build_management_chat_response(message, mode, base_url, history):
    payload = build_management_chat_payload(message=message, mode=mode, base_url=base_url)
    payload['assistant_backend'] = 'heuristic'
    payload['fallback_used'] = True
    payload['model'] = ''

    if not MANAGEMENT_LLM_ENABLED:
        payload['fallback_used'] = True
        payload['llm_error'] = 'llm disabled by MANAGEMENT_LLM_ENABLED'
        return payload

    sanitized_history = _sanitize_management_history(history)
    llm_reply, llm_error, llm_model = _call_management_llm(
        mode=payload.get('mode', mode),
        message=message,
        history=sanitized_history,
        fallback_payload=payload,
    )
    if llm_reply:
        payload['assistant_backend'] = 'ollama'
        payload['model'] = llm_model or MANAGEMENT_LLM_MODEL
        payload['fallback_used'] = True
        if _llm_reply_safe_for_ops(llm_reply):
            payload['llm_error'] = 'ollama reply received; deterministic guidance enforced'
        else:
            payload['llm_error'] = 'ollama reply rejected by safety filter; using deterministic guidance'
        payload['llm_reply_preview'] = llm_reply[:320]
        return payload

    payload['llm_error'] = llm_error
    return payload

def load_json_file(path, fallback):
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            return json.load(fh)
    except Exception as exc:
        print(f'[nightpay] WARNING: failed to load JSON file {path}: {exc}')
        return fallback

def load_ontology_examples(base_dir):
    out = {}
    pattern = os.path.join(base_dir, 'examples', '*.jsonld')
    for path in sorted(glob.glob(pattern)):
        doc = load_json_file(path, None)
        if doc is None:
            continue
        filename = os.path.basename(path)
        name = filename.replace('.example.jsonld', '').replace('.jsonld', '')
        out[name] = doc
    return out

ONTOLOGY_CONTEXT = load_json_file(
    os.path.join(ONTOLOGY_DIR, 'context.jsonld'),
    {
        '@context': {
            'nightpay': 'https://nightpay.dev/ontology#'
        }
    }
)
ONTOLOGY_SPEC = load_json_file(
    os.path.join(ONTOLOGY_DIR, 'ontology.jsonld'),
    {
        '@context': 'https://nightpay.dev/ontology/context',
        'id': 'https://nightpay.dev/ontology',
        'type': 'rdfs:Resource',
        'name': 'NightPay Ontology',
        'description': 'Fallback NightPay ontology document.',
        'version': '1.0.0'
    }
)
ONTOLOGY_EXAMPLES = load_ontology_examples(ONTOLOGY_DIR)
if not ONTOLOGY_EXAMPLES:
    print(f'[nightpay] WARNING: no ontology examples loaded from {os.path.join(ONTOLOGY_DIR, "examples")}')

# ─── Security helpers ─────────────────────────────────────────────────────────

def make_job_token(job_id):
    # domain-separated — cannot be reused as any other HMAC in the system
    msg = f'nightpay-job-token-v1:{job_id}'
    return hmac.new(JOB_TOKEN_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()

def verify_job_token(job_id, token):
    return hmac.compare_digest(make_job_token(job_id), token)

def verify_work_reveal(work_commit, work, nonce):
    # SECURITY: domain-separated reveal hash — matches gateway.sh convention
    revealed = hashlib.sha256(f'nightpay-work-reveal-v1:{work}:{nonce}'.encode()).hexdigest()
    return hmac.compare_digest(revealed, work_commit)

def verify_operator_sig(job_id, reason, sig):
    # Operator signs: HMAC(OPERATOR_SECRET_KEY, 'dispute:{job_id}:{reason}')
    msg = f'dispute:{job_id}:{reason}'
    expected = hmac.new(OPERATOR_SECRET_KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)

def verify_operator_session_token(token):
    # Time-limited token from CLI (e.g. SSH): ops.<expiry_ts>.<hmac_hex>
    if not token or not isinstance(token, str) or not token.startswith('ops.') or token.count('.') != 2:
        return False
    try:
        _, expiry_str, sig = token.split('.', 2)
        expiry_ts = int(expiry_str)
    except (ValueError, AttributeError):
        return False
    if datetime.now(timezone.utc).timestamp() > expiry_ts:
        return False
    msg = f'ops:{expiry_str}'
    expected = hmac.new(OPERATOR_SECRET_KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(sig, expected)

def validate_actor_id(value):
    return bool(ID_RE.match(str(value or '').strip()))

def make_agent_challenge_message(challenge_id, agent_id, nonce, issued_at, expires_at, domain, algorithm, chain):
    # Canonical challenge envelope used for detached signature verification.
    return '\n'.join([
        'nightpay-agent-challenge-v1',
        f'challenge_id:{challenge_id}',
        f'agent_id:{agent_id}',
        f'nonce:{nonce}',
        f'issued_at:{issued_at}',
        f'expires_at:{expires_at}',
        f'domain:{domain}',
        f'algorithm:{algorithm}',
        f'chain:{chain}',
    ])

def verify_agent_signature(algorithm, public_key_hex, signature_hex, message):
    algo = str(algorithm or '').strip().lower()
    if algo != 'ed25519':
        return False, 'unsupported algorithm: expected ed25519', None
    if Ed25519PublicKey is None:
        return False, 'ed25519 verification unavailable (install python cryptography package)', None

    try:
        pub_bytes = bytes.fromhex(str(public_key_hex or '').strip())
        sig_bytes = bytes.fromhex(str(signature_hex or '').strip())
    except Exception:
        return False, 'public_key_hex and signature_hex must be lowercase/uppercase hex strings', None

    if len(pub_bytes) != 32:
        return False, 'public_key_hex must decode to 32 bytes for ed25519', None
    if len(sig_bytes) != 64:
        return False, 'signature_hex must decode to 64 bytes for ed25519', None

    try:
        Ed25519PublicKey.from_public_bytes(pub_bytes).verify(sig_bytes, message.encode('utf-8'))
        return True, '', pub_bytes
    except Exception:
        return False, 'signature verification failed', None

def make_agent_fingerprint(agent_id, chain, wallet_address, midnight_address, masumi_agent_id, public_key_hash):
    # Salted fingerprint prevents raw key material from becoming a stable public correlation key.
    canonical = json.dumps({
        'v': 1,
        'agent_id': str(agent_id or '').strip(),
        'chain': str(chain or '').strip().lower(),
        'wallet_address': str(wallet_address or '').strip(),
        'midnight_address': str(midnight_address or '').strip(),
        'masumi_agent_id': str(masumi_agent_id or '').strip(),
        'public_key_hash': str(public_key_hash or '').strip(),
    }, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(f'nightpay-agent-fingerprint-v1:{canonical}:{AGENT_FINGERPRINT_SALT}'.encode()).hexdigest()

def make_verified_agent_token(agent_id, fingerprint_hash):
    issued_at = int(datetime.now(timezone.utc).timestamp())
    msg = f'nightpay-agent-auth-v1:{agent_id}:{issued_at}:{fingerprint_hash}'
    sig = hmac.new(JOB_TOKEN_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return f'npaid.{agent_id}.{issued_at}.{sig}'

def safe_json_loads(raw, fallback):
    if raw in (None, ''):
        return fallback
    try:
        return json.loads(raw)
    except Exception:
        return fallback

def parse_iso8601(raw):
    if raw in (None, ''):
        return None
    try:
        return datetime.fromisoformat(str(raw).replace('Z', '+00:00'))
    except Exception:
        return None

def parse_voter_snapshot(raw):
    rows = safe_json_loads(raw, [])
    if not isinstance(rows, list):
        return []
    out = []
    seen = set()
    for row in rows:
        actor_id = str(row or '').strip()
        if not validate_actor_id(actor_id):
            continue
        if actor_id in seen:
            continue
        seen.add(actor_id)
        out.append(actor_id)
    return out

def normalize_string_list(raw, max_items=16, max_len=64):
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if len(out) >= max_items:
            break
        text = str(item).strip()
        if not text:
            continue
        out.append(text[:max_len])
    return out

def normalize_showcase_entries(raw, max_items=8):
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if len(out) >= max_items:
            break
        if not isinstance(item, dict):
            continue
        title = str(item.get('title') or '').strip()[:120]
        summary = str(item.get('summary') or '').strip()[:420]
        if not title and not summary:
            continue
        entry = {
            'title': title or (summary[:90] if summary else 'Untitled work'),
            'summary': summary,
            'capabilities': normalize_string_list(item.get('capabilities', []), max_items=12, max_len=64),
        }
        proof_url = str(item.get('proof_url') or '').strip()[:300]
        if proof_url:
            entry['proof_url'] = proof_url
        out.append(entry)
    return out

def normalize_visibility(value, default='public'):
    # API accepts public | private; internal storage is public | hidden (private -> hidden).
    raw = str(value if value is not None else default).strip().lower()
    if raw not in ('public', 'private', 'hidden'):
        return None
    return 'hidden' if raw in ('private', 'hidden') else 'public'

def visibility_for_api(internal):
    """Return API-facing value: public | private (hidden -> private)."""
    if internal == 'hidden':
        return 'private'
    return (internal or 'public')

def _sigmoid(value):
    if value >= 60:
        return 1.0
    if value <= -60:
        return 0.0
    return 1.0 / (1.0 + math.exp(-value))

def compute_agent_credibility(db, agent_id, capabilities=None):
    agent_id = str(agent_id or '').strip()
    if not agent_id:
        return {
            'model': 'nightpay-variety-v1',
            'score': 0.0,
            'variety_index': 0.0,
            'features': {},
            'signals': {}
        }

    claimed = int(db.execute(
        'SELECT COUNT(*) AS n FROM job_claims WHERE agent_id = ?',
        (agent_id,)
    ).fetchone()['n'] or 0)
    completed = int(db.execute(
        "SELECT COUNT(*) AS n FROM jobs WHERE assigned_agent_id = ? AND status = 'completed'",
        (agent_id,)
    ).fetchone()['n'] or 0)

    vote_row = db.execute(
        '''SELECT
               COALESCE(SUM(CASE WHEN v.vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve_votes,
               COALESCE(SUM(CASE WHEN v.vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject_votes
           FROM job_votes v
           JOIN jobs j ON j.job_id = v.job_id
           WHERE j.assigned_agent_id = ?''',
        (agent_id,)
    ).fetchone()
    approve_votes = int(vote_row['approve_votes'] or 0) if vote_row else 0
    reject_votes = int(vote_row['reject_votes'] or 0) if vote_row else 0

    peer_rows = db.execute(
        '''SELECT jc2.agent_id, COUNT(*) AS co_jobs
           FROM job_claims jc
           JOIN job_claims jc2 ON jc.job_id = jc2.job_id
           WHERE jc.agent_id = ? AND jc2.agent_id != ?
           GROUP BY jc2.agent_id''',
        (agent_id, agent_id)
    ).fetchall()
    peer_counts = [int(r['co_jobs'] or 0) for r in peer_rows if int(r['co_jobs'] or 0) > 0]
    unique_peers = len(peer_counts)
    co_claim_total = sum(peer_counts)
    if co_claim_total > 0:
        simpson_diversity = 1.0 - sum((count / float(co_claim_total)) ** 2 for count in peer_counts)
    else:
        simpson_diversity = 0.0
    peer_spread = 1.0 - math.exp(-float(unique_peers) / 5.0)
    peer_variety = max(0.0, min(1.0, (0.55 * peer_spread) + (0.45 * simpson_diversity)))

    tag_rows = db.execute(
        '''SELECT input_data
           FROM jobs
           WHERE assigned_agent_id = ?
             AND status IN ('running', 'awaiting_approval', 'multisig_pending', 'completed')
           ORDER BY updated_at DESC
           LIMIT 500''',
        (agent_id,)
    ).fetchall()
    tag_counts = {}
    for row in tag_rows:
        data = safe_json_loads(row['input_data'], {})
        tags = normalize_string_list(data.get('tags', []) if isinstance(data, dict) else [], max_items=20, max_len=40)
        for tag in tags:
            key = str(tag).strip().lower()
            if not key:
                continue
            tag_counts[key] = int(tag_counts.get(key, 0)) + 1
    tag_total = sum(tag_counts.values())
    if tag_total > 0 and len(tag_counts) > 1:
        entropy = -sum((count / float(tag_total)) * math.log(count / float(tag_total)) for count in tag_counts.values())
        max_entropy = math.log(float(len(tag_counts)))
        entropy_norm = (entropy / max_entropy) if max_entropy > 0 else 0.0
    else:
        entropy_norm = 0.0
    tag_coverage = 1.0 - math.exp(-float(len(tag_counts)) / 6.0)
    domain_variety = max(0.0, min(1.0, (0.6 * entropy_norm) + (0.4 * tag_coverage)))

    normalized_capabilities = normalize_string_list(capabilities if capabilities is not None else [], max_items=32, max_len=64)
    capability_count = len(set([c.lower() for c in normalized_capabilities]))
    capability_breadth = 1.0 - math.exp(-float(capability_count) / 6.0)

    success_rate = float(completed + 1) / float(claimed + 2)
    review_quality = float(approve_votes + 1) / float(approve_votes + reject_votes + 2)
    if claimed > 0:
        sample_confidence = min(1.0, math.log1p(float(claimed)) / math.log(25.0))
    else:
        sample_confidence = 0.0
    abandonment_ratio = max(0.0, float(claimed - completed) / float(max(claimed, 1)))

    # ML-style linear model + logistic projection.
    z = (
        -1.6
        + (2.2 * success_rate)
        + (1.8 * peer_variety)
        + (1.0 * domain_variety)
        + (0.9 * review_quality)
        + (0.6 * capability_breadth)
        + (0.7 * sample_confidence)
        - (1.1 * abandonment_ratio)
    )
    score = round(_sigmoid(z) * 100.0, 2)
    variety_index = round((((0.7 * peer_variety) + (0.3 * domain_variety)) * 100.0), 2)

    return {
        'model': 'nightpay-variety-v1',
        'score': score,
        'variety_index': variety_index,
        'features': {
            'success_rate': round(success_rate, 4),
            'peer_variety': round(peer_variety, 4),
            'domain_variety': round(domain_variety, 4),
            'review_quality': round(review_quality, 4),
            'capability_breadth': round(capability_breadth, 4),
            'sample_confidence': round(sample_confidence, 4),
            'abandonment_ratio': round(abandonment_ratio, 4),
        },
        'signals': {
            'claimed_tasks': claimed,
            'completed_tasks': completed,
            'approve_votes': approve_votes,
            'reject_votes': reject_votes,
            'unique_peer_agents': unique_peers,
            'tag_domains': len(tag_counts),
        }
    }

def hash_start_job_request(body):
    # Canonical payload hash used for idempotency conflict detection.
    payload = dict(body)
    payload.pop('idempotency_key', None)
    canonical = json.dumps(payload, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(canonical.encode()).hexdigest()

def parse_contest_config(raw):
    # Contest mode enables multi-agent submissions + per-submission voting.
    if raw in (None, '', 'null'):
        return {
            'enabled': False,
            'min_agents': 1,
            'max_agents': 1,
            'min_votes_to_select': 1,
            'vote_window_hours': 24,
            'agent_voting_only': True
        }
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            return {
                'enabled': False,
                'min_agents': 1,
                'max_agents': 1,
                'min_votes_to_select': 1,
                'vote_window_hours': 24,
                'agent_voting_only': True
            }

    enabled = bool(raw.get('enabled', False))
    min_agents = int(raw.get('min_agents', 1) or 1)
    max_agents = int(raw.get('max_agents', 1) or 1)
    min_votes_to_select = int(raw.get('min_votes_to_select', 1) or 1)
    vote_window_hours = int(raw.get('vote_window_hours', 24) or 24)
    agent_voting_only = bool(raw.get('agent_voting_only', True))

    if min_agents < 1:
        min_agents = 1
    if max_agents < min_agents:
        max_agents = min_agents
    if max_agents > 20:
        max_agents = 20
    if min_votes_to_select < 1:
        min_votes_to_select = 1
    if vote_window_hours < 1:
        vote_window_hours = 1
    if vote_window_hours > 168:
        vote_window_hours = 168

    return {
        'enabled': enabled,
        'min_agents': min_agents,
        'max_agents': max_agents,
        'min_votes_to_select': min_votes_to_select,
        'vote_window_hours': vote_window_hours,
        'agent_voting_only': agent_voting_only
    }

def validate_contest_config(raw):
    if raw is None:
        return None, None
    if not isinstance(raw, dict):
        return None, 'contest must be an object'
    cfg = parse_contest_config(raw)
    if cfg['enabled'] and cfg['min_agents'] > 20:
        return None, 'contest min_agents cannot exceed 20'
    if cfg['enabled'] and cfg['max_agents'] > 20:
        return None, 'contest max_agents cannot exceed 20'
    if cfg['enabled'] and cfg['min_agents'] < 5:
        return None, 'contest min_agents must be >= 5 when enabled'
    if cfg['enabled'] and cfg['max_agents'] < cfg['min_agents']:
        return None, 'contest max_agents must be >= min_agents'
    if cfg['enabled'] and cfg['vote_window_hours'] < 1:
        return None, 'contest vote_window_hours must be >= 1'
    if cfg['enabled'] and cfg['vote_window_hours'] > 168:
        return None, 'contest vote_window_hours must be <= 168'
    return cfg, None

def ensure_voting_session(db, job_id, contest_cfg, now_dt, fallback_voter_id=None):
    row = db.execute(
        'SELECT voting_started_at, voting_ends_at, voter_snapshot FROM jobs WHERE job_id = ?',
        (job_id,)
    ).fetchone()
    if not row:
        return None, None, [], 'job not found'

    started_at = row['voting_started_at']
    voting_ends_at = row['voting_ends_at']
    voter_snapshot = parse_voter_snapshot(row['voter_snapshot'])
    if started_at and voting_ends_at and voter_snapshot:
        return started_at, voting_ends_at, voter_snapshot, None

    claim_rows = db.execute(
        'SELECT agent_id FROM job_claims WHERE job_id = ? ORDER BY claimed_at ASC, agent_id ASC',
        (job_id,)
    ).fetchall()
    voter_snapshot = []
    seen = set()
    for claim in claim_rows:
        actor_id = str(claim['agent_id'] or '').strip()
        if not validate_actor_id(actor_id):
            continue
        if actor_id in seen:
            continue
        seen.add(actor_id)
        voter_snapshot.append(actor_id)

    if fallback_voter_id:
        actor_id = str(fallback_voter_id or '').strip()
        if validate_actor_id(actor_id) and actor_id not in seen:
            seen.add(actor_id)
            voter_snapshot.append(actor_id)

    if not voter_snapshot:
        return None, None, [], 'no eligible voters available; agents must claim the job before voting'

    vote_window_hours = int(contest_cfg.get('vote_window_hours', 24) or 24)
    started_at = now_dt.isoformat()
    voting_ends_at = (now_dt + timedelta(hours=vote_window_hours)).isoformat()
    db.execute(
        '''UPDATE jobs
           SET voting_started_at = ?, voting_ends_at = ?, voter_snapshot = ?, updated_at = ?
           WHERE job_id = ?''',
        (started_at, voting_ends_at, json.dumps(voter_snapshot), started_at, job_id)
    )
    return started_at, voting_ends_at, voter_snapshot, None

def external_status_from_internal(internal_status, amount_specks):
    if internal_status == 'completed':
        return 'completed'
    if internal_status == 'disputed':
        return 'failed'
    if internal_status == 'running':
        return 'awaiting_payment' if int(amount_specks or 0) <= 0 else 'running'
    # NightPay intermediate statuses map to "running" in external taxonomy.
    if internal_status in ('awaiting_approval', 'multisig_pending'):
        return 'running'
    return 'failed'

def canonical_input_hash(input_data):
    payload = input_data if isinstance(input_data, dict) else {}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def strict_start_job_response(job_id, body, now_dt, amount_specks):
    input_data = body.get('input_data') if isinstance(body.get('input_data'), dict) else {}
    pay_by = now_dt + timedelta(hours=1)
    submit_by = now_dt + timedelta(hours=OPTIMISTIC_WINDOW_HOURS)
    unlock_at = submit_by + timedelta(hours=24)
    dispute_unlock_at = unlock_at + timedelta(hours=24)
    return {
        'id': job_id,
        'blockchainIdentifier': body.get('blockchainIdentifier') or job_id,
        'payByTime': pay_by.isoformat(),
        'submitResultTime': submit_by.isoformat(),
        'unlockTime': unlock_at.isoformat(),
        'externalDisputeUnlockTime': dispute_unlock_at.isoformat(),
        'agentIdentifier': body.get('agentIdentifier'),
        'sellerVKey': body.get('sellerVKey'),
        'identifierFromPurchaser': body.get('identifierFromPurchaser') or body.get('identifier_from_purchaser'),
        'input_hash': canonical_input_hash(input_data),
        'status': external_status_from_internal('running', amount_specks),
        'internal_status': 'running',
        'legacy': {
            'job_id': job_id,
            'job_token': make_job_token(job_id),
            'status': external_status_from_internal('running', amount_specks),
            'internal_status': 'running'
        }
    }

def record_status_event(db, job_id, status, input_schema=None, result=None, created_at=None):
    event_status = str(status or '').strip()
    if event_status not in MIP003_STATUSES:
        event_status = 'failed'
    ts = created_at or datetime.now(timezone.utc).isoformat()
    status_id = str(uuid.uuid4())
    db.execute(
        '''INSERT INTO job_status_events(status_id, job_id, status, input_schema, result, created_at)
           VALUES (?, ?, ?, ?, ?, ?)''',
        (
            status_id,
            job_id,
            event_status,
            json.dumps(input_schema) if input_schema is not None else None,
            json.dumps(result) if result is not None else None,
            ts
        )
    )
    return status_id

def latest_status_event(db, job_id):
    return db.execute(
        '''SELECT status_id, job_id, status, input_schema, result, created_at
           FROM job_status_events
           WHERE job_id = ?
           ORDER BY created_at DESC, status_id DESC
           LIMIT 1''',
        (job_id,)
    ).fetchone()

# ─── Database (SQLite default, Postgres for horizontal scale) ────────────────

SCHEMA_SQL = '''
    CREATE TABLE IF NOT EXISTS jobs (
        job_id         TEXT PRIMARY KEY,
        status         TEXT NOT NULL DEFAULT 'running',
        assigned_agent_id TEXT,
        visibility     TEXT NOT NULL DEFAULT 'public',
        input_data     TEXT,
        extra_input    TEXT,
        result         TEXT,
        contest_config TEXT,
        voting_started_at TEXT,
        voting_ends_at TEXT,
        voter_snapshot TEXT,
        started_at     TEXT NOT NULL,
        updated_at     TEXT NOT NULL,
        work_commit    TEXT,
        amount_specks  INTEGER,
        approved_at    TEXT,
        dispute_reason TEXT,
        approvals      TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_jobs_status   ON jobs(status);
    CREATE INDEX IF NOT EXISTS idx_jobs_status_approved ON jobs(status, approved_at)
        WHERE approved_at IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_jobs_approved ON jobs(approved_at)
        WHERE approved_at IS NOT NULL;

    CREATE TABLE IF NOT EXISTS agents (
        agent_id       TEXT PRIMARY KEY,
        name           TEXT NOT NULL,
        description    TEXT,
        capabilities   TEXT,
        showcase       TEXT,
        model_provider TEXT,
        model_name     TEXT,
        endpoint_url   TEXT,
        metadata       TEXT,
        created_at     TEXT NOT NULL,
        updated_at     TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_agents_updated_at ON agents(updated_at DESC);

    CREATE TABLE IF NOT EXISTS idempotency_keys (
        idem_key     TEXT PRIMARY KEY,
        request_hash TEXT NOT NULL,
        job_id       TEXT NOT NULL,
        created_at   TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_idempotency_created_at ON idempotency_keys(created_at);

    CREATE TABLE IF NOT EXISTS job_claims (
        job_id      TEXT NOT NULL,
        agent_id    TEXT NOT NULL,
        claimed_at  TEXT NOT NULL,
        PRIMARY KEY (job_id, agent_id)
    );
    CREATE INDEX IF NOT EXISTS idx_job_claims_job_id ON job_claims(job_id);

    CREATE TABLE IF NOT EXISTS job_votes (
        job_id      TEXT NOT NULL,
        voter_id    TEXT NOT NULL,
        vote        TEXT NOT NULL CHECK (vote IN ('approve', 'reject')),
        reason      TEXT,
        voted_at    TEXT NOT NULL,
        PRIMARY KEY (job_id, voter_id)
    );
    CREATE INDEX IF NOT EXISTS idx_job_votes_job_id ON job_votes(job_id);

    CREATE TABLE IF NOT EXISTS job_submissions (
        submission_id   TEXT PRIMARY KEY,
        job_id          TEXT NOT NULL,
        agent_id        TEXT NOT NULL,
        payload         TEXT NOT NULL,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        is_winner       INTEGER NOT NULL DEFAULT 0,
        selected_at     TEXT,
        UNIQUE(job_id, agent_id)
    );
    CREATE INDEX IF NOT EXISTS idx_job_submissions_job_id ON job_submissions(job_id);

    CREATE TABLE IF NOT EXISTS submission_votes (
        job_id         TEXT NOT NULL,
        submission_id  TEXT NOT NULL,
        voter_id       TEXT NOT NULL,
        vote           TEXT NOT NULL CHECK (vote IN ('approve', 'reject')),
        reason         TEXT,
        voted_at       TEXT NOT NULL,
        PRIMARY KEY (job_id, submission_id, voter_id)
    );
    CREATE INDEX IF NOT EXISTS idx_submission_votes_submission ON submission_votes(job_id, submission_id);

    CREATE TABLE IF NOT EXISTS job_status_events (
        status_id    TEXT PRIMARY KEY,
        job_id       TEXT NOT NULL,
        status       TEXT NOT NULL,
        input_schema TEXT,
        result       TEXT,
        created_at   TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_job_status_events_job_id_created_at
        ON job_status_events(job_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS agent_challenges (
        challenge_id      TEXT PRIMARY KEY,
        agent_id          TEXT NOT NULL,
        algorithm         TEXT NOT NULL,
        chain             TEXT,
        wallet_address    TEXT,
        midnight_address  TEXT,
        masumi_agent_id   TEXT,
        challenge_message TEXT NOT NULL,
        nonce             TEXT NOT NULL,
        created_at        TEXT NOT NULL,
        expires_at        TEXT NOT NULL,
        used_at           TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_agent_challenges_agent_id ON agent_challenges(agent_id);
    CREATE INDEX IF NOT EXISTS idx_agent_challenges_expires_at ON agent_challenges(expires_at);

    CREATE TABLE IF NOT EXISTS agent_identities (
        agent_id           TEXT PRIMARY KEY,
        algorithm          TEXT NOT NULL,
        chain              TEXT,
        public_key_hex     TEXT NOT NULL,
        public_key_hash    TEXT NOT NULL,
        wallet_address     TEXT,
        midnight_address   TEXT,
        masumi_agent_id    TEXT,
        cardano_stake_addr TEXT,
        fingerprint_hash   TEXT NOT NULL,
        challenge_id       TEXT NOT NULL,
        metadata           TEXT,
        verified_at        TEXT NOT NULL,
        revoked_at         TEXT,
        created_at         TEXT NOT NULL,
        updated_at         TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_agent_identities_fingerprint ON agent_identities(fingerprint_hash);
    CREATE INDEX IF NOT EXISTS idx_agent_identities_verified_at ON agent_identities(verified_at DESC);

    CREATE TABLE IF NOT EXISTS job_artifacts (
        artifact_id    TEXT PRIMARY KEY,
        job_id         TEXT NOT NULL,
        filename       TEXT NOT NULL,
        content_type   TEXT NOT NULL DEFAULT 'application/octet-stream',
        content        BLOB NOT NULL,
        size_bytes     INTEGER NOT NULL,
        description    TEXT,
        uploaded_by    TEXT,
        uploaded_at    TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_job_artifacts_job_id ON job_artifacts(job_id);
'''

MIGRATION_SQL = [
    'ALTER TABLE jobs ADD COLUMN assigned_agent_id TEXT',
    "ALTER TABLE jobs ADD COLUMN visibility TEXT NOT NULL DEFAULT 'public'",
    'ALTER TABLE jobs ADD COLUMN work_commit    TEXT',
    'ALTER TABLE jobs ADD COLUMN amount_specks  INTEGER',
    'ALTER TABLE jobs ADD COLUMN approved_at    TEXT',
    'ALTER TABLE jobs ADD COLUMN dispute_reason TEXT',
    'ALTER TABLE jobs ADD COLUMN approvals      TEXT',
    'ALTER TABLE jobs ADD COLUMN contest_config TEXT',
    'ALTER TABLE jobs ADD COLUMN voting_started_at TEXT',
    'ALTER TABLE jobs ADD COLUMN voting_ends_at TEXT',
    'ALTER TABLE jobs ADD COLUMN voter_snapshot TEXT',
    'ALTER TABLE agents ADD COLUMN showcase TEXT',
    'ALTER TABLE agents ADD COLUMN artifact_beta_approved INTEGER NOT NULL DEFAULT 0',
]

def _replace_qmark_placeholders(sql):
    out = []
    in_single = False
    in_double = False
    i = 0
    while i < len(sql):
        ch = sql[i]
        if ch == "'" and not in_double:
            if in_single and i + 1 < len(sql) and sql[i + 1] == "'":
                out.append("''")
                i += 2
                continue
            in_single = not in_single
            out.append(ch)
            i += 1
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            i += 1
            continue
        if ch == '?' and not in_single and not in_double:
            out.append('%s')
        else:
            out.append(ch)
        i += 1
    return ''.join(out)

def _rewrite_sql_for_postgres(sql):
    q = str(sql)
    if '?' in q:
        q = _replace_qmark_placeholders(q)
    if re.match(r'^\s*BEGIN\s+IMMEDIATE\b', q, flags=re.IGNORECASE):
        return 'BEGIN'
    if re.match(r'^\s*INSERT\s+OR\s+IGNORE\s+INTO\b', q, flags=re.IGNORECASE):
        q = re.sub(r'^\s*INSERT\s+OR\s+IGNORE\s+INTO\b', 'INSERT INTO', q, count=1, flags=re.IGNORECASE)
        if re.search(r'\bON\s+CONFLICT\b', q, flags=re.IGNORECASE) is None:
            q = q.rstrip().rstrip(';') + ' ON CONFLICT DO NOTHING'
    q = re.sub(r'\bBLOB\b', 'BYTEA', q, flags=re.IGNORECASE)
    return q

def _split_sql_script(script):
    statements = []
    for part in str(script).split(';'):
        stmt = part.strip()
        if stmt:
            statements.append(stmt)
    return statements

class PostgresCompatConnection:
    def __init__(self, raw_conn, driver):
        self._conn = raw_conn
        self._driver = driver

    def _cursor(self):
        if self._driver == 'psycopg':
            return self._conn.cursor(row_factory=_pg_dict_row)
        return self._conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    def execute(self, sql, params=()):
        q = _rewrite_sql_for_postgres(sql)
        cur = self._cursor()
        cur.execute(q, tuple(params or ()))
        return cur

    def executescript(self, script):
        for stmt in _split_sql_script(script):
            self.execute(stmt)

    def commit(self):
        self._conn.commit()

    def rollback(self):
        self._conn.rollback()

    def close(self):
        self._conn.close()

def _new_postgres_connection():
    if psycopg is not None:
        raw = psycopg.connect(DATABASE_URL)
        raw.autocommit = False
        return PostgresCompatConnection(raw, 'psycopg')
    if psycopg2 is not None:
        raw = psycopg2.connect(DATABASE_URL)
        raw.autocommit = False
        return PostgresCompatConnection(raw, 'psycopg2')
    raise RuntimeError(
        'NIGHTPAY_DB_BACKEND=postgres requires psycopg>=3 or psycopg2-binary in the Python environment'
    )

local = threading.local()
_postgres_pool = queue.Queue(maxsize=DB_POOL_SIZE)
_postgres_pool_lock = threading.Lock()
_postgres_pool_created = 0

def _acquire_postgres_connection():
    global _postgres_pool_created
    try:
        return _postgres_pool.get_nowait()
    except queue.Empty:
        pass

    with _postgres_pool_lock:
        if _postgres_pool_created < DB_POOL_SIZE:
            _postgres_pool_created += 1
            return _new_postgres_connection()

    return _postgres_pool.get()

def _release_postgres_connection(conn):
    try:
        _postgres_pool.put_nowait(conn)
    except queue.Full:
        try:
            conn.close()
        except Exception:
            pass

def get_db():
    if hasattr(local, 'conn'):
        return local.conn

    if DB_BACKEND == 'postgres':
        local.conn = _acquire_postgres_connection()
        return local.conn

    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA synchronous=NORMAL')
    conn.row_factory = sqlite3.Row
    local.conn = conn
    return local.conn

def release_db():
    conn = getattr(local, 'conn', None)
    if conn is None:
        return

    try:
        conn.rollback()
    except Exception:
        pass

    if DB_BACKEND == 'postgres':
        _release_postgres_connection(conn)
    else:
        try:
            conn.close()
        except Exception:
            pass

    try:
        delattr(local, 'conn')
    except Exception:
        pass

def _open_init_connection():
    if DB_BACKEND == 'postgres':
        return _new_postgres_connection()
    conn = sqlite3.connect(DB_PATH)
    conn.execute('PRAGMA journal_mode=WAL')
    return conn

def _initialize_schema():
    conn = _open_init_connection()
    try:
        conn.executescript(SCHEMA_SQL)
        for col_def in MIGRATION_SQL:
            try:
                conn.execute(col_def)
            except Exception:
                pass  # column already exists — idempotent
        conn.commit()
    finally:
        conn.close()

_initialize_schema()

# ─── HTTP handler ─────────────────────────────────────────────────────────────

class MIP003Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'[nightpay] {args[0]}')

    def finish(self):
        try:
            super().finish()
        finally:
            release_db()

    def _get_allowed_origin(self):
        origin = self.headers.get('Origin')
        if not origin:
            return None
            
        try:
            parsed = urlparse(origin)
            hostname = parsed.hostname or ''
            hostname = hostname.lower()
            
            if hostname == 'nightpay.dev' or hostname.endswith('.nightpay.dev') or hostname == 'localhost' or hostname == '127.0.0.1':
                return origin
        except Exception:
            pass
            
        return None

    def respond(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        allowed_origin = self._get_allowed_origin()
        if allowed_origin:
            self.send_header('Access-Control-Allow-Origin', allowed_origin)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        allowed_origin = self._get_allowed_origin()
        if allowed_origin:
            self.send_header('Access-Control-Allow-Origin', allowed_origin)
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Requested-With, X-Agent-Token, X-Idempotency-Key')
        self.end_headers()

    def _proxy_ollama(self, path_only):
        if not (path_only == '/ollama' or path_only.startswith('/ollama/')):
            return False

        # Security check 1: Enforce allowed web origins (prevents UI abuse by other sites)
        origin = self.headers.get('Origin')
        referer = self.headers.get('Referer')
        
        # Require a valid Origin or Referer to block casual cURL/script abuse
        if not origin and not referer:
            self.respond(403, {'error': 'missing origin or referer header'})
            return True
            
        # Strict hostname validation
        if origin and not self._get_allowed_origin():
            self.respond(403, {'error': 'origin not allowed to proxy ollama'})
            return True

        # Security check 2: Restrict which Ollama endpoints can be called
        # This prevents attackers from calling /api/delete or /api/pull to destroy models
        allowed_paths = ['/ollama/api/tags', '/ollama/api/chat', '/ollama/api/generate', '/ollama/api/version']
        if path_only not in allowed_paths:
            self.respond(403, {'error': f'route not permitted for proxying: {path_only}'})
            return True

        target_url = 'https://zgx.procureai.tech' + path_only
        parsed = urlparse(self.path)
        if parsed.query:
            target_url += '?' + parsed.query

        headers = {}
        for key, value in self.headers.items():
            if key.lower() in ('content-type', 'accept', 'user-agent', 'authorization'):
                headers[key] = value

        if MANAGEMENT_LLM_API_KEY:
            headers['Authorization'] = f'Bearer {MANAGEMENT_LLM_API_KEY}'

        data = None
        if self.command in ('POST', 'PUT', 'PATCH'):
            length = int(self.headers.get('Content-Length', 0))
            if length:
                data = self.rfile.read(length)

        req = urlrequest.Request(target_url, data=data, headers=headers, method=self.command)
        try:
            with urlrequest.urlopen(req, timeout=MANAGEMENT_LLM_TIMEOUT_SECONDS) as response:
                response_body = response.read()
                self.send_response(response.status)
                allowed_origin = self._get_allowed_origin()
                if allowed_origin:
                    self.send_header('Access-Control-Allow-Origin', allowed_origin)
                for k, v in response.getheaders():
                    if k.lower() not in ('transfer-encoding', 'content-length', 'connection', 'access-control-allow-origin'):
                        self.send_header(k, v)
                self.send_header('Content-Length', str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
        except Exception as e:
            self.respond(502, {'error': f'upstream proxy error: {str(e)}'})
            
        return True

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 5 * 1024 * 1024:  # 5MB limit
            self.respond(413, {'error': 'Payload too large'})
            return None
        return json.loads(self.rfile.read(length)) if length else {}

    def _validate_job_id(self, job_id):
        # Mirrors validate_job_id in gateway.sh — prevents path traversal
        return bool(re.match(r'^[a-zA-Z0-9_-]{1,128}$', job_id))

    def _job_external_status(self, job):
        return external_status_from_internal(job.get('status'), job.get('amount_specks'))

    def _public_base_url(self):
        proto = str(self.headers.get('X-Forwarded-Proto', 'http')).split(',')[0].strip() or 'http'
        host = str(self.headers.get('X-Forwarded-Host', '')).split(',')[0].strip()
        if not host:
            host = str(self.headers.get('Host', '')).strip()
        if not host:
            host = f'127.0.0.1:{PORT}'
        return f'{proto}://{host}'

    def _cleanup_agent_challenges(self, db, now_iso=None):
        cutoff = now_iso or datetime.now(timezone.utc).isoformat()
        db.execute(
            'DELETE FROM agent_challenges WHERE used_at IS NOT NULL OR expires_at <= ?',
            (cutoff,)
        )

    def _verify_agent_identity_token(self, db, token, expected_agent_id=None):
        parts = str(token or '').strip().split('.')
        if len(parts) != 4 or parts[0] != 'npaid':
            return None, 'invalid X-Agent-Token format'
        _, token_agent_id, issued_raw, sig = parts
        if not validate_actor_id(token_agent_id):
            return None, 'invalid X-Agent-Token agent_id'
        if expected_agent_id and token_agent_id != expected_agent_id:
            return None, 'X-Agent-Token agent_id does not match request agent_id'
        try:
            issued_at = int(issued_raw)
        except Exception:
            return None, 'invalid X-Agent-Token timestamp'

        now_ts = int(datetime.now(timezone.utc).timestamp())
        if issued_at > now_ts + 300 or (now_ts - issued_at) > AGENT_VERIFIED_TOKEN_TTL_SECONDS:
            return None, 'agent token expired'

        row = db.execute(
            'SELECT * FROM agent_identities WHERE agent_id = ? AND revoked_at IS NULL',
            (token_agent_id,)
        ).fetchone()
        if not row:
            return None, 'agent identity is not verified'

        fingerprint_hash = row['fingerprint_hash']
        msg = f'nightpay-agent-auth-v1:{token_agent_id}:{issued_at}:{fingerprint_hash}'
        expected_sig = hmac.new(JOB_TOKEN_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected_sig, sig):
            return None, 'invalid X-Agent-Token signature'

        return dict(row), ''

    def _require_verified_agent(self, db, agent_id):
        if not AGENT_IDENTITY_ENFORCE:
            return None
        token = str(self.headers.get('X-Agent-Token', '')).strip()
        if not token:
            self.respond(401, {'error': 'X-Agent-Token required when AGENT_IDENTITY_ENFORCE=1'})
            return False
        identity, err = self._verify_agent_identity_token(db, token, expected_agent_id=agent_id)
        if err:
            self.respond(403, {'error': err})
            return False
        return identity

    def _enforce_submitter_link(self, db, job_id, agent_id, assigned_agent_id, now_iso):
        # Prevent submitters from hijacking jobs by requiring claim/assignment consistency.
        if assigned_agent_id and assigned_agent_id != agent_id:
            return False, 'agent_id does not match assigned_agent_id for this job'

        claimed = db.execute(
            'SELECT 1 FROM job_claims WHERE job_id = ? AND agent_id = ?',
            (job_id, agent_id)
        ).fetchone()
        if not claimed:
            other_claim = db.execute(
                'SELECT agent_id FROM job_claims WHERE job_id = ? AND agent_id != ? LIMIT 1',
                (job_id, agent_id)
            ).fetchone()
            if other_claim:
                return False, 'agent must claim job before submitting'
            db.execute(
                'INSERT OR IGNORE INTO job_claims(job_id, agent_id, claimed_at) VALUES (?, ?, ?)',
                (job_id, agent_id, now_iso)
            )

        if not assigned_agent_id:
            db.execute(
                'UPDATE jobs SET assigned_agent_id = ?, updated_at = ? WHERE job_id = ?',
                (agent_id, now_iso, job_id)
            )

        return True, ''

    def _status_payload(self, db, job):
        latest = latest_status_event(db, job['job_id'])
        if latest is None:
            seed_status = 'awaiting_input' if job['status'] == 'running' else self._job_external_status(job)
            status_id = record_status_event(db, job['job_id'], seed_status, input_schema={'required': ['input_data']})
            db.commit()
            latest = latest_status_event(db, job['job_id'])

        input_schema = json.loads(latest['input_schema']) if latest['input_schema'] else None
        result = json.loads(latest['result']) if latest['result'] else None
        external_status = self._job_external_status(job)

        if MIP003_MODE == 'strict':
            return {
                'id': latest['status_id'],
                'status_id': latest['status_id'],
                'job_id': job['job_id'],
                'status': latest['status'],
                'input_schema': input_schema,
                'result': result,
                'created_at': latest['created_at']
            }

        # compat mode: keep current rich payload + explicit external/internal statuses
        payload = dict(job)
        payload['internal_status'] = payload['status']
        payload['status'] = external_status
        payload['status_id'] = latest['status_id']
        payload['mip_status'] = latest['status']
        payload['status_created_at'] = latest['created_at']
        if input_schema is not None:
            payload['status_input_schema'] = input_schema
        if result is not None:
            payload['status_result'] = result
        return payload

    def _operator_bearer_ok(self):
        # Admin: raw OPERATOR_SECRET_KEY or time-limited session token (ops.<expiry>.<hmac> from CLI).
        auth = str(self.headers.get('Authorization', '')).strip()
        if not auth.startswith('Bearer '):
            return False
        provided = auth[len('Bearer '):].strip()
        if not provided:
            return False
        if hmac.compare_digest(provided, OPERATOR_SECRET_KEY):
            return True
        return verify_operator_session_token(provided)

    def _nightpay_agent_profile(self, row, db=None):
        if not row:
            return None
        agent = dict(row)
        capabilities = normalize_string_list(safe_json_loads(agent.get('capabilities'), []), max_items=32, max_len=64)
        showcase = normalize_showcase_entries(safe_json_loads(agent.get('showcase'), []), max_items=8)
        credibility = compute_agent_credibility(db, agent.get('agent_id'), capabilities=capabilities) if db else {
            'model': 'nightpay-variety-v1',
            'score': 0.0,
            'variety_index': 0.0,
            'features': {},
            'signals': {}
        }
        return {
            'agent_id': agent.get('agent_id'),
            'name': agent.get('name'),
            'description': agent.get('description') or '',
            'capabilities': capabilities,
            'showcase': showcase,
            'model_provider': agent.get('model_provider') or '',
            'model_name': agent.get('model_name') or '',
            'endpoint_url': agent.get('endpoint_url') or '',
            'metadata': safe_json_loads(agent.get('metadata'), {}),
            'credibility_score': credibility['score'],
            'credibility': credibility,
            'created_at': agent.get('created_at'),
            'updated_at': agent.get('updated_at'),
        }

    def _build_agent_catalog(self, db, params):
        capability_filter = str(params.get('capability', [''])[0]).strip().lower()
        query_filter = str(params.get('q', [''])[0]).strip().lower()
        sort_by = str(params.get('sort', ['credibility'])[0]).strip().lower()
        showcase_only = str(params.get('showcase_only', ['0'])[0]).strip().lower() in ('1', 'true', 'yes', 'on')
        try:
            limit = int(params.get('limit', ['20'])[0])
            offset = int(params.get('offset', ['0'])[0])
        except Exception:
            return None, 'limit and offset must be integers'
        if limit < 1 or limit > 200:
            return None, 'limit must be between 1 and 200'
        if offset < 0:
            return None, 'offset must be >= 0'
        if sort_by not in ('credibility', 'updated_at'):
            return None, 'sort must be one of: credibility, updated_at'

        scan_limit = max((offset + limit) * 3, 120)
        if scan_limit > 600:
            scan_limit = 600
        rows = db.execute(
            'SELECT * FROM agents ORDER BY updated_at DESC LIMIT ?',
            (scan_limit,)
        ).fetchall()
        profiles = []
        for row in rows:
            profile = self._nightpay_agent_profile(row, db=db)
            caps = [str(c).strip().lower() for c in profile.get('capabilities', []) if str(c).strip()]
            if capability_filter:
                if not any(capability_filter in cap for cap in caps):
                    continue
            if query_filter:
                haystack = ' '.join([
                    str(profile.get('name') or '').lower(),
                    str(profile.get('description') or '').lower(),
                    ' '.join(caps),
                ])
                if query_filter not in haystack:
                    continue
            if showcase_only and not profile.get('showcase'):
                continue
            profiles.append(profile)

        if sort_by == 'updated_at':
            profiles.sort(key=lambda p: str(p.get('updated_at') or ''), reverse=True)
        else:
            profiles.sort(
                key=lambda p: (
                    float(p.get('credibility_score') or 0.0),
                    str(p.get('updated_at') or '')
                ),
                reverse=True
            )

        page = profiles[offset:offset + limit]
        return {
            'count': len(page),
            'total': len(profiles),
            'limit': limit,
            'offset': offset,
            'has_more': (offset + limit) < len(profiles),
            'agents': page,
        }, ''

    # ── GET ──────────────────────────────────────────────────────────────────

    def do_GET(self):
        parsed = urlparse(self.path)
        path_only = parsed.path
        params = parse_qs(parsed.query)

        if self._proxy_ollama(path_only):
            return

        if path_only == '/agents':
            db = get_db()
            payload, err = self._build_agent_catalog(db, params)
            if err:
                self.respond(400, {'error': err})
                return
            self.respond(200, payload)

        elif path_only == '/availability':
            db = get_db()
            total = db.execute('SELECT COUNT(*) AS n FROM jobs').fetchone()['n']
            active = db.execute(
                'SELECT COUNT(*) AS n FROM jobs WHERE status = ?',
                ('running',)
            ).fetchone()['n']
            self.respond(200, {
                'status': 'available',
                'total_jobs': total,
                'active_jobs': active,
                'potential_use_cases_count': len(POTENTIAL_USE_CASES),
            })

        elif path_only == '/use_cases':
            self.respond(200, {
                'count': len(POTENTIAL_USE_CASES),
                'items': POTENTIAL_USE_CASES,
            })

        elif path_only == '/management/help':
            self.respond(200, {
                'agent': 'nightpay-ceo',
                'modes': list(MANAGEMENT_CHAT_MODES),
                'description': 'NightPay management assistant for operator onboarding and troubleshooting.',
                'post_route': '/management/chat',
                'backend': {
                    'type': 'ollama',
                    'enabled': MANAGEMENT_LLM_ENABLED,
                    'url': MANAGEMENT_LLM_URL,
                    'model': MANAGEMENT_LLM_MODEL,
                    'timeout_seconds': MANAGEMENT_LLM_TIMEOUT_SECONDS,
                },
                'example': {
                    'message': 'How do I route docs and ceo subdomains with Caddy?',
                    'mode': 'deploy',
                },
            })

        elif path_only == '/ontology':
            base = self._public_base_url()
            payload = copy.deepcopy(ONTOLOGY_SPEC)
            payload['context_url'] = f'{base}/ontology/context'
            payload['examples_url'] = f'{base}/ontology/examples'
            self.respond(200, payload)

        elif path_only == '/ontology/context':
            self.respond(200, copy.deepcopy(ONTOLOGY_CONTEXT))

        elif path_only == '/ontology/examples':
            base = self._public_base_url()
            items = []
            for name in sorted(ONTOLOGY_EXAMPLES.keys()):
                items.append({
                    'id': name,
                    'url': f'{base}/ontology/examples/{name}',
                })
            self.respond(200, {
                'count': len(items),
                'ontology_url': f'{base}/ontology',
                'context_url': f'{base}/ontology/context',
                'items': items,
            })

        elif path_only.startswith('/ontology/examples/'):
            name = path_only[len('/ontology/examples/'):].strip()
            if not name:
                self.respond(400, {'error': 'example id required'})
                return
            doc = ONTOLOGY_EXAMPLES.get(name)
            if doc is None:
                self.respond(404, {'error': 'ontology example not found'})
                return
            self.respond(200, copy.deepcopy(doc))

        elif path_only == '/input_schema':
            self.respond(200, {
                'type': 'object',
                'properties': {
                    'description': {
                        'type': 'string',
                        'description': 'Bounty job description'
                    },
                    'amount_specks': {
                        'type': 'integer',
                        'description': 'Bounty amount in NIGHT specks'
                    },
                    'work_commit': {
                        'type': 'string',
                        'description': 'sha256(nightpay-work-reveal-v1:{work}:{nonce}) — commit before reveal'
                    },
                    'direct_agent_id': {
                        'type': 'string',
                        'description': 'Optional direct assignment to a registered agent profile'
                    },
                    'visibility': {
                        'type': 'string',
                        'description': 'public or private (default: private). Private jobs are hidden from public listings; submissions only for bounty creator.'
                    },
                    'attachment_filename': {
                        'type': 'string',
                        'description': 'Optional .md or .txt filename; requires authentication (X-Agent-Token or operator Bearer). Max 255 chars.'
                    },
                    'attachment_content': {
                        'type': 'string',
                        'description': 'Optional attachment body (markdown or text); requires authentication. Max 256KB.'
                    },
                    'idempotency_key': {
                        'type': 'string',
                        'description': 'Optional replay-safe key; also accepted via X-Idempotency-Key header'
                    },
                    'contest': {
                        'type': 'object',
                        'description': 'Optional contest mode: 5-20 agent submissions with agent-majority voting',
                        'properties': {
                            'enabled': {'type': 'boolean'},
                            'min_agents': {'type': 'integer'},
                            'max_agents': {'type': 'integer'},
                            'min_votes_to_select': {'type': 'integer'},
                            'vote_window_hours': {'type': 'integer'},
                            'agent_voting_only': {'type': 'boolean'}
                        }
                    }
                },
                'required': ['description', 'amount_specks']
            })

        elif path_only == '/demo':
            self.respond(200, {
                'demo': True,
                'message': 'nightpay mip003 demo endpoint',
                'mode': MIP003_MODE,
                'routes': ['/availability', '/use_cases', '/agents', '/ontology', '/ontology/context', '/ontology/examples', '/management/help', '/management/chat', '/input_schema', '/agent/challenge', '/agent/verify', '/start_job', '/status?job_id=...', '/provide_input?job_id=...'],
                'potential_use_cases': POTENTIAL_USE_CASES,
            })

        elif path_only.startswith('/status/') or path_only == '/status':
            job_id = path_only.split('/')[-1] if path_only.startswith('/status/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return
            db = get_db()
            row = db.execute('SELECT * FROM jobs WHERE job_id = ?', (job_id,)).fetchone()
            if not row:
                self.respond(404, {'error': 'job not found'})
            else:
                job = dict(row)
                contest_cfg = parse_contest_config(job.get('contest_config'))
                claims_count = db.execute(
                    'SELECT COUNT(*) AS n FROM job_claims WHERE job_id = ?',
                    (job_id,)
                ).fetchone()['n']
                submissions_count = db.execute(
                    'SELECT COUNT(*) AS n FROM job_submissions WHERE job_id = ?',
                    (job_id,)
                ).fetchone()['n']
                vote_row = db.execute(
                    """SELECT
                            COALESCE(SUM(CASE WHEN vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve_votes,
                            COALESCE(SUM(CASE WHEN vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject_votes
                        FROM job_votes
                        WHERE job_id = ?""",
                    (job_id,)
                ).fetchone()
                if job.get('input_data'):
                    job['input_data'] = json.loads(job['input_data'])
                if job.get('extra_input'):
                    job['extra_input'] = json.loads(job['extra_input'])
                if job.get('result'):
                    job['result'] = json.loads(job['result'])
                voter_snapshot = parse_voter_snapshot(job.get('voter_snapshot'))
                job.pop('contest_config', None)
                job['claims_count'] = claims_count
                job['submissions_count'] = submissions_count
                job['contest'] = contest_cfg
                job['voter_snapshot'] = voter_snapshot
                job['voting'] = {
                    'started_at': job.get('voting_started_at'),
                    'ends_at': job.get('voting_ends_at'),
                    'eligible_voters_count': len(voter_snapshot),
                    'agent_voting_only': bool(contest_cfg.get('agent_voting_only', True)),
                    'vote_window_hours': int(contest_cfg.get('vote_window_hours', 24) or 24),
                }
                job['approve_votes'] = int(vote_row['approve_votes']) if vote_row else 0
                job['reject_votes'] = int(vote_row['reject_votes']) if vote_row else 0
                self.respond(200, self._status_payload(db, job))

        elif path_only.startswith('/vote_result/') or path_only == '/vote_result':
            job_id = path_only.split('/')[-1] if path_only.startswith('/vote_result/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            db = get_db()
            exists = db.execute('SELECT job_id FROM jobs WHERE job_id = ?', (job_id,)).fetchone()
            if not exists:
                self.respond(404, {'error': 'job not found'})
                return

            tally = db.execute(
                """SELECT
                        COALESCE(SUM(CASE WHEN vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve,
                        COALESCE(SUM(CASE WHEN vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject
                    FROM job_votes
                    WHERE job_id = ?""",
                (job_id,)
            ).fetchone()
            votes = db.execute(
                'SELECT voter_id, vote, reason, voted_at FROM job_votes WHERE job_id = ? ORDER BY voted_at DESC LIMIT 200',
                (job_id,)
            ).fetchall()

            self.respond(200, {
                'job_id': job_id,
                'approve': int(tally['approve']) if tally else 0,
                'reject': int(tally['reject']) if tally else 0,
                'total': (int(tally['approve']) + int(tally['reject'])) if tally else 0,
                'votes': [dict(v) for v in votes]
            })

        elif path_only.startswith('/submissions/') or path_only == '/submissions':
            job_id = path_only.split('/')[-1] if path_only.startswith('/submissions/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            # Submissions are only available to the bounty creator (job_token) or operator.
            auth_header = self.headers.get('Authorization', '')
            if not auth_header or not auth_header.startswith('Bearer '):
                self.respond(401, {'error': 'Authorization: Bearer <job_token> required to list submissions (bounty creator only)'})
                return
            provided_token = auth_header[len('Bearer '):].strip()
            token_valid = verify_job_token(job_id, provided_token) if provided_token else False
            if not token_valid and not self._operator_bearer_ok():
                self.respond(403, {'error': 'invalid job_token or not authorized to view this job\'s submissions'})
                return

            db = get_db()
            job = db.execute(
                'SELECT contest_config, voting_started_at, voting_ends_at, voter_snapshot FROM jobs WHERE job_id = ?',
                (job_id,)
            ).fetchone()
            if not job:
                self.respond(404, {'error': 'job not found'})
                return

            contest_cfg = parse_contest_config(job['contest_config'])
            voter_snapshot = parse_voter_snapshot(job['voter_snapshot'])
            rows = db.execute(
                '''SELECT s.submission_id, s.agent_id, s.payload, s.created_at, s.updated_at, s.is_winner, s.selected_at,
                          COALESCE(SUM(CASE WHEN v.vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve_votes,
                          COALESCE(SUM(CASE WHEN v.vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject_votes
                   FROM job_submissions s
                   LEFT JOIN submission_votes v
                     ON v.job_id = s.job_id AND v.submission_id = s.submission_id
                   WHERE s.job_id = ?
                   GROUP BY s.submission_id, s.agent_id, s.payload, s.created_at, s.updated_at, s.is_winner, s.selected_at
                   ORDER BY (approve_votes - reject_votes) DESC, approve_votes DESC, s.updated_at ASC''',
                (job_id,)
            ).fetchall()

            submissions = []
            for row in rows:
                payload = {}
                try:
                    payload = json.loads(row['payload'])
                except Exception:
                    payload = {}
                approve_votes = int(row['approve_votes'])
                reject_votes = int(row['reject_votes'])
                submissions.append({
                    'submission_id': row['submission_id'],
                    'agent_id': row['agent_id'],
                    'payload': payload,
                    'created_at': row['created_at'],
                    'updated_at': row['updated_at'],
                    'is_winner': bool(row['is_winner']),
                    'selected_at': row['selected_at'],
                    'approve_votes': approve_votes,
                    'reject_votes': reject_votes,
                    'score': approve_votes - reject_votes
                })

            self.respond(200, {
                'job_id': job_id,
                'contest': contest_cfg,
                'voting': {
                    'started_at': job['voting_started_at'],
                    'ends_at': job['voting_ends_at'],
                    'eligible_voters_count': len(voter_snapshot),
                    'agent_voting_only': bool(contest_cfg.get('agent_voting_only', True)),
                    'vote_window_hours': int(contest_cfg.get('vote_window_hours', 24) or 24),
                },
                'voter_snapshot': voter_snapshot,
                'submissions': submissions,
                'count': len(submissions)
            })

        elif path_only == '/jobs':
            # GET /jobs?status=<value>&limit=<n>&offset=<n>&approved_before=<iso8601>&search=<text>&visibility=<all|public|hidden>
            # used by optimistic-sweep, dashboards, and board search.
            status_filter = params.get('status', [None])[0]
            approved_before = params.get('approved_before', [None])[0]
            search_term = params.get('search', [None])[0]
            visibility_filter = str(params.get('visibility', ['public'])[0]).strip().lower() or 'public'
            if visibility_filter == 'private':
                visibility_filter = 'hidden'

            # SECURITY: clamp pagination to bounded values
            try:
                limit = int(params.get('limit', ['100'])[0])
                offset = int(params.get('offset', ['0'])[0])
            except ValueError:
                self.respond(400, {'error': 'limit and offset must be integers'})
                return
            if limit < 1 or limit > 500:
                self.respond(400, {'error': 'limit must be between 1 and 500'})
                return
            if offset < 0 or offset > 1000000:
                self.respond(400, {'error': 'offset must be between 0 and 1000000'})
                return
            if visibility_filter not in ('all', 'public', 'hidden'):
                self.respond(400, {'error': 'visibility must be one of: all, public, private (or hidden)'})
                return
            # Hidden jobs can contain private direct-hire details; only operator-authenticated
            # callers may query hidden/all visibility through this public route.
            if visibility_filter == 'all':
                if not self._operator_bearer_ok():
                    visibility_filter = 'public'
            elif visibility_filter == 'hidden':
                if not self._operator_bearer_ok():
                    self.respond(403, {'error': 'visibility=hidden requires operator bearer auth'})
                    return

            # SECURITY: whitelist status values - prevents SQL injection via status param
            status_filter_internal = status_filter
            if status_filter:
                if MIP003_MODE == 'strict':
                    if status_filter not in MIP003_STATUSES:
                        self.respond(400, {'error': f'unknown status filter: {status_filter}'})
                        return
                    if status_filter in ('running', 'awaiting_input', 'awaiting_payment'):
                        status_filter_internal = None
                    elif status_filter == 'failed':
                        status_filter_internal = 'disputed'
                    elif status_filter == 'completed':
                        status_filter_internal = 'completed'
                elif status_filter not in KNOWN_STATUSES:
                    self.respond(400, {'error': f'unknown status filter: {status_filter}'})
                    return

            if approved_before:
                try:
                    datetime.fromisoformat(approved_before.replace('Z', '+00:00'))
                except ValueError:
                    self.respond(400, {'error': 'approved_before must be ISO-8601'})
                    return

            if search_term is not None:
                search_term = str(search_term).strip()
                if len(search_term) > 200:
                    self.respond(400, {'error': 'search must be 200 chars or fewer'})
                    return
                if any(ord(ch) < 32 for ch in search_term):
                    self.respond(400, {'error': 'search must not contain control characters'})
                    return
                if search_term == '':
                    search_term = None

            db = get_db()
            where_clauses = []
            query_params = []

            if status_filter_internal:
                where_clauses.append('j.status = ?')
                query_params.append(status_filter_internal)
            if approved_before:
                where_clauses.append('j.approved_at IS NOT NULL AND j.approved_at <= ?')
                query_params.append(approved_before)
            if search_term:
                # Escape wildcard chars so search is treated as literal text.
                esc = search_term.lower().replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
                like = f'%{esc}%'
                where_clauses.append(
                    "(LOWER(COALESCE(j.input_data, '')) LIKE ? ESCAPE '\\' OR LOWER(j.job_id) LIKE ? ESCAPE '\\')"
                )
                query_params.extend([like, like])
            if visibility_filter in ('public', 'hidden'):
                where_clauses.append("COALESCE(j.visibility, 'public') = ?")
                query_params.append(visibility_filter)

            sql = (
                'SELECT j.job_id, j.status, j.started_at, j.approved_at, j.amount_specks, j.input_data, j.assigned_agent_id, j.visibility, '
                'COALESCE(c.claims_count, 0) AS claims_count, '
                'COALESCE(v.approve_votes, 0) AS approve_votes, '
                'COALESCE(v.reject_votes, 0) AS reject_votes '
                'FROM jobs j '
                'LEFT JOIN (SELECT job_id, COUNT(*) AS claims_count FROM job_claims GROUP BY job_id) c ON c.job_id = j.job_id '
                'LEFT JOIN (SELECT job_id, '
                "SUM(CASE WHEN vote = 'approve' THEN 1 ELSE 0 END) AS approve_votes, "
                "SUM(CASE WHEN vote = 'reject' THEN 1 ELSE 0 END) AS reject_votes "
                'FROM job_votes GROUP BY job_id) v ON v.job_id = j.job_id '
            )
            if where_clauses:
                sql += 'WHERE ' + ' AND '.join(where_clauses) + ' '
            if approved_before:
                sql += 'ORDER BY j.approved_at ASC, j.job_id ASC '
            else:
                sql += 'ORDER BY j.updated_at DESC, j.job_id ASC '
            sql += 'LIMIT ? OFFSET ?'

            query_params.extend([limit, offset])
            rows = db.execute(sql, tuple(query_params)).fetchall()

            jobs = []
            for r in rows:
                j = dict(r)
                if j.get('input_data'):
                    try:
                        j['input_data'] = json.loads(j['input_data'])
                    except Exception:
                        pass
                internal_status = j.get('status')
                j['status'] = external_status_from_internal(internal_status, j.get('amount_specks'))
                j['internal_status'] = internal_status
                j['visibility'] = visibility_for_api(normalize_visibility(j.get('visibility'), default='public') or 'public')
                jobs.append(j)

            if MIP003_MODE == 'strict' and status_filter and status_filter_internal is None:
                jobs = [j for j in jobs if j.get('status') == status_filter]

            self.respond(200, {
                'jobs': jobs,
                'limit': limit,
                'offset': offset,
                'count': len(jobs),
                'has_more': len(jobs) == limit
            })

        else:
            self.respond(404, {'error': 'not found'})


    # ── POST ─────────────────────────────────────────────────────────────────

    def do_POST(self):
        parsed = urlparse(self.path)
        path_only = parsed.path

        if self._proxy_ollama(path_only):
            return

        body = self._read_body()
        if body is None:
            return

        if path_only == '/management/chat':
            if not isinstance(body, dict):
                self.respond(400, {'error': 'JSON object body required'})
                return
            message = str(body.get('message', '')).strip()
            if not message:
                self.respond(400, {'error': 'message is required'})
                return
            if len(message) > 4000:
                message = message[:4000]
            mode = str(body.get('mode', 'general')).strip().lower()
            history = body.get('history', [])
            payload = build_management_chat_response(
                message=message,
                mode=mode,
                base_url=self._public_base_url(),
                history=history,
            )
            self.respond(200, payload)
            return

        if path_only == '/agent/challenge':
            if not isinstance(body, dict):
                self.respond(400, {'error': 'JSON object body required'})
                return

            agent_id = str(body.get('agent_id', '')).strip()
            if not validate_actor_id(agent_id):
                self.respond(400, {'error': 'agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                return

            algorithm = str(body.get('algorithm', 'ed25519')).strip().lower()
            if algorithm != 'ed25519':
                self.respond(400, {'error': 'algorithm must be ed25519'})
                return
            if Ed25519PublicKey is None:
                self.respond(503, {'error': 'ed25519 verification unavailable (install python cryptography package)'})
                return

            chain = str(body.get('chain', 'cardano')).strip().lower()[:32] or 'cardano'
            wallet_address = str(body.get('wallet_address', '')).strip()[:256]
            midnight_address = str(body.get('midnight_address', '')).strip()[:128]
            masumi_agent_id = str(body.get('masumi_agent_id', '')).strip()[:128]
            challenge_id = str(uuid.uuid4())
            nonce = secrets.token_hex(32)
            now_dt = datetime.now(timezone.utc)
            now_iso = now_dt.isoformat()
            expires_iso = (now_dt + timedelta(seconds=AGENT_CHALLENGE_TTL_SECONDS)).isoformat()
            challenge_message = make_agent_challenge_message(
                challenge_id=challenge_id,
                agent_id=agent_id,
                nonce=nonce,
                issued_at=now_iso,
                expires_at=expires_iso,
                domain=self._public_base_url(),
                algorithm=algorithm,
                chain=chain,
            )

            db = get_db()
            self._cleanup_agent_challenges(db, now_iso)
            db.execute(
                '''INSERT INTO agent_challenges(
                       challenge_id, agent_id, algorithm, chain, wallet_address, midnight_address, masumi_agent_id,
                       challenge_message, nonce, created_at, expires_at, used_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)''',
                (
                    challenge_id,
                    agent_id,
                    algorithm,
                    chain,
                    wallet_address,
                    midnight_address,
                    masumi_agent_id,
                    challenge_message,
                    nonce,
                    now_iso,
                    expires_iso,
                )
            )
            db.commit()
            self.respond(200, {
                'agent_id': agent_id,
                'challenge_id': challenge_id,
                'algorithm': algorithm,
                'chain': chain,
                'challenge': challenge_message,
                'issued_at': now_iso,
                'expires_at': expires_iso,
                'ttl_seconds': AGENT_CHALLENGE_TTL_SECONDS,
                'signing_hint': 'sign UTF-8 bytes of `challenge` exactly as returned',
            })
            return

        if path_only == '/agent/verify':
            if not isinstance(body, dict):
                self.respond(400, {'error': 'JSON object body required'})
                return

            challenge_id = str(body.get('challenge_id', '')).strip()
            agent_id = str(body.get('agent_id', '')).strip()
            algorithm = str(body.get('algorithm', 'ed25519')).strip().lower()
            public_key_hex = str(body.get('public_key_hex', '')).strip().lower()
            signature_hex = str(body.get('signature_hex', '')).strip().lower()

            if not re.match(r'^[a-f0-9-]{8,64}$', challenge_id):
                self.respond(400, {'error': 'challenge_id must be uuid-like lowercase hex plus dashes'})
                return
            if not validate_actor_id(agent_id):
                self.respond(400, {'error': 'agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                return
            if not public_key_hex or not signature_hex:
                self.respond(400, {'error': 'public_key_hex and signature_hex are required'})
                return

            db = get_db()
            now_iso = datetime.now(timezone.utc).isoformat()
            challenge_row = db.execute(
                'SELECT * FROM agent_challenges WHERE challenge_id = ?',
                (challenge_id,)
            ).fetchone()
            if not challenge_row:
                self.respond(404, {'error': 'challenge not found'})
                return
            if challenge_row['used_at'] is not None:
                self.respond(409, {'error': 'challenge already used'})
                return
            if challenge_row['expires_at'] <= now_iso:
                self.respond(410, {'error': 'challenge expired'})
                return
            if challenge_row['agent_id'] != agent_id:
                self.respond(409, {'error': 'challenge agent_id mismatch'})
                return
            if challenge_row['algorithm'] != algorithm:
                self.respond(409, {'error': 'algorithm must match challenge algorithm'})
                return

            verified, err, pub_bytes = verify_agent_signature(
                algorithm=algorithm,
                public_key_hex=public_key_hex,
                signature_hex=signature_hex,
                message=challenge_row['challenge_message']
            )
            if not verified:
                self.respond(403, {'error': err})
                return

            chain = str(body.get('chain') or challenge_row['chain'] or 'cardano').strip().lower()[:32] or 'cardano'
            wallet_address = str(body.get('wallet_address') or challenge_row['wallet_address'] or '').strip()[:256]
            midnight_address = str(body.get('midnight_address') or challenge_row['midnight_address'] or '').strip()[:128]
            masumi_agent_id = str(body.get('masumi_agent_id') or challenge_row['masumi_agent_id'] or '').strip()[:128]
            cardano_stake_addr = str(body.get('cardano_stake_address') or '').strip()[:256]
            metadata = body.get('metadata') if isinstance(body.get('metadata'), dict) else {}
            public_key_hash = hashlib.sha256(pub_bytes).hexdigest()
            fingerprint_hash = make_agent_fingerprint(
                agent_id=agent_id,
                chain=chain,
                wallet_address=wallet_address,
                midnight_address=midnight_address,
                masumi_agent_id=masumi_agent_id,
                public_key_hash=public_key_hash,
            )

            existing = db.execute(
                'SELECT created_at FROM agent_identities WHERE agent_id = ?',
                (agent_id,)
            ).fetchone()
            created_at = existing['created_at'] if existing else now_iso
            db.execute(
                '''INSERT INTO agent_identities(
                       agent_id, algorithm, chain, public_key_hex, public_key_hash, wallet_address, midnight_address,
                       masumi_agent_id, cardano_stake_addr, fingerprint_hash, challenge_id, metadata,
                       verified_at, revoked_at, created_at, updated_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                   ON CONFLICT(agent_id) DO UPDATE SET
                       algorithm = excluded.algorithm,
                       chain = excluded.chain,
                       public_key_hex = excluded.public_key_hex,
                       public_key_hash = excluded.public_key_hash,
                       wallet_address = excluded.wallet_address,
                       midnight_address = excluded.midnight_address,
                       masumi_agent_id = excluded.masumi_agent_id,
                       cardano_stake_addr = excluded.cardano_stake_addr,
                       fingerprint_hash = excluded.fingerprint_hash,
                       challenge_id = excluded.challenge_id,
                       metadata = excluded.metadata,
                       verified_at = excluded.verified_at,
                       revoked_at = NULL,
                       updated_at = excluded.updated_at''',
                (
                    agent_id,
                    algorithm,
                    chain,
                    public_key_hex,
                    public_key_hash,
                    wallet_address,
                    midnight_address,
                    masumi_agent_id,
                    cardano_stake_addr,
                    fingerprint_hash,
                    challenge_id,
                    json.dumps(metadata),
                    now_iso,
                    created_at,
                    now_iso,
                )
            )
            db.execute(
                'UPDATE agent_challenges SET used_at = ? WHERE challenge_id = ?',
                (now_iso, challenge_id)
            )
            self._cleanup_agent_challenges(db, now_iso)
            db.commit()

            agent_token = make_verified_agent_token(agent_id, fingerprint_hash)
            self.respond(200, {
                'verified': True,
                'agent_id': agent_id,
                'algorithm': algorithm,
                'chain': chain,
                'wallet_address': wallet_address,
                'midnight_address': midnight_address,
                'masumi_agent_id': masumi_agent_id,
                'cardano_stake_address': cardano_stake_addr,
                'public_key_hash': public_key_hash,
                'fingerprint_hash': fingerprint_hash,
                'agent_token': agent_token,
                'token_type': 'Bearer',
                'expires_in': AGENT_VERIFIED_TOKEN_TTL_SECONDS,
                'enforced': AGENT_IDENTITY_ENFORCE,
            })
            return

        if path_only == '/start_job':
            if not isinstance(body, dict):
                self.respond(400, {'error': 'JSON object body required'})
                return
            contest_cfg, contest_err = validate_contest_config(body.get('contest'))
            if contest_err:
                self.respond(400, {'error': contest_err})
                return
            input_data = body.get('input_data') if isinstance(body.get('input_data'), dict) else {}
            direct_agent_id = str(body.get('direct_agent_id') or '').strip()
            visibility_default = 'hidden' if direct_agent_id else 'private'
            visibility = normalize_visibility(body.get('visibility'), default=visibility_default)
            if visibility is None:
                self.respond(400, {'error': 'visibility must be public or private'})
                return
            if direct_agent_id and not validate_actor_id(direct_agent_id):
                self.respond(400, {'error': 'direct_agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                return
            if direct_agent_id and contest_cfg and contest_cfg.get('enabled'):
                self.respond(400, {'error': 'direct_agent_id cannot be used when contest mode is enabled'})
                return
            contest_json = json.dumps(contest_cfg) if contest_cfg else None

            # Validate optional work_commit
            work_commit = body.get('work_commit')
            if work_commit is not None:
                if not re.match(r'^[0-9a-f]{64}$', str(work_commit)):
                    self.respond(400, {'error': 'work_commit must be 64-char lowercase hex sha256'})
                    return

            # Validate optional amount_specks
            amount_specks = body.get('amount_specks')
            if amount_specks is not None:
                try:
                    amount_specks = int(amount_specks)
                    if amount_specks < 0:
                        raise ValueError
                except (ValueError, TypeError):
                    self.respond(400, {'error': 'amount_specks must be a non-negative integer'})
                    return

            # Optional attachment (.md or .txt) — only for authenticated callers (operator or X-Agent-Token).
            attachment_filename = str(body.get('attachment_filename') or '').strip()
            attachment_content = body.get('attachment_content')
            if attachment_content is not None and not isinstance(attachment_content, str):
                attachment_content = None
            if attachment_filename or (attachment_content is not None and attachment_content != ''):
                db_auth = get_db()
                agent_token = str(self.headers.get('X-Agent-Token', '')).strip()
                identity, _ = self._verify_agent_identity_token(db_auth, agent_token, None) if agent_token else (None, 'missing')
                if not self._operator_bearer_ok() and not identity:
                    self.respond(403, {'error': 'attachment requires authentication (Authorization: Bearer <operator_secret> or valid X-Agent-Token)'})
                    return
                if attachment_filename:
                    if not attachment_filename.lower().endswith(('.md', '.txt')):
                        self.respond(400, {'error': 'attachment_filename must end with .md or .txt'})
                        return
                    if len(attachment_filename) > 255:
                        self.respond(400, {'error': 'attachment_filename too long'})
                        return
                if attachment_content is not None and len(attachment_content.encode('utf-8', errors='replace')) > MAX_ATTACHMENT_BYTES:
                    self.respond(400, {'error': f'attachment_content must be at most {MAX_ATTACHMENT_BYTES} bytes'})
                    return
            else:
                attachment_filename = None
                attachment_content = None

            # Optional idempotency key: header and body must match if both provided.
            idem_header = self.headers.get('X-Idempotency-Key', '').strip()
            idem_body_raw = body.get('idempotency_key')
            idem_body = str(idem_body_raw).strip() if idem_body_raw is not None else ''
            if idem_header and idem_body and idem_header != idem_body:
                self.respond(400, {'error': 'idempotency_key body value does not match X-Idempotency-Key header'})
                return

            idempotency_key = idem_header or idem_body or None
            request_hash = None
            if idempotency_key is not None:
                if not re.match(r'^[A-Za-z0-9._:-]{8,128}$', idempotency_key):
                    self.respond(400, {'error': 'idempotency key must match [A-Za-z0-9._:-] and be 8-128 chars'})
                    return
                request_hash = hash_start_job_request(body)

            now_dt = datetime.now(timezone.utc)
            now = now_dt.isoformat()
            db = get_db()
            if direct_agent_id:
                target = db.execute('SELECT 1 FROM agents WHERE agent_id = ?', (direct_agent_id,)).fetchone()
                if not target:
                    self.respond(404, {'error': 'direct_agent_id not found'})
                    return

            input_payload = dict(input_data)
            input_payload['visibility'] = visibility
            if direct_agent_id:
                input_payload['direct_agent_id'] = direct_agent_id
            if attachment_filename:
                input_payload['attachment_filename'] = attachment_filename
            if attachment_content is not None:
                input_payload['attachment_content'] = attachment_content

            if idempotency_key:
                # BEGIN IMMEDIATE serializes writers and prevents duplicate inserts for same key.
                db.execute('BEGIN IMMEDIATE')
                try:
                    if IDEMPOTENCY_TTL_SECONDS > 0:
                        cutoff = (now_dt - timedelta(seconds=IDEMPOTENCY_TTL_SECONDS)).isoformat()
                        db.execute('DELETE FROM idempotency_keys WHERE created_at < ?', (cutoff,))

                    existing = db.execute(
                        'SELECT request_hash, job_id FROM idempotency_keys WHERE idem_key = ?',
                        (idempotency_key,)
                    ).fetchone()

                    if existing:
                        if not hmac.compare_digest(existing['request_hash'], request_hash):
                            db.rollback()
                            self.respond(409, {'error': 'idempotency key already used with different payload'})
                            return

                        job_id = existing['job_id']
                        row = db.execute(
                            'SELECT status, amount_specks, assigned_agent_id, visibility FROM jobs WHERE job_id = ?',
                            (job_id,)
                        ).fetchone()
                        db.rollback()

                        if not row:
                            self.respond(500, {'error': 'idempotency mapping references missing job'})
                            return

                        if MIP003_MODE == 'strict':
                            strict_payload = strict_start_job_response(job_id, body, now_dt, row['amount_specks'])
                            strict_payload['idempotent_replay'] = True
                            strict_payload['visibility'] = visibility_for_api(normalize_visibility(row['visibility'], default='public') or 'public')
                            strict_payload['assigned_agent_id'] = row['assigned_agent_id']
                            self.respond(200, strict_payload)
                        else:
                            self.respond(200, {
                                'job_id': job_id,
                                'job_token': make_job_token(job_id),
                                'status': external_status_from_internal(row['status'], row['amount_specks']),
                                'internal_status': row['status'],
                                'assigned_agent_id': row['assigned_agent_id'],
                                'visibility': visibility_for_api(normalize_visibility(row['visibility'], default='public') or 'public'),
                                'idempotent_replay': True
                            })
                        return

                    job_id = str(uuid.uuid4())
                    db.execute(
                        '''INSERT INTO jobs(job_id, status, assigned_agent_id, visibility, input_data, work_commit, amount_specks, contest_config, started_at, updated_at)
                           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
                        (job_id, 'running', direct_agent_id or None, visibility, json.dumps(input_payload),
                         work_commit, amount_specks, contest_json, now, now)
                    )
                    if direct_agent_id:
                        db.execute(
                            'INSERT OR IGNORE INTO job_claims(job_id, agent_id, claimed_at) VALUES (?, ?, ?)',
                            (job_id, direct_agent_id, now)
                        )
                    record_status_event(
                        db,
                        job_id,
                        'awaiting_input',
                        input_schema={'required': ['input_data'], 'job_id': job_id}
                    )
                    db.execute(
                        '''INSERT INTO idempotency_keys(idem_key, request_hash, job_id, created_at)
                           VALUES (?, ?, ?, ?)''',
                        (idempotency_key, request_hash, job_id, now)
                    )
                    db.commit()
                except Exception:
                    db.rollback()
                    raise
            else:
                job_id = str(uuid.uuid4())
                db.execute(
                    '''INSERT INTO jobs(job_id, status, assigned_agent_id, visibility, input_data, work_commit, amount_specks, contest_config, started_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
                    (job_id, 'running', direct_agent_id or None, visibility, json.dumps(input_payload),
                     work_commit, amount_specks, contest_json, now, now)
                )
                if direct_agent_id:
                    db.execute(
                        'INSERT OR IGNORE INTO job_claims(job_id, agent_id, claimed_at) VALUES (?, ?, ?)',
                        (job_id, direct_agent_id, now)
                    )
                record_status_event(
                    db,
                    job_id,
                    'awaiting_input',
                    input_schema={'required': ['input_data'], 'job_id': job_id}
                )
                db.commit()

            # SECURITY: job_token is ephemeral - derived on demand, never stored
            if MIP003_MODE == 'strict':
                response = strict_start_job_response(job_id, body, now_dt, amount_specks)
                response['visibility'] = visibility_for_api(visibility)
                response['assigned_agent_id'] = direct_agent_id or None
            else:
                response = {
                    'job_id':    job_id,
                    'job_token': make_job_token(job_id),
                    'status':    external_status_from_internal('running', amount_specks),
                    'internal_status': 'running',
                    'assigned_agent_id': direct_agent_id or None,
                    'visibility': visibility_for_api(visibility),
                }
                if contest_cfg:
                    response['contest'] = contest_cfg
            if idempotency_key:
                response['idempotency_key'] = idempotency_key
            self.respond(200, response)

        elif path_only.startswith('/claim_job/') or path_only == '/claim_job':
            job_id = path_only.split('/')[-1] if path_only.startswith('/claim_job/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            agent_id = str(body.get('agent_id', '')).strip()
            if not validate_actor_id(agent_id):
                self.respond(400, {'error': 'agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                return

            exclusive = bool(body.get('exclusive', False))
            assign = bool(body.get('assign', False))

            db = get_db()
            verified_identity = self._require_verified_agent(db, agent_id)
            if AGENT_IDENTITY_ENFORCE and verified_identity is False:
                return
            now = datetime.now(timezone.utc).isoformat()
            row = db.execute(
                'SELECT status, assigned_agent_id, contest_config, amount_specks, visibility FROM jobs WHERE job_id = ?',
                (job_id,)
            ).fetchone()
            if not row:
                self.respond(404, {'error': 'job not found'})
                return
            job_visibility = visibility_for_api(normalize_visibility(row['visibility'], default='public') or 'public')
            if normalize_visibility(row['visibility'], default='public') == 'hidden' and row['assigned_agent_id'] and row['assigned_agent_id'] != agent_id:
                self.respond(403, {'error': 'private job is reserved for another agent'})
                return
            if row['status'] not in ('running', 'awaiting_approval', 'multisig_pending'):
                self.respond(409, {'error': f'job cannot be claimed in current state (status: {row["status"]})'})
                return

            contest_cfg = parse_contest_config(row['contest_config'])
            claims_count_before = db.execute(
                'SELECT COUNT(*) AS n FROM job_claims WHERE job_id = ?',
                (job_id,)
            ).fetchone()['n']

            if exclusive:
                existing_other = db.execute(
                    'SELECT agent_id FROM job_claims WHERE job_id = ? AND agent_id != ? LIMIT 1',
                    (job_id, agent_id)
                ).fetchone()
                if existing_other:
                    self.respond(409, {'error': 'job already claimed by another agent in exclusive mode'})
                    return
            elif contest_cfg['enabled'] and claims_count_before >= contest_cfg['max_agents']:
                already_claimed = db.execute(
                    'SELECT 1 FROM job_claims WHERE job_id = ? AND agent_id = ?',
                    (job_id, agent_id)
                ).fetchone()
                if not already_claimed:
                    self.respond(409, {'error': f'contest already has max_agents={contest_cfg["max_agents"]} claims'})
                    return

            db.execute(
                'INSERT OR IGNORE INTO job_claims(job_id, agent_id, claimed_at) VALUES (?, ?, ?)',
                (job_id, agent_id, now)
            )

            assigned_agent_id = row['assigned_agent_id']
            if assign or exclusive or not assigned_agent_id:
                db.execute(
                    'UPDATE jobs SET assigned_agent_id = ?, updated_at = ? WHERE job_id = ?',
                    (agent_id, now, job_id)
                )
                assigned_agent_id = agent_id

            claims_count = db.execute(
                'SELECT COUNT(*) AS n FROM job_claims WHERE job_id = ?',
                (job_id,)
            ).fetchone()['n']
            db.commit()
            ext_status = external_status_from_internal(row['status'], row['amount_specks'])

            self.respond(200, {
                'job_id': job_id,
                'status': ext_status,
                'internal_status': row['status'],
                'agent_id': agent_id,
                'agent_verified': bool(verified_identity) if AGENT_IDENTITY_ENFORCE else False,
                'claimed': True,
                'mode': 'exclusive' if exclusive else 'shared',
                'assigned_agent_id': assigned_agent_id,
                'claims_count': claims_count,
                'contest': contest_cfg
            })

        elif path_only.startswith('/vote_result/') or path_only == '/vote_result':
            job_id = path_only.split('/')[-1] if path_only.startswith('/vote_result/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            voter_id = str(body.get('voter_id', '')).strip()
            vote = str(body.get('vote', '')).strip().lower()
            reason = str(body.get('reason', '')).strip()[:500] or None

            if not validate_actor_id(voter_id):
                self.respond(400, {'error': 'voter_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                return
            if vote not in ('approve', 'reject'):
                self.respond(400, {'error': 'vote must be approve or reject'})
                return

            db = get_db()
            exists = db.execute('SELECT job_id FROM jobs WHERE job_id = ?', (job_id,)).fetchone()
            if not exists:
                self.respond(404, {'error': 'job not found'})
                return

            now = datetime.now(timezone.utc).isoformat()
            db.execute(
                '''INSERT INTO job_votes(job_id, voter_id, vote, reason, voted_at)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(job_id, voter_id) DO UPDATE SET
                     vote = excluded.vote,
                     reason = excluded.reason,
                     voted_at = excluded.voted_at''',
                (job_id, voter_id, vote, reason, now)
            )
            tally = db.execute(
                """SELECT
                        COALESCE(SUM(CASE WHEN vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve,
                        COALESCE(SUM(CASE WHEN vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject
                    FROM job_votes
                    WHERE job_id = ?""",
                (job_id,)
            ).fetchone()
            db.commit()

            approve = int(tally['approve']) if tally else 0
            reject = int(tally['reject']) if tally else 0
            self.respond(200, {
                'job_id': job_id,
                'voter_id': voter_id,
                'vote': vote,
                'approve': approve,
                'reject': reject,
                'total': approve + reject
            })

        elif path_only.startswith('/vote_submission/'):
            parts = path_only.split('/')
            if len(parts) != 4:
                self.respond(400, {'error': 'path must be /vote_submission/<job_id>/<submission_id>'})
                return
            _, _, job_id, submission_id = parts

            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return
            if not re.match(r'^[a-f0-9-]{8,64}$', submission_id):
                self.respond(400, {'error': 'invalid submission_id format'})
                return

            voter_id = str(body.get('voter_id', '')).strip()
            vote = str(body.get('vote', '')).strip().lower()
            reason = str(body.get('reason', '')).strip()[:500] or None
            if not validate_actor_id(voter_id):
                self.respond(400, {'error': 'voter_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                return
            if vote not in ('approve', 'reject'):
                self.respond(400, {'error': 'vote must be approve or reject'})
                return

            db = get_db()
            job = db.execute(
                'SELECT contest_config, status, voting_started_at, voting_ends_at, voter_snapshot FROM jobs WHERE job_id = ?',
                (job_id,)
            ).fetchone()
            if not job:
                self.respond(404, {'error': 'job not found'})
                return
            if job['status'] != 'running':
                self.respond(409, {'error': f'job is not running (status: {job["status"]})'})
                return
            contest_cfg = parse_contest_config(job['contest_config'])
            if not contest_cfg['enabled']:
                self.respond(409, {'error': 'submission voting requires contest mode'})
                return

            now_dt = datetime.now(timezone.utc)
            voting_started_at, voting_ends_at, voter_snapshot, voting_err = ensure_voting_session(
                db,
                job_id,
                contest_cfg,
                now_dt
            )
            if voting_err:
                self.respond(409, {'error': voting_err})
                return
            voting_ends_dt = parse_iso8601(voting_ends_at)
            if voting_ends_dt and now_dt > voting_ends_dt:
                self.respond(409, {'error': 'vote window has closed', 'voting_ends_at': voting_ends_at})
                return
            if bool(contest_cfg.get('agent_voting_only', True)) and voter_id not in set(voter_snapshot):
                self.respond(403, {'error': 'voter_id is not eligible for this bounty vote'})
                return

            sub = db.execute(
                'SELECT agent_id FROM job_submissions WHERE job_id = ? AND submission_id = ?',
                (job_id, submission_id)
            ).fetchone()
            if not sub:
                self.respond(404, {'error': 'submission not found'})
                return
            if sub['agent_id'] == voter_id:
                self.respond(409, {'error': 'self-voting is not allowed'})
                return

            now = now_dt.isoformat()
            db.execute(
                '''INSERT INTO submission_votes(job_id, submission_id, voter_id, vote, reason, voted_at)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(job_id, submission_id, voter_id) DO UPDATE SET
                     vote = excluded.vote,
                     reason = excluded.reason,
                     voted_at = excluded.voted_at''',
                (job_id, submission_id, voter_id, vote, reason, now)
            )
            tally = db.execute(
                '''SELECT
                       COALESCE(SUM(CASE WHEN vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve,
                       COALESCE(SUM(CASE WHEN vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject
                   FROM submission_votes
                   WHERE job_id = ? AND submission_id = ?''',
                (job_id, submission_id)
            ).fetchone()
            db.commit()

            approve = int(tally['approve']) if tally else 0
            reject = int(tally['reject']) if tally else 0
            self.respond(200, {
                'job_id': job_id,
                'submission_id': submission_id,
                'voter_id': voter_id,
                'vote': vote,
                'approve': approve,
                'reject': reject,
                'total': approve + reject,
                'voting': {
                    'started_at': voting_started_at,
                    'ends_at': voting_ends_at,
                    'eligible_voters_count': len(voter_snapshot),
                    'agent_voting_only': bool(contest_cfg.get('agent_voting_only', True)),
                    'vote_window_hours': int(contest_cfg.get('vote_window_hours', 24) or 24),
                }
            })

        elif path_only.startswith('/select_winner/') or path_only == '/select_winner':
            job_id = path_only.split('/')[-1] if path_only.startswith('/select_winner/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            auth_header = self.headers.get('Authorization', '')
            if not auth_header.startswith('Bearer '):
                self.respond(401, {'error': 'Authorization: Bearer <job_token> or operator secret required'})
                return
            provided_token = auth_header[len('Bearer '):].strip()
            if not verify_job_token(job_id, provided_token) and not self._operator_bearer_ok():
                self.respond(403, {'error': 'invalid job_token or not authorized (operator)'})
                return

            selected_submission_id = str(body.get('submission_id', '')).strip() or None

            db = get_db()
            row = db.execute(
                'SELECT contest_config, amount_specks, status, voting_started_at, voting_ends_at, voter_snapshot FROM jobs WHERE job_id = ?',
                (job_id,)
            ).fetchone()
            if not row:
                self.respond(404, {'error': 'job not found'})
                return
            if row['status'] != 'running':
                self.respond(409, {'error': f'job is not running (status: {row["status"]})'})
                return

            contest_cfg = parse_contest_config(row['contest_config'])
            if not contest_cfg['enabled']:
                self.respond(409, {'error': 'winner selection requires contest mode'})
                return

            now_dt = datetime.now(timezone.utc)
            voting_started_at, voting_ends_at, voter_snapshot, voting_err = ensure_voting_session(
                db,
                job_id,
                contest_cfg,
                now_dt
            )
            if voting_err:
                self.respond(409, {'error': voting_err})
                return
            voting_ends_dt = parse_iso8601(voting_ends_at)
            if voting_ends_dt is None:
                self.respond(500, {'error': 'voting window is invalid; job needs operator repair'})
                return

            min_votes = int(contest_cfg['min_votes_to_select'] or 1)
            voting_window_open = now_dt <= voting_ends_dt
            eligible_voters_count = len(voter_snapshot)

            submissions = db.execute(
                '''SELECT s.submission_id, s.agent_id, s.payload, s.updated_at,
                          COALESCE(SUM(CASE WHEN v.vote = 'approve' THEN 1 ELSE 0 END), 0) AS approve_votes,
                          COALESCE(SUM(CASE WHEN v.vote = 'reject' THEN 1 ELSE 0 END), 0) AS reject_votes
                   FROM job_submissions s
                   LEFT JOIN submission_votes v
                     ON v.job_id = s.job_id AND v.submission_id = s.submission_id
                   WHERE s.job_id = ?
                   GROUP BY s.submission_id, s.agent_id, s.payload, s.updated_at
                   ORDER BY (approve_votes - reject_votes) DESC, approve_votes DESC, s.updated_at ASC''',
                (job_id,)
            ).fetchall()
            if not submissions:
                self.respond(409, {'error': 'no submissions to select'})
                return

            candidate = None
            if selected_submission_id:
                for row_submission in submissions:
                    if row_submission['submission_id'] == selected_submission_id:
                        candidate = row_submission
                        break
                if not candidate:
                    self.respond(404, {'error': 'submission not found'})
                    return
            else:
                candidate = submissions[0]

            approve_votes = int(candidate['approve_votes'])
            reject_votes = int(candidate['reject_votes'])
            total_votes = approve_votes + reject_votes
            score = approve_votes - reject_votes
            if voting_window_open:
                required_majority = (eligible_voters_count // 2) + 1
                if approve_votes < required_majority:
                    self.respond(409, {
                        'error': f'early selection requires strict majority (need >= {required_majority} approve votes)',
                        'voting_ends_at': voting_ends_at,
                        'eligible_voters_count': eligible_voters_count,
                        'current': {'approve': approve_votes, 'reject': reject_votes}
                    })
                    return
            else:
                if total_votes < min_votes:
                    self.respond(409, {
                        'error': f'not enough votes to select winner after vote window (need >= {min_votes}, got {total_votes})',
                        'voting_ends_at': voting_ends_at
                    })
                    return
                if approve_votes <= reject_votes:
                    self.respond(409, {
                        'error': 'winner must have majority of votes cast after vote window',
                        'voting_ends_at': voting_ends_at,
                        'current': {'approve': approve_votes, 'reject': reject_votes}
                    })
                    return
                if not selected_submission_id and len(submissions) > 1:
                    top = submissions[0]
                    second = submissions[1]
                    top_score = int(top['approve_votes']) - int(top['reject_votes'])
                    second_score = int(second['approve_votes']) - int(second['reject_votes'])
                    if top_score == second_score and int(top['approve_votes']) == int(second['approve_votes']):
                        self.respond(409, {
                            'error': 'top submissions are tied after vote window; move to dispute or manual selection',
                            'voting_ends_at': voting_ends_at
                        })
                        return

            now = now_dt.isoformat()
            amount_specks = row['amount_specks'] or 0
            fee_bps = int(os.environ.get('OPERATOR_FEE_BPS', '200'))
            fee = amount_specks * fee_bps // 10000
            net_to_agent = amount_specks - fee

            if amount_specks >= MULTISIG_THRESHOLD_SPECKS:
                next_status = 'multisig_pending'
                approved_at = None
            else:
                next_status = 'awaiting_approval'
                approved_at = (now_dt + timedelta(hours=OPTIMISTIC_WINDOW_HOURS)).isoformat()

            result_payload = json.dumps({
                'selection_mode': 'manual' if selected_submission_id else 'auto',
                'winner_submission_id': candidate['submission_id'],
                'winner_agent_id': candidate['agent_id'],
                'winner_votes': {
                    'approve': approve_votes,
                    'reject': reject_votes,
                    'score': score
                },
                'voting': {
                    'started_at': voting_started_at,
                    'ends_at': voting_ends_at,
                    'eligible_voters_count': eligible_voters_count,
                    'agent_voting_only': bool(contest_cfg.get('agent_voting_only', True)),
                    'vote_window_hours': int(contest_cfg.get('vote_window_hours', 24) or 24),
                    'finalize_basis': 'early_majority' if voting_window_open else 'window_expired_majority'
                },
                'submission_preview': json.loads(candidate['payload']) if candidate['payload'] else {}
            })

            db.execute(
                'UPDATE job_submissions SET is_winner = 0, selected_at = NULL WHERE job_id = ?',
                (job_id,)
            )
            db.execute(
                'UPDATE job_submissions SET is_winner = 1, selected_at = ? WHERE job_id = ? AND submission_id = ?',
                (now, job_id, candidate['submission_id'])
            )
            db.execute(
                '''UPDATE jobs
                   SET result = ?, status = ?, approved_at = ?, assigned_agent_id = ?, updated_at = ?
                   WHERE job_id = ?''',
                (result_payload, next_status, approved_at, candidate['agent_id'], now, job_id)
            )
            event_status = external_status_from_internal(next_status, amount_specks)
            status_event_id = record_status_event(
                db,
                job_id,
                event_status,
                result={'winner_submission_id': candidate['submission_id'], 'internal_status': next_status}
            )
            db.commit()

            self.respond(200, {
                'job_id': job_id,
                'status': event_status,
                'internal_status': next_status,
                'status_id': status_event_id,
                'approved_at': approved_at,
                'winner_submission_id': candidate['submission_id'],
                'winner_agent_id': candidate['agent_id'],
                'winner_votes': {
                    'approve': approve_votes,
                    'reject': reject_votes,
                    'score': score,
                    'total': total_votes
                },
                'voting': {
                    'started_at': voting_started_at,
                    'ends_at': voting_ends_at,
                    'eligible_voters_count': eligible_voters_count,
                    'agent_voting_only': bool(contest_cfg.get('agent_voting_only', True)),
                    'vote_window_hours': int(contest_cfg.get('vote_window_hours', 24) or 24),
                    'finalize_basis': 'early_majority' if voting_window_open else 'window_expired_majority'
                },
                'economics': {
                    'amount_specks': amount_specks,
                    'fee': fee,
                    'net_to_agent': net_to_agent,
                    'fee_bps': fee_bps
                },
                'message': (
                    'winner selected, optimistic window started'
                    if next_status == 'awaiting_approval'
                    else 'winner selected, awaiting multisig approval'
                )
            })

        elif path_only.startswith('/provide_input/') or path_only == '/provide_input':
            legacy_path = path_only.startswith('/provide_input/')
            job_id = path_only.split('/')[-1] if legacy_path else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return

            # SECURITY: validate job_id format
            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            strict_semantics = (MIP003_MODE == 'strict' and not legacy_path)
            input_payload = body if isinstance(body, dict) else {}
            status_id = ''
            submit_agent_id = str(body.get('agent_id', '')).strip() if isinstance(body, dict) else ''
            verified_identity = None

            db  = get_db()
            row = db.execute(
                'SELECT work_commit, amount_specks, status, assigned_agent_id FROM jobs WHERE job_id = ?',
                (job_id,)
            ).fetchone()
            if not row:
                self.respond(404, {'error': 'job not found'})
                return

            # SECURITY: only accept input while job is still running
            if row['status'] != 'running':
                self.respond(409, {'error': f'job is not running (status: {row["status"]})'})
                return

            if AGENT_IDENTITY_ENFORCE:
                if not validate_actor_id(submit_agent_id):
                    self.respond(400, {'error': 'agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars when AGENT_IDENTITY_ENFORCE=1'})
                    return
                verified_identity = self._require_verified_agent(db, submit_agent_id)
                if verified_identity is False:
                    return

            if strict_semantics:
                if not isinstance(body, dict):
                    self.respond(400, {'error': 'JSON object body required in strict mode'})
                    return
                payload_job_id = str(body.get('job_id', '')).strip()
                if payload_job_id and payload_job_id != job_id:
                    self.respond(409, {'error': 'job_id in body must match job_id query parameter'})
                    return
                status_id = str(body.get('status_id', '')).strip()
                input_payload = body.get('input_data')
                if not status_id:
                    self.respond(400, {'error': 'status_id is required in strict mode'})
                    return
                if not isinstance(input_payload, dict):
                    self.respond(400, {'error': 'input_data object is required in strict mode'})
                    return

                expected = db.execute(
                    '''SELECT status_id FROM job_status_events
                       WHERE job_id = ? AND status = 'awaiting_input'
                       ORDER BY created_at DESC, status_id DESC
                       LIMIT 1''',
                    (job_id,)
                ).fetchone()
                if not expected:
                    record_status_event(db, job_id, 'awaiting_input', input_schema={'required': ['input_data'], 'job_id': job_id})
                    expected = db.execute(
                        '''SELECT status_id FROM job_status_events
                           WHERE job_id = ? AND status = 'awaiting_input'
                           ORDER BY created_at DESC, status_id DESC
                           LIMIT 1''',
                        (job_id,)
                    ).fetchone()
                if not expected or expected['status_id'] != status_id:
                    self.respond(409, {'error': 'status_id does not match latest awaiting_input status event'})
                    return
            else:
                # Legacy/compat flow requires bearer token.
                auth_header = self.headers.get('Authorization', '')
                if not auth_header.startswith('Bearer '):
                    self.respond(401, {'error': 'Authorization: Bearer <job_token> required'})
                    return
                provided_token = auth_header[len('Bearer '):]
                if not verify_job_token(job_id, provided_token):
                    self.respond(403, {'error': 'invalid job_token'})
                    return

            # SECURITY: commit-reveal verification (skipped if no work_commit — backward compat)
            work_commit = row['work_commit']
            if work_commit is not None:
                work  = input_payload.get('work') if isinstance(input_payload, dict) else None
                nonce = input_payload.get('work_nonce') if isinstance(input_payload, dict) else None
                if not work or not nonce:
                    self.respond(400, {'error': 'work and work_nonce required for commit-reveal jobs'})
                    return
                if not verify_work_reveal(work_commit, str(work), str(nonce)):
                    self.respond(400, {'error': 'commit-reveal mismatch: sha256(nightpay-work-reveal-v1:work:nonce) != work_commit'})
                    return

            now           = datetime.now(timezone.utc)
            now_iso       = now.isoformat()
            if AGENT_IDENTITY_ENFORCE:
                ok, err = self._enforce_submitter_link(
                    db=db,
                    job_id=job_id,
                    agent_id=submit_agent_id,
                    assigned_agent_id=row['assigned_agent_id'],
                    now_iso=now_iso,
                )
                if not ok:
                    self.respond(403, {'error': err})
                    return
            amount_specks = row['amount_specks'] or 0

            # Determine delivery path
            if amount_specks >= MULTISIG_THRESHOLD_SPECKS:
                next_status = 'multisig_pending'
                approved_at = None  # no auto-approve until M-of-N collected
            else:
                next_status = 'awaiting_approval'
                approved_at = (now + timedelta(hours=OPTIMISTIC_WINDOW_HOURS)).isoformat()

            db.execute(
                '''UPDATE jobs
                   SET extra_input = ?, status = ?, approved_at = ?, updated_at = ?
                   WHERE job_id = ?''',
                (json.dumps(input_payload), next_status, approved_at, now_iso, job_id)
            )
            event_status = external_status_from_internal(next_status, amount_specks)
            status_event_id = record_status_event(
                db,
                job_id,
                event_status,
                input_schema={'status_id': status_id or None, 'strict': strict_semantics},
                result={'approved_at': approved_at, 'internal_status': next_status, 'agent_id': submit_agent_id if AGENT_IDENTITY_ENFORCE else None}
            )
            db.commit()
            if strict_semantics:
                self.respond(200, {
                    'id': status_event_id,
                    'job_id': job_id,
                    'status': event_status,
                    'internal_status': next_status,
                    'approved_at': approved_at,
                    'agent_id': submit_agent_id if AGENT_IDENTITY_ENFORCE else None,
                    'agent_verified': bool(verified_identity) if AGENT_IDENTITY_ENFORCE else False,
                })
            else:
                self.respond(200, {
                    'status':      event_status,
                    'internal_status': next_status,
                    'status_id':   status_event_id,
                    'approved_at': approved_at,
                    'agent_id': submit_agent_id if AGENT_IDENTITY_ENFORCE else None,
                    'agent_verified': bool(verified_identity) if AGENT_IDENTITY_ENFORCE else False,
                    'message':     'work accepted, optimistic window started'
                                   if next_status == 'awaiting_approval'
                                   else 'work accepted, awaiting multisig approval'
                })

        elif path_only.startswith('/provide_result/') or path_only == '/provide_result':
            # ClawWork-compatible: agent delivers final work output + artifact paths.
            # Legacy mode: single delivery transitions job to approval flow.
            # Contest mode: claimed agents can submit candidates; winner is chosen later via /select_winner/<job_id>.
            job_id = path_only.split('/')[-1] if path_only.startswith('/provide_result/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return

            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            auth_header = self.headers.get('Authorization', '')
            provided_token = ''
            token_valid = False
            if auth_header:
                if not auth_header.startswith('Bearer '):
                    self.respond(401, {'error': 'Authorization: Bearer <job_token> required'})
                    return
                provided_token = auth_header[len('Bearer '):]
                token_valid = verify_job_token(job_id, provided_token)
                if not token_valid:
                    self.respond(403, {'error': 'invalid job_token'})
                    return

            work_output = str(body.get('work_output', ''))
            artifact_paths = body.get('artifact_file_paths', [])
            if not isinstance(artifact_paths, list):
                artifact_paths = []
            submit_agent_id = str(body.get('agent_id', '')).strip() if isinstance(body, dict) else ''
            verified_identity = None

            if len(work_output) < 10:
                self.respond(400, {'error': 'work_output must be at least 10 chars'})
                return

            db  = get_db()
            row = db.execute(
                'SELECT work_commit, amount_specks, status, assigned_agent_id, contest_config FROM jobs WHERE job_id = ?',
                (job_id,)
            ).fetchone()
            if not row:
                self.respond(404, {'error': 'job not found'})
                return
            if row['status'] != 'running':
                self.respond(409, {'error': 'job is not running (status: %s)' % row['status']})
                return

            if AGENT_IDENTITY_ENFORCE:
                if not validate_actor_id(submit_agent_id):
                    self.respond(400, {'error': 'agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars when AGENT_IDENTITY_ENFORCE=1'})
                    return
                verified_identity = self._require_verified_agent(db, submit_agent_id)
                if verified_identity is False:
                    return

            contest_cfg = parse_contest_config(row['contest_config'])
            if not contest_cfg['enabled'] and not token_valid:
                self.respond(401, {'error': 'Authorization: Bearer <job_token> required'})
                return

            now           = datetime.now(timezone.utc)
            now_iso       = now.isoformat()
            amount_specks = row['amount_specks'] or 0
            fee_bps       = int(os.environ.get('OPERATOR_FEE_BPS', '200'))
            fee           = amount_specks * fee_bps // 10000
            net_to_agent  = amount_specks - fee

            payload = {
                'work_output':      work_output[:500],  # store truncated — full output is agent-side
                'artifact_paths':   artifact_paths,
                'artifact_count':   len(artifact_paths),
            }

            if contest_cfg['enabled']:
                # Contest submissions are authenticated by claimed agent_id (or valid job token).
                agent_id = submit_agent_id if AGENT_IDENTITY_ENFORCE else str(body.get('agent_id', '')).strip()
                if not validate_actor_id(agent_id):
                    self.respond(400, {'error': 'agent_id must match [A-Za-z0-9._:@-] and be 2-128 chars'})
                    return
                claimed = db.execute(
                    'SELECT 1 FROM job_claims WHERE job_id = ? AND agent_id = ?',
                    (job_id, agent_id)
                ).fetchone()
                if not claimed:
                    self.respond(409, {'error': 'agent must claim job before submitting in contest mode'})
                    return

                existing = db.execute(
                    'SELECT submission_id FROM job_submissions WHERE job_id = ? AND agent_id = ?',
                    (job_id, agent_id)
                ).fetchone()
                submission_id = existing['submission_id'] if existing else str(uuid.uuid4())
                db.execute(
                    '''INSERT INTO job_submissions(submission_id, job_id, agent_id, payload, created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?)
                       ON CONFLICT(job_id, agent_id) DO UPDATE SET
                         payload = excluded.payload,
                         updated_at = excluded.updated_at''',
                    (submission_id, job_id, agent_id, json.dumps(payload), now_iso, now_iso)
                )
                submissions_count = db.execute(
                    'SELECT COUNT(*) AS n FROM job_submissions WHERE job_id = ?',
                    (job_id,)
                ).fetchone()['n']
                voting_started_at, voting_ends_at, voter_snapshot, voting_err = ensure_voting_session(
                    db,
                    job_id,
                    contest_cfg,
                    now,
                    fallback_voter_id=agent_id
                )
                if voting_err:
                    self.respond(409, {'error': voting_err})
                    return
                status_event_id = record_status_event(
                    db,
                    job_id,
                    'running',
                    result={'submission_id': submission_id, 'agent_id': agent_id}
                )
                db.commit()

                self.respond(200, {
                    'job_id': job_id,
                    'status': 'running',
                    'internal_status': 'running',
                    'status_id': status_event_id,
                    'contest': contest_cfg,
                    'submission_id': submission_id,
                    'agent_id': agent_id,
                    'agent_verified': bool(verified_identity) if AGENT_IDENTITY_ENFORCE else False,
                    'submissions_count': submissions_count,
                    'voting': {
                        'started_at': voting_started_at,
                        'ends_at': voting_ends_at,
                        'eligible_voters_count': len(voter_snapshot),
                        'agent_voting_only': bool(contest_cfg.get('agent_voting_only', True)),
                        'vote_window_hours': int(contest_cfg.get('vote_window_hours', 24) or 24),
                    },
                    'artifact_count': len(artifact_paths),
                    'economics': {
                        'amount_specks': amount_specks,
                        'fee': fee,
                        'net_to_agent': net_to_agent,
                        'fee_bps': fee_bps,
                    },
                    'message': 'submission stored; wait for voting and winner selection'
                })
                return

            if AGENT_IDENTITY_ENFORCE:
                ok, err = self._enforce_submitter_link(
                    db=db,
                    job_id=job_id,
                    agent_id=submit_agent_id,
                    assigned_agent_id=row['assigned_agent_id'],
                    now_iso=now_iso,
                )
                if not ok:
                    self.respond(403, {'error': err})
                    return

            if amount_specks >= MULTISIG_THRESHOLD_SPECKS:
                next_status = 'multisig_pending'
                approved_at = None
            else:
                next_status = 'awaiting_approval'
                approved_at = (now + timedelta(hours=OPTIMISTIC_WINDOW_HOURS)).isoformat()

            result_payload = json.dumps(payload)

            db.execute(
                '''UPDATE jobs
                   SET result = ?, status = ?, approved_at = ?, updated_at = ?
                   WHERE job_id = ?''',
                (result_payload, next_status, approved_at, now_iso, job_id)
            )
            event_status = external_status_from_internal(next_status, amount_specks)
            status_event_id = record_status_event(
                db,
                job_id,
                event_status,
                result={
                    'artifact_count': len(artifact_paths),
                    'internal_status': next_status,
                    'agent_id': submit_agent_id if AGENT_IDENTITY_ENFORCE else None,
                }
            )
            db.commit()

            self.respond(200, {
                'status':        event_status,
                'internal_status': next_status,
                'status_id':     status_event_id,
                'approved_at':   approved_at,
                'agent_id': submit_agent_id if AGENT_IDENTITY_ENFORCE else None,
                'agent_verified': bool(verified_identity) if AGENT_IDENTITY_ENFORCE else False,
                'artifact_count': len(artifact_paths),
                # Economics footer — ClawWork-compatible shape
                'economics': {
                    'amount_specks': amount_specks,
                    'fee':           fee,
                    'net_to_agent':  net_to_agent,
                    'fee_bps':       fee_bps,
                },
                'message': (
                    'work accepted, optimistic window started'
                    if next_status == 'awaiting_approval'
                    else 'work accepted, awaiting multisig approval'
                ),
            })

        elif path_only.startswith('/dispute/') or path_only == '/dispute':
            job_id = path_only.split('/')[-1] if path_only.startswith('/dispute/') else params.get('job_id', [None])[0]
            if not job_id:
                self.respond(400, {'error': 'job_id query parameter required'})
                return

            if not self._validate_job_id(job_id):
                self.respond(400, {'error': 'invalid job_id format'})
                return

            reason = str(body.get('reason', 'no reason given'))[:500]

            # SECURITY: job_token holder, operator Bearer, or X-Operator-Sig can dispute
            auth_header   = self.headers.get('Authorization', '')
            op_sig_header = self.headers.get('X-Operator-Sig', '')
            authorized    = False

            if auth_header.startswith('Bearer '):
                token = auth_header[len('Bearer '):].strip()
                if verify_job_token(job_id, token):
                    authorized = True
                if not authorized and self._operator_bearer_ok():
                    authorized = True

            if not authorized and op_sig_header:
                if verify_operator_sig(job_id, reason, op_sig_header):
                    authorized = True

            if not authorized:
                self.respond(403, {'error': 'dispute requires valid job_token, operator Bearer, or X-Operator-Sig'})
                return

            db  = get_db()
            now = datetime.now(timezone.utc).isoformat()
            cur = db.execute(
                '''UPDATE jobs SET status = 'disputed', dispute_reason = ?, updated_at = ?
                   WHERE job_id = ? AND status IN ('running', 'awaiting_approval', 'multisig_pending') ''',
                (reason, now, job_id)
            )
            if cur.rowcount == 0:
                # Check if job exists at all
                exists = db.execute('SELECT status FROM jobs WHERE job_id = ?', (job_id,)).fetchone()
                if not exists:
                    self.respond(404, {'error': 'job not found'})
                else:
                    self.respond(409, {'error': f'job cannot be disputed in current state (status: {exists["status"]})'})
            else:
                status_event_id = record_status_event(
                    db,
                    job_id,
                    'failed',
                    result={'reason': reason, 'internal_status': 'disputed'}
                )
                db.commit()
                self.respond(200, {
                    'status': 'failed',
                    'internal_status': 'disputed',
                    'status_id': status_event_id,
                    'reason': reason
                })

        else:
            self.respond(404, {'error': 'not found'})

    def do_PATCH(self):
        parsed = urlparse(self.path)
        if self._proxy_ollama(parsed.path):
            return
        self.respond(404, {'error': 'not found'})

class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_slots = threading.BoundedSemaphore(MIP003_MAX_INFLIGHT)

    def process_request(self, request, client_address):
        self.request_slots.acquire()
        try:
            super().process_request(request, client_address)
        except Exception:
            self.request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.request_slots.release()

httpd = ThreadedHTTPServer(('0.0.0.0', PORT), MIP003Handler)
print(f'[nightpay] MIP-003 threaded service ready on port {PORT}')
if DB_BACKEND == 'postgres':
    print(f'[nightpay] DB: postgres (pool={DB_POOL_SIZE})')
else:
    print(f'[nightpay] DB: sqlite ({DB_PATH})')
print(f"[nightpay] Optimistic window: {OPTIMISTIC_WINDOW_HOURS}h | Multisig threshold: {MULTISIG_THRESHOLD_SPECKS} specks | Fee: {os.environ.get('OPERATOR_FEE_BPS','200')} bps")
print(f'[nightpay] MIP003 mode: {MIP003_MODE}')
print(f'[nightpay] Idempotency TTL: {IDEMPOTENCY_TTL_SECONDS}s (X-Idempotency-Key)')
print(f'[nightpay] Max inflight requests: {MIP003_MAX_INFLIGHT}')
print(f'[nightpay] Agent identity enforce: {AGENT_IDENTITY_ENFORCE} | challenge TTL: {AGENT_CHALLENGE_TTL_SECONDS}s | token TTL: {AGENT_VERIFIED_TOKEN_TTL_SECONDS}s')
print(f'[nightpay] Management LLM: enabled={MANAGEMENT_LLM_ENABLED} | url={MANAGEMENT_LLM_URL} | model={MANAGEMENT_LLM_MODEL} | timeout={MANAGEMENT_LLM_TIMEOUT_SECONDS}s')
endpoints = '/availability /use_cases /agents /ontology /ontology/context /ontology/examples /ontology/examples/<id> /management/help /management/chat /input_schema /demo /agent/challenge /agent/verify /start_job /status?job_id= /status/<id> /claim_job/<id> /vote_result/<id> /vote_submission/<job_id>/<submission_id> /submissions/<id> /select_winner/<id> /provide_input?job_id= /provide_input/<id> /provide_result/<id> /dispute/<id> /jobs?status=&limit=&offset=&approved_before=&search=&visibility='
print(f'[nightpay] Endpoints: {endpoints}')
httpd.serve_forever()
PYCODE

