#!/usr/bin/env bash
# nightpay bounty board — public board backed by SQLite
#
# Handles 100K+ bounties with indexed queries, concurrent reads,
# and WAL mode for write performance. Single file, no external DB.
#
# SECURITY MODEL:
#   - Board stored in a persistent, operator-controlled directory (not /tmp)
#   - All inputs validated as 64-char hex before touching the database
#   - Only known statuses accepted for remove (completed/refunded/expired)
#   - SQLite WAL mode for safe concurrent access
#   - Directory permissions restricted to owner (chmod 700)
#
# Usage: ./bounty-board.sh <command> [args...]
# Commands: list [limit] [offset], add <commit>, remove <commit> [status], stats,
#           search <prefix>, report <commit> <category> [reason], reports [commit]

set -euo pipefail

BOARD_DIR="${BOARD_DIR:-${HOME}/.nightpay}"
BOARD_DB="${BOARD_DIR}/board.db"
COMPLAINT_FREEZE_THRESHOLD="${COMPLAINT_FREEZE_THRESHOLD:-3}"
SAFETY_REPORTS_FILE="${HOME}/.nightpay/safety/community-reports.json"

COMMAND="${1:?Usage: bounty-board.sh <command> [args...]}"
shift

validate_commitment() {
  if ! [[ "$1" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: commitment must be a 64-character lowercase hex string"; exit 1
  fi
}

mkdir -p "$BOARD_DIR"
chmod 700 "$BOARD_DIR"

# SECURITY: validate commitment hex format before any database or Python invocation.
# 'reports' without args lists all flagged — no commitment to validate.
if [[ "$COMMAND" == "add" || "$COMMAND" == "remove" || "$COMMAND" == "report" ]]; then
  validate_commitment "${1:?Usage: bounty-board.sh $COMMAND <commitment>}"
elif [[ "$COMMAND" == "reports" && "${1:-}" != "" ]]; then
  validate_commitment "$1"
fi

export COMPLAINT_FREEZE_THRESHOLD SAFETY_REPORTS_FILE

python3 -c "
import sqlite3, sys, json

db_path = sys.argv[1]
command = sys.argv[2]
args = sys.argv[3:]

conn = sqlite3.connect(db_path)
conn.execute('PRAGMA journal_mode=WAL')
conn.execute('PRAGMA synchronous=NORMAL')

conn.executescript('''
    CREATE TABLE IF NOT EXISTS bounties (
        commitment TEXT PRIMARY KEY,
        timestamp  TEXT NOT NULL,
        status     TEXT NOT NULL DEFAULT 'active'
    );
    CREATE INDEX IF NOT EXISTS idx_bounties_status ON bounties(status);
    CREATE INDEX IF NOT EXISTS idx_bounties_ts ON bounties(timestamp);

    CREATE TABLE IF NOT EXISTS stats (
        key   TEXT PRIMARY KEY,
        value INTEGER NOT NULL DEFAULT 0
    );
    INSERT OR IGNORE INTO stats(key, value) VALUES ('posted', 0);
    INSERT OR IGNORE INTO stats(key, value) VALUES ('completed', 0);
    INSERT OR IGNORE INTO stats(key, value) VALUES ('refunded', 0);
    INSERT OR IGNORE INTO stats(key, value) VALUES ('expired', 0);
    INSERT OR IGNORE INTO stats(key, value) VALUES ('flagged', 0);

    -- SAFETY: community complaint tracking.
    -- reporter_hash is sha256(reporter_id) — preserves reporter privacy
    -- while preventing duplicate reports from the same reporter.
    CREATE TABLE IF NOT EXISTS complaints (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        commitment      TEXT NOT NULL,
        category        TEXT NOT NULL,
        reason          TEXT NOT NULL DEFAULT '',
        reporter_hash   TEXT NOT NULL,
        timestamp       TEXT NOT NULL,
        UNIQUE(commitment, reporter_hash)
    );
    CREATE INDEX IF NOT EXISTS idx_complaints_commitment ON complaints(commitment);
''')

if command == 'list':
    # SECURITY: clamp limit and offset — prevent memory exhaustion from huge integers
    MAX_LIMIT = 200
    MAX_OFFSET = 10_000_000
    try:
        limit  = min(int(args[0]), MAX_LIMIT)  if len(args) > 0 else 50
        offset = min(int(args[1]), MAX_OFFSET) if len(args) > 1 else 0
    except ValueError:
        print('ERROR: limit and offset must be integers'); sys.exit(1)
    cur = conn.execute(
        'SELECT commitment, timestamp FROM bounties WHERE status = ? ORDER BY timestamp DESC LIMIT ? OFFSET ?',
        ('active', limit, offset)
    )
    rows = cur.fetchall()
    active_count = conn.execute('SELECT COUNT(*) FROM bounties WHERE status = ?', ('active',)).fetchone()[0]
    print(f'Active bounties: {active_count} (showing {offset+1}-{offset+len(rows)})')
    for commitment, ts in rows:
        print(f'  {commitment[:16]}... posted {ts}')

elif command == 'add':
    commitment = args[0]
    from datetime import datetime, timezone
    ts = datetime.now(timezone.utc).isoformat()
    try:
        conn.execute('INSERT INTO bounties(commitment, timestamp) VALUES (?, ?)', (commitment, ts))
        conn.execute('UPDATE stats SET value = value + 1 WHERE key = ?', ('posted',))
        conn.commit()
        print('Bounty added')
    except sqlite3.IntegrityError:
        print('ERROR: Bounty with this commitment already exists')
        sys.exit(1)

elif command == 'remove':
    commitment = args[0]
    status = args[1] if len(args) > 1 else 'completed'
    if status not in ('completed', 'refunded', 'expired'):
        print('ERROR: status must be completed, refunded, or expired')
        sys.exit(1)
    cur = conn.execute('UPDATE bounties SET status = ? WHERE commitment = ? AND status = ?', (status, commitment, 'active'))
    if cur.rowcount == 0:
        print('ERROR: No active bounty with that commitment')
        sys.exit(1)
    conn.execute('UPDATE stats SET value = value + 1 WHERE key = ?', (status,))
    conn.commit()
    print(f'Bounty removed ({status})')

elif command == 'stats':
    rows = conn.execute('SELECT key, value FROM stats').fetchall()
    s = dict(rows)
    active = conn.execute('SELECT COUNT(*) FROM bounties WHERE status = ?', ('active',)).fetchone()[0]
    flagged = conn.execute('SELECT COUNT(*) FROM bounties WHERE status = ?', ('flagged',)).fetchone()[0]
    complaints_total = conn.execute('SELECT COUNT(*) FROM complaints').fetchone()[0]
    print(f'Posted: {s.get(\"posted\",0)} | Completed: {s.get(\"completed\",0)} | Refunded: {s.get(\"refunded\",0)} | Expired: {s.get(\"expired\",0)}')
    print(f'Active: {active} | Flagged: {flagged} | Complaints: {complaints_total}')

elif command == 'search':
    prefix = args[0] if args else ''
    # SECURITY: prefix must be a hex string — no wildcards, no SQL special chars.
    # Prevents LIKE pattern DoS (e.g. '%a%b%c%' causes catastrophic backtracking)
    # and ensures search is only ever a left-anchored prefix scan on the index.
    import re
    if not re.match(r'^[0-9a-f]{0,64}$', prefix):
        print('ERROR: search prefix must be a lowercase hex string (0-64 chars)'); sys.exit(1)
    cur = conn.execute(
        'SELECT commitment, timestamp, status FROM bounties WHERE commitment LIKE ? LIMIT 20',
        (prefix + '%',)
    )
    for commitment, ts, status in cur.fetchall():
        print(f'  {commitment[:16]}... {status} {ts}')

elif command == 'report':
    # SAFETY: community complaint — anyone can report a bounty commitment
    # Usage: report <commitment> <category> [reason]
    import re, hashlib, os, secrets
    from datetime import datetime, timezone

    if len(args) < 2:
        print('Usage: report <commitment> <category> [reason]'); sys.exit(1)

    commitment = args[0]
    category = args[1]
    reason = args[2] if len(args) > 2 else ''

    # SECURITY: truncate reason to 500 chars — prevent DB bloat via huge strings
    reason = reason[:500]

    VALID_CATEGORIES = (
        'csam', 'violence', 'weapons_of_mass_destruction', 'human_trafficking',
        'terrorism', 'ncii', 'financial_fraud', 'infrastructure_attack',
        'doxxing', 'drug_manufacturing', 'other'
    )
    if category not in VALID_CATEGORIES:
        sep = ', '
        print(f'ERROR: category must be one of: {sep.join(VALID_CATEGORIES)}')
        sys.exit(1)

    # DARK ENERGY: reporter_hash preimage leak fix.
    # Old: sha256(REPORTER_ID env var) — low-entropy input like a username is
    # reversible via rainbow table, de-anonymising reporters.
    # Fix: sha256(PEPPER + REPORTER_ID) where PEPPER is a 32-byte server secret.
    # Without the pepper, no rainbow table attack is possible.
    pepper = os.environ.get('REPORTER_PEPPER', '')
    if not pepper:
        # DARK ENERGY: no pepper = no privacy. Fail loudly rather than silently
        # hashing a low-entropy ID and believing it's private.
        print('ERROR: REPORTER_PEPPER env var required for reporter privacy'); sys.exit(1)
    reporter_id = os.environ.get('REPORTER_ID', '')
    if not reporter_id:
        print('ERROR: REPORTER_ID env var required to file a report'); sys.exit(1)
    reporter_hash = hashlib.sha256(f'{pepper}:{reporter_id}'.encode()).hexdigest()

    ts = datetime.now(timezone.utc).isoformat()

    # Check bounty exists
    exists = conn.execute('SELECT status FROM bounties WHERE commitment = ?', (commitment,)).fetchone()
    if not exists:
        print('ERROR: No bounty with that commitment on the board')
        sys.exit(1)

    # DARK ENERGY: auto-freeze manipulation fix.
    # Old: anyone with 3 different REPORTER_ID values could freeze any bounty.
    # Fix: rate-limit reports per reporter_hash — one reporter can flag at most
    # REPORT_RATE_LIMIT distinct bounties per REPORT_WINDOW_HOURS. Stored in DB.
    REPORT_RATE_LIMIT = int(os.environ.get('REPORT_RATE_LIMIT', '10'))
    REPORT_WINDOW_HOURS = int(os.environ.get('REPORT_WINDOW_HOURS', '24'))
    from datetime import timedelta
    window_start = (datetime.now(timezone.utc) - timedelta(hours=REPORT_WINDOW_HOURS)).isoformat()
    recent_reports = conn.execute(
        'SELECT COUNT(DISTINCT commitment) FROM complaints WHERE reporter_hash = ? AND timestamp > ?',
        (reporter_hash, window_start)
    ).fetchone()[0]
    if recent_reports >= REPORT_RATE_LIMIT:
        print(f'ERROR: Rate limit — you have filed {recent_reports} reports in the last {REPORT_WINDOW_HOURS}h (max {REPORT_RATE_LIMIT})')
        sys.exit(1)

    try:
        conn.execute(
            'INSERT INTO complaints(commitment, category, reason, reporter_hash, timestamp) VALUES (?, ?, ?, ?, ?)',
            (commitment, category, reason, reporter_hash, ts)
        )
        conn.commit()
    except sqlite3.IntegrityError:
        print('ERROR: You have already reported this bounty')
        sys.exit(1)

    # Count DISTINCT reporter hashes — one reporter spamming multiple reports
    # counts as 1 voice, not N voices
    count = conn.execute(
        'SELECT COUNT(DISTINCT reporter_hash) FROM complaints WHERE commitment = ?', (commitment,)
    ).fetchone()[0]

    threshold = int(os.environ.get('COMPLAINT_FREEZE_THRESHOLD', '3'))
    print(f'Report filed ({count} distinct reporter(s) for this bounty)')

    # SAFETY: auto-freeze — if DISTINCT reporters >= threshold, flag bounty
    if count >= threshold and exists[0] == 'active':
        conn.execute(
            'UPDATE bounties SET status = ? WHERE commitment = ? AND status = ?',
            ('flagged', commitment, 'active')
        )
        conn.execute('UPDATE stats SET value = value + 1 WHERE key = ?', ('flagged',))
        conn.commit()
        print(f'AUTO-FREEZE: Bounty {commitment[:16]}... flagged by {count} distinct reporters (threshold: {threshold})')

        # Export to community-reports.json for operator review
        reports_file = os.environ.get('SAFETY_REPORTS_FILE', '')
        if reports_file:
            os.makedirs(os.path.dirname(reports_file), exist_ok=True)
            cats = conn.execute(
                'SELECT category, COUNT(*) FROM complaints WHERE commitment = ? GROUP BY category',
                (commitment,)
            ).fetchall()
            new_entry = {
                'commitment': commitment,
                'categories': {cat: cnt for cat, cnt in cats},
                'distinct_reporters': count,
                'flagged_at': ts
            }
            # DARK ENERGY: atomic write race fix for Windows.
            # os.rename() is NOT atomic on Windows if the target file exists —
            # it raises FileExistsError. Use os.replace() which IS atomic on
            # both POSIX (rename syscall) and Windows (MoveFileEx MOVEFILE_REPLACE_EXISTING).
            existing = {'reports': []}
            if os.path.exists(reports_file):
                try:
                    with open(reports_file) as f:
                        existing = json.load(f)
                except (json.JSONDecodeError, KeyError):
                    pass
            existing['reports'].append(new_entry)
            tmp = reports_file + f'.tmp.{secrets.token_hex(8)}'
            with open(tmp, 'w') as f:
                json.dump(existing, f, indent=2)
            os.replace(tmp, reports_file)  # atomic on both POSIX and Windows

elif command == 'reports':
    # View complaints for a specific commitment or all flagged bounties
    if args:
        commitment = args[0]
        cur = conn.execute(
            'SELECT category, reason, timestamp FROM complaints WHERE commitment = ? ORDER BY timestamp DESC',
            (commitment,)
        )
        rows = cur.fetchall()
        if not rows:
            print(f'No complaints for {commitment[:16]}...')
        else:
            print(f'Complaints for {commitment[:16]}... ({len(rows)} total):')
            for cat, reason, ts in rows:
                reason_str = f' — {reason}' if reason else ''
                print(f'  [{cat}] {ts}{reason_str}')
    else:
        # Show all flagged bounties
        cur = conn.execute(
            '''SELECT b.commitment, b.timestamp, COUNT(c.id) as complaint_count
               FROM bounties b
               JOIN complaints c ON b.commitment = c.commitment
               WHERE b.status = 'flagged'
               GROUP BY b.commitment
               ORDER BY complaint_count DESC
               LIMIT 50''',
        )
        rows = cur.fetchall()
        flagged_count = conn.execute('SELECT COUNT(*) FROM bounties WHERE status = ?', ('flagged',)).fetchone()[0]
        print(f'Flagged bounties: {flagged_count}')
        for commitment, ts, cnt in rows:
            print(f'  {commitment[:16]}... posted {ts} ({cnt} complaints)')

else:
    print('Commands: list, add, remove, stats, search, report, reports')
    sys.exit(1)

conn.close()
" "$BOARD_DB" "$COMMAND" "$@"
