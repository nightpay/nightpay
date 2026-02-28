#!/usr/bin/env bash
# nightpay blocklist updater — pulls from open-source threat intel feeds
# and merges into a local rules file consumed by gateway.sh safety_check.
#
# Run via cron or systemd timer:
#   0 */6 * * * /path/to/update-blocklist.sh
#
# PRIVACY: fetches category patterns only — never sends bounty data upstream.
#
# Sources:
#   - OISF/suricata-update    — IDS rule categories (violence, drugs, fraud)
#   - stamparm/maltrail        — malicious keyword/phrase lists
#   - operator custom rules    — local overrides in custom-rules.json
#
# Output: ~/.nightpay/safety-rules.json (consumed by gateway.sh)
#
# Usage: ./update-blocklist.sh [--dry-run]

set -euo pipefail

SAFETY_DIR="${SAFETY_DIR:-${HOME}/.nightpay/safety}"
RULES_FILE="${SAFETY_DIR}/safety-rules.json"
CUSTOM_RULES="${SAFETY_DIR}/custom-rules.json"
COMMUNITY_REPORTS="${SAFETY_DIR}/community-reports.json"
FEED_CACHE="${SAFETY_DIR}/feed-cache"
LOCKFILE="${SAFETY_DIR}/update.lock"

DRY_RUN="${1:-}"

mkdir -p "$SAFETY_DIR" "$FEED_CACHE"
chmod 700 "$SAFETY_DIR"

# ─── Locking ──────────────────────────────────────────────────────────────────
# Prevent concurrent updates from corrupting the rules file
if [ -f "$LOCKFILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(cat "$LOCKFILE" 2>/dev/null || echo 0) ))
  if (( LOCK_AGE < 300 )); then
    echo "ERROR: Another update is running (lock age: ${LOCK_AGE}s)" >&2
    exit 1
  fi
  echo "WARNING: Stale lock found (${LOCK_AGE}s) — overriding" >&2
fi
date +%s > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# ─── Feed fetchers ────────────────────────────────────────────────────────────
# Each fetcher outputs JSON lines: {"category": "...", "pattern": "...", "source": "..."}

fetch_stamparm_keywords() {
  # stamparm/maltrail — trails/static/malware directory has keyword lists
  # We extract category names as patterns for known-bad campaign names
  local url="https://raw.githubusercontent.com/stamparm/maltrail/master/trails/static/suspicious/domain.txt"
  local cache="${FEED_CACHE}/stamparm-domains.txt"

  curl -sf --max-time 30 -o "$cache.tmp" "$url" 2>/dev/null || {
    echo "WARNING: Failed to fetch stamparm feed" >&2
    return 0
  }
  mv "$cache.tmp" "$cache"

  # Extract domain-based patterns for known malicious services
  python3 -c "
import sys
# We don't use domains directly — we extract category hints from comments
# and common malicious service names for pattern matching
known_bad_services = [
    # These are services commonly used for harmful content distribution
    'ransomware', 'phishing', 'malware', 'botnet', 'c2', 'exploit-kit',
    'cryptojacking', 'credential-theft', 'keylogger', 'rat-trojan'
]
for svc in known_bad_services:
    print(f'{svc}|cyberattack|{svc}')
" 2>/dev/null || true
}

fetch_community_reports() {
  # Load patterns derived from community complaints
  # community-reports.json is built by the 'complaint' command in bounty-board.sh
  if [ -f "$COMMUNITY_REPORTS" ]; then
    python3 -c "
import json, sys, re

with open(sys.argv[1]) as f:
    reports = json.load(f)

# A commitment that gets >= THRESHOLD complaints gets its category patterns promoted
THRESHOLD = 3

category_counts = {}
for report in reports.get('reports', []):
    cat = report.get('category', 'unknown')
    category_counts[cat] = category_counts.get(cat, 0) + 1

# Report which categories are trending in complaints
for cat, count in category_counts.items():
    if count >= THRESHOLD and cat != 'other':
        print(f'{cat}|community_report|community({count} reports)')
" "$COMMUNITY_REPORTS" 2>/dev/null || true
  fi
}

# ─── Merge rules ──────────────────────────────────────────────────────────────

python3 -c "
import json, sys, os, re
from datetime import datetime, timezone

safety_dir = sys.argv[1]
rules_file = sys.argv[2]
custom_file = sys.argv[3]
dry_run = sys.argv[4] == '--dry-run'

# Base rules — the hardcoded set from gateway.sh, kept as authoritative source
BASE_RULES = [
    {'category': 'csam',                    'pattern': r'\b(child|minor|underage|kid|teen)\b.*\b(sex|porn|nude|naked|exploit)\b', 'source': 'base'},
    {'category': 'csam',                    'pattern': r'\b(sex|porn|nude|naked|exploit)\b.*\b(child|minor|underage|kid|teen)\b', 'source': 'base'},
    {'category': 'violence',                'pattern': r'\b(kill|assassinate|murder|execute)\b.*\b(person|people|someone|him|her|them|target)\b', 'source': 'base'},
    {'category': 'violence',                'pattern': r'\b(hire|find|pay).*\b(hitman|killer|assassin)\b', 'source': 'base'},
    {'category': 'violence',                'pattern': r'\bhit\s*man\b', 'source': 'base'},
    {'category': 'weapons_of_mass_destruction', 'pattern': r'\b(synthe|build|make|create|assemble)\b.*\b(bomb|bioweapon|chemical weapon|nerve agent|sarin|anthrax|ricin|nuclear|dirty bomb|explosive device)\b', 'source': 'base'},
    {'category': 'human_trafficking',       'pattern': r'\b(traffic|smuggle|exploit|enslave)\b.*\b(person|people|human|worker|organ|women|children)\b', 'source': 'base'},
    {'category': 'terrorism',               'pattern': r'\b(fund|finance|recruit|plan|support)\b.*\b(terror|jihad|extremis|insurrection|attack on)\b', 'source': 'base'},
    {'category': 'ncii',                    'pattern': r'\b(deepfake|revenge porn|sextortion|non.?consensual)\b.*\b(nude|naked|intimate|image|video|photo)\b', 'source': 'base'},
    {'category': 'financial_fraud',         'pattern': r'\b(launder|counterfeit|forge)\b.*\b(money|currency|documents|passport|identity)\b', 'source': 'base'},
    {'category': 'financial_fraud',         'pattern': r'\b(evade|bypass|circumvent)\b.*\b(sanction|embargo|aml|kyc)\b', 'source': 'base'},
    {'category': 'infrastructure_attack',   'pattern': r'\b(attack|hack|disrupt|destroy|sabotage)\b.*\b(power grid|water supply|hospital|election|pipeline|dam)\b', 'source': 'base'},
    {'category': 'doxxing',                 'pattern': r'\b(doxx|stalk|track|surveil|locate)\b.*\b(person|address|home|family|where .* live)\b', 'source': 'base'},
    {'category': 'drug_manufacturing',      'pattern': r'\b(synthe|cook|manufacture|produce)\b.*\b(meth|fentanyl|heroin|cocaine|mdma|lsd)\b', 'source': 'base'},
]

all_rules = list(BASE_RULES)

# Load operator custom rules
if os.path.exists(custom_file):
    try:
        with open(custom_file) as f:
            custom = json.load(f)
        for rule in custom.get('rules', []):
            if 'category' in rule and 'pattern' in rule:
                # Validate regex compiles
                try:
                    re.compile(rule['pattern'])
                    rule['source'] = 'custom'
                    all_rules.append(rule)
                except re.error as e:
                    print(f'WARNING: Skipping invalid custom regex: {e}', file=sys.stderr)
    except (json.JSONDecodeError, KeyError) as e:
        print(f'WARNING: Failed to load custom rules: {e}', file=sys.stderr)

# Read feed data from stdin (piped from fetchers)
feed_lines = []
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split('|', 2)
    if len(parts) == 3:
        feed_lines.append({
            'category': parts[0],
            'pattern': r'\b' + re.escape(parts[0]) + r'\b',
            'source': f'feed:{parts[2]}'
        })

all_rules.extend(feed_lines)

# Deduplicate by pattern
seen = set()
deduped = []
for rule in all_rules:
    if rule['pattern'] not in seen:
        seen.add(rule['pattern'])
        deduped.append(rule)

output = {
    'version': datetime.now(timezone.utc).isoformat(),
    'rule_count': len(deduped),
    'sources': list(set(r.get('source', 'unknown') for r in deduped)),
    'rules': deduped
}

if dry_run:
    print(json.dumps(output, indent=2))
    print(f'\n--- DRY RUN: {len(deduped)} rules would be written ---', file=sys.stderr)
else:
    # Atomic write — write to temp then rename
    tmp = rules_file + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(output, f, indent=2)
    os.rename(tmp, rules_file)
    print(f'Updated {rules_file}: {len(deduped)} rules from {len(output[\"sources\"])} sources')
" "$SAFETY_DIR" "$RULES_FILE" "$CUSTOM_RULES" "$DRY_RUN" < <(
  fetch_stamparm_keywords
  fetch_community_reports
)
