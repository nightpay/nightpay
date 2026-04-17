#!/usr/bin/env bash
# seed-corpus.sh — push the realistic brief corpus into a running MIP-003 server.
#
# Parses skills/nightpay/ontology/briefs/<category>/<slug>.md, calls POST /start_job
# for each brief, records the returned job_id in .tmp/seed-state.json so re-runs
# are idempotent. Optionally walks a subset through claim -> provide_result ->
# select_winner so the board shows completed work as well.
#
# Usage:
#   bash scripts/seed-corpus.sh [options]
#
# Options:
#   --base-url <url>           MIP-003 base URL (default: http://127.0.0.1:8090)
#   --state-file <path>        Idempotency state (default: .tmp/seed-state.json)
#   --only <category>          Only seed briefs in <category> (audit|build|data|research|design|translate|integrate|ops|all)
#   --limit <n>                Seed at most N briefs (for dev / smoke tests)
#   --complete-fraction <0-1>  Walk this fraction through claim -> submit -> complete (default: 0.0)
#   --operator-secret <hex>    Operator bearer used for /complete_job (default: $OPERATOR_SECRET_KEY)
#   --timeout-seconds <n>      HTTP timeout per request (default: 10)
#   --regenerate-index         Rewrite skills/nightpay/ontology/briefs/INDEX.md from the corpus and exit
#   --dry-run                  Print what would happen without calling /start_job
#   -h, --help                 Show this help
#
# Post-deploy usage (Hetzner):
#   ssh root@HOST 'su - deploy -c "cd /opt/nightpay && bash scripts/seed-corpus.sh --base-url http://127.0.0.1:8090"'

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEFS_DIR="$ROOT_DIR/skills/nightpay/ontology/briefs"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

BASE_URL="http://127.0.0.1:8090"
STATE_FILE="$ROOT_DIR/.tmp/seed-state.json"
ONLY="all"
LIMIT=0
COMPLETE_FRACTION="0.0"
OPERATOR_SECRET="${OPERATOR_SECRET_KEY:-}"
TIMEOUT_SECONDS=10
REGENERATE_INDEX=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-all}"; shift 2 ;;
    --limit) LIMIT="${2:-0}"; shift 2 ;;
    --complete-fraction) COMPLETE_FRACTION="${2:-0.0}"; shift 2 ;;
    --operator-secret) OPERATOR_SECRET="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-10}"; shift 2 ;;
    --regenerate-index) REGENERATE_INDEX=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
if [[ -z "$PYTHON_BIN" || "$PYTHON_BIN" == *"WindowsApps"* ]]; then
  PYTHON_BIN="$(command -v python 2>/dev/null || true)"
fi
[[ -n "$PYTHON_BIN" ]] || { echo "ERROR: python3/python required" >&2; exit 1; }

if [[ ! -d "$BRIEFS_DIR" ]]; then
  echo "ERROR: briefs directory not found: $BRIEFS_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"

export BASE_URL STATE_FILE ONLY LIMIT COMPLETE_FRACTION OPERATOR_SECRET TIMEOUT_SECONDS REGENERATE_INDEX DRY_RUN BRIEFS_DIR ROOT_DIR

"$PYTHON_BIN" - <<'PY'
import hashlib
import json
import os
import random
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime, timezone

BASE_URL = os.environ['BASE_URL'].rstrip('/')
STATE_FILE = os.environ['STATE_FILE']
ONLY = os.environ['ONLY'] or 'all'
LIMIT = int(os.environ.get('LIMIT') or 0)
try:
    COMPLETE_FRACTION = float(os.environ.get('COMPLETE_FRACTION') or '0.0')
except ValueError:
    COMPLETE_FRACTION = 0.0
OPERATOR_SECRET = os.environ.get('OPERATOR_SECRET') or ''
TIMEOUT_SECONDS = int(os.environ.get('TIMEOUT_SECONDS') or 10)
REGENERATE_INDEX = os.environ.get('REGENERATE_INDEX') == '1'
DRY_RUN = os.environ.get('DRY_RUN') == '1'
BRIEFS_DIR = os.environ['BRIEFS_DIR']
ROOT_DIR = os.environ['ROOT_DIR']

BRIEF_ALLOWED_CATEGORIES = (
    'audit', 'build', 'data', 'research',
    'design', 'translate', 'integrate', 'ops',
)

def _log(prefix, msg):
    ts = datetime.now(timezone.utc).strftime('%H:%M:%S')
    print(f'[{ts}] {prefix} {msg}', flush=True)

def _parse_scalar(raw):
    text = raw.strip()
    if text == '' or text.lower() in ('null', '~'):
        return None
    if text.lower() == 'true':
        return True
    if text.lower() == 'false':
        return False
    if re.fullmatch(r'-?\d+', text):
        try:
            return int(text)
        except ValueError:
            return text
    if re.fullmatch(r'-?\d+\.\d+', text):
        try:
            return float(text)
        except ValueError:
            return text
    if (text.startswith('"') and text.endswith('"')) or (text.startswith("'") and text.endswith("'")):
        return text[1:-1]
    if text.startswith('[') and text.endswith(']'):
        inner = text[1:-1].strip()
        if inner == '':
            return []
        parts = []
        current = ''
        depth = 0
        for ch in inner:
            if ch == ',' and depth == 0:
                parts.append(current)
                current = ''
            else:
                if ch in '[{':
                    depth += 1
                elif ch in ']}':
                    depth -= 1
                current += ch
        parts.append(current)
        return [_parse_scalar(p) for p in parts if p.strip() != '']
    return text

def _parse_frontmatter(raw_fm):
    data = {}
    lines = raw_fm.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped == '' or stripped.startswith('#'):
            i += 1
            continue
        indent = len(line) - len(line.lstrip(' '))
        if indent != 0:
            i += 1
            continue
        if ':' not in stripped:
            i += 1
            continue
        key, _, value = stripped.partition(':')
        key = key.strip()
        value = value.strip()
        if value != '':
            data[key] = _parse_scalar(value)
            i += 1
            continue
        block_items = []
        block_obj = None
        j = i + 1
        while j < len(lines):
            child = lines[j]
            child_stripped = child.strip()
            if child_stripped == '':
                j += 1
                continue
            child_indent = len(child) - len(child.lstrip(' '))
            if child_indent == 0:
                break
            if child_stripped.startswith('- '):
                item = child_stripped[2:].strip()
                if ':' in item and not (item.startswith('"') or item.startswith("'")):
                    item_key, _, item_val = item.partition(':')
                    current = {item_key.strip(): _parse_scalar(item_val)}
                    k = j + 1
                    while k < len(lines):
                        nxt = lines[k]
                        nxt_stripped = nxt.strip()
                        if nxt_stripped == '':
                            k += 1
                            continue
                        nxt_indent = len(nxt) - len(nxt.lstrip(' '))
                        if nxt_indent <= child_indent:
                            break
                        if nxt_stripped.startswith('- ') or ':' not in nxt_stripped:
                            break
                        nk, _, nv = nxt_stripped.partition(':')
                        current[nk.strip()] = _parse_scalar(nv)
                        k += 1
                    block_items.append(current)
                    j = k
                else:
                    block_items.append(_parse_scalar(item))
                    j += 1
            elif ':' in child_stripped:
                obj_key, _, obj_val = child_stripped.partition(':')
                if block_obj is None:
                    block_obj = {}
                block_obj[obj_key.strip()] = _parse_scalar(obj_val)
                j += 1
            else:
                j += 1
        if block_items:
            data[key] = block_items
        elif block_obj is not None:
            data[key] = block_obj
        else:
            data[key] = None
        i = j
    return data

def load_briefs():
    briefs = []
    for category in sorted(os.listdir(BRIEFS_DIR)):
        cat_path = os.path.join(BRIEFS_DIR, category)
        if not os.path.isdir(cat_path) or category.startswith('.'):
            continue
        if category.lower() not in BRIEF_ALLOWED_CATEGORIES:
            continue
        for fname in sorted(os.listdir(cat_path)):
            if not fname.endswith('.md'):
                continue
            if fname.lower() in ('index.md', 'readme.md'):
                continue
            path = os.path.join(cat_path, fname)
            with open(path, 'r', encoding='utf-8') as fh:
                raw = fh.read()
            if not raw.startswith('---'):
                continue
            rest = raw[3:]
            end = rest.find('\n---')
            if end == -1:
                continue
            fm_raw = rest[:end].lstrip('\n')
            body = rest[end + 4:].lstrip('\n')
            fm = _parse_frontmatter(fm_raw)
            slug = fname[:-3]
            if str(fm.get('brief_id') or '').strip() != slug:
                _log('WARN', f'brief_id mismatch in {path}; skipping')
                continue
            briefs.append({
                'brief_id': slug,
                'title': str(fm.get('title') or '').strip(),
                'category': category.lower(),
                'capability_tags': [str(t).strip() for t in (fm.get('capability_tags') or []) if str(t).strip()],
                'amount_specks': int(fm.get('amount_specks') or 0),
                'contest': fm.get('contest') if isinstance(fm.get('contest'), dict) else {},
                'expected_artifacts': fm.get('expected_artifacts') if isinstance(fm.get('expected_artifacts'), list) else [],
                'acceptance_criteria': fm.get('acceptance_criteria') if isinstance(fm.get('acceptance_criteria'), list) else [],
                'body': body.strip(),
                'source_path': path,
            })
    return briefs

def regenerate_index(briefs):
    out = [
        '# NightPay seed corpus — index',
        '',
        'Auto-generated by `scripts/seed-corpus.sh --regenerate-index`. Do not edit by hand.',
        '',
    ]
    by_cat = {}
    for b in briefs:
        by_cat.setdefault(b['category'], []).append(b)
    for cat in BRIEF_ALLOWED_CATEGORIES:
        rows = sorted(by_cat.get(cat, []), key=lambda r: r['brief_id'])
        if not rows:
            continue
        out.append(f'## {cat} ({len(rows)})')
        out.append('')
        out.append('| brief_id | title | specks | tags |')
        out.append('|---|---|---:|---|')
        for b in rows:
            tags = ', '.join(b['capability_tags'][:5])
            specks = f"{b['amount_specks']:,}"
            out.append(f"| `{b['brief_id']}` | {b['title']} | {specks} | {tags} |")
        out.append('')
    out.append('---')
    out.append('')
    out.append(f'**Total:** {len(briefs)} briefs across {len(BRIEF_ALLOWED_CATEGORIES)} categories.')
    out.append('')
    index_path = os.path.join(BRIEFS_DIR, 'INDEX.md')
    with open(index_path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(out))
    _log('OK', f'wrote {index_path} ({len(briefs)} briefs)')

def load_state():
    if os.path.isfile(STATE_FILE):
        try:
            with open(STATE_FILE, 'r', encoding='utf-8') as fh:
                return json.load(fh)
        except Exception as exc:
            _log('WARN', f'state file unreadable ({exc}); starting fresh')
    return {'base_url': BASE_URL, 'jobs': {}}

def save_state(state):
    tmp = STATE_FILE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
    os.replace(tmp, STATE_FILE)

def http_call(method, url, body=None, headers=None, timeout=None):
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers.setdefault('Content-Type', 'application/json')
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout or TIMEOUT_SECONDS) as resp:
            payload = resp.read().decode('utf-8', errors='replace')
            try:
                return resp.status, json.loads(payload)
            except Exception:
                return resp.status, payload
    except urllib.error.HTTPError as exc:
        payload = exc.read().decode('utf-8', errors='replace')
        try:
            return exc.code, json.loads(payload)
        except Exception:
            return exc.code, payload
    except Exception as exc:
        return 0, {'error': str(exc)}

def compute_commitment(brief_id):
    # Deterministic commitment hash so re-running the seeder doesn't churn data.
    h = hashlib.sha256(f'nightpay-seed-corpus-v1:{brief_id}'.encode()).hexdigest()
    return h

def start_job_for(brief):
    commitment = compute_commitment(brief['brief_id'])
    body = {
        'amount_specks': brief['amount_specks'] or 1000000,
        'visibility': 'public',
        'input_data': {
            'description': brief['title'] or brief['brief_id'],
            'commitmentHash': commitment,
            'brief_id': brief['brief_id'],
            'title': brief['title'],
            'category': brief['category'],
            'capability_tags': brief['capability_tags'],
        },
        'idempotency_key': f'seed-corpus-{brief["brief_id"]}',
    }
    contest = brief.get('contest') or {}
    if contest.get('enabled'):
        body['contest'] = {
            'enabled': True,
            'min_agents': int(contest.get('min_agents') or 5),
            'max_agents': int(contest.get('max_agents') or 6),
            'min_votes_to_select': int(contest.get('min_votes_to_select') or 3),
            'vote_window_hours': int(contest.get('vote_window_hours') or 24),
            'agent_voting_only': True,
        }
    return http_call('POST', f'{BASE_URL}/start_job', body=body)

def complete_flow(brief, job_id, job_token):
    # Walk through a minimal claim -> submit -> complete for a subset, so the board
    # shows completed work too. Uses the operator bearer (OPERATOR_SECRET) for
    # /complete_job. Skipped entirely if OPERATOR_SECRET is empty.
    agent_id = f'seed-agent-{brief["brief_id"][:40]}'
    headers = {'Authorization': f'Bearer {OPERATOR_SECRET}'} if OPERATOR_SECRET else {}
    code, _ = http_call('POST', f'{BASE_URL}/claim_job/{job_id}', body={'agent_id': agent_id})
    if code != 200:
        return False, f'claim_job -> {code}'
    sha = hashlib.sha256(f'{job_id}|{agent_id}|result'.encode()).hexdigest()
    code, _ = http_call('POST', f'{BASE_URL}/provide_result/{job_id}', body={
        'agent_id': agent_id,
        'work_output': f'seed corpus completion for {brief["brief_id"]}',
        'artifact_file_paths': ['/tmp/seed/result.md'],
        'artifact_sha256': [sha],
    })
    if code != 200:
        return False, f'provide_result -> {code}'
    if not OPERATOR_SECRET:
        return True, 'submitted (complete skipped: no OPERATOR_SECRET)'
    code, _ = http_call('POST', f'{BASE_URL}/complete_job/{job_id}', body={
        'commitmentHash': compute_commitment(brief['brief_id']),
    }, headers=headers)
    if code != 200:
        return False, f'complete_job -> {code}'
    return True, 'completed'

def main():
    briefs = load_briefs()
    _log('INFO', f'parsed {len(briefs)} briefs from {BRIEFS_DIR}')

    if REGENERATE_INDEX:
        regenerate_index(briefs)
        return 0

    if ONLY != 'all':
        if ONLY not in BRIEF_ALLOWED_CATEGORIES:
            _log('ERR', f'--only {ONLY!r} not in {",".join(BRIEF_ALLOWED_CATEGORIES)}')
            return 2
        briefs = [b for b in briefs if b['category'] == ONLY]
        _log('INFO', f'filtered to {len(briefs)} brief(s) in category {ONLY!r}')

    if LIMIT > 0:
        briefs = briefs[:LIMIT]
        _log('INFO', f'limited to {len(briefs)} brief(s)')

    if not DRY_RUN:
        code, _ = http_call('GET', f'{BASE_URL}/availability', timeout=5)
        if code != 200:
            _log('ERR', f'MIP-003 server at {BASE_URL} not reachable (/availability -> {code}) — is it running?')
            return 3

    state = load_state()
    state.setdefault('base_url', BASE_URL)
    state.setdefault('jobs', {})

    posted = 0
    reused = 0
    errors = 0
    random.seed(42)
    complete_targets = set()
    if COMPLETE_FRACTION > 0:
        n = max(1, int(round(COMPLETE_FRACTION * len(briefs))))
        complete_targets = set(random.sample([b['brief_id'] for b in briefs], n))

    for brief in briefs:
        if DRY_RUN:
            _log('DRY', f'{brief["category"]}/{brief["brief_id"]} -> POST /start_job')
            continue

        existing = state['jobs'].get(brief['brief_id'])
        if existing and existing.get('base_url') == BASE_URL and existing.get('job_id'):
            reused += 1
            _log('SKIP', f'{brief["brief_id"]} already seeded (job_id={existing["job_id"]})')
            continue

        code, resp = start_job_for(brief)
        if code != 200 or not isinstance(resp, dict) or not resp.get('job_id'):
            errors += 1
            _log('ERR', f'{brief["brief_id"]} /start_job -> {code} {resp!r:.160s}')
            continue
        entry = {
            'base_url': BASE_URL,
            'job_id': resp['job_id'],
            'job_token': resp.get('job_token'),
            'category': brief['category'],
            'title': brief['title'],
            'commitment': compute_commitment(brief['brief_id']),
            'seeded_at': datetime.now(timezone.utc).isoformat(),
        }

        if brief['brief_id'] in complete_targets:
            ok, detail = complete_flow(brief, resp['job_id'], resp.get('job_token'))
            entry['complete_attempt'] = detail
            if ok:
                entry['completed'] = True
            else:
                _log('WARN', f'{brief["brief_id"]} complete flow partial: {detail}')

        state['jobs'][brief['brief_id']] = entry
        save_state(state)
        posted += 1
        _log('OK', f'{brief["brief_id"]} -> job_id={resp["job_id"]}')

    _log('DONE', f'posted={posted} reused={reused} errors={errors} state={STATE_FILE}')
    if errors:
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
PY
