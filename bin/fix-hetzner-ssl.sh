#!/usr/bin/env bash
# One-shot recovery for nightpay.dev ERR_SSL_PROTOCOL_ERROR / hung TLS.
# Run as root on the Hetzner VPS (web console or SSH):
#   bash /opt/nightpay/bin/fix-hetzner-ssl.sh
set -euo pipefail

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'

say() { printf '%s\n' "$*"; }
ok() { printf '%s%s%s\n' "$GREEN" "$1" "$RESET"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$1" "$RESET"; }
fail() { printf '%s%s%s\n' "$RED" "$1" "$RESET" >&2; exit 1; }

say "=== NightPay TLS recovery (nightpay.dev) ==="

# 1) Kill stale listeners that block Caddy (common after failed deploy)
say "[1/7] Clearing stale listeners on 80/443..."
if command -v fuser >/dev/null 2>&1; then
  fuser -k 80/tcp 443/tcp 2>/dev/null || true
  sleep 2
fi

# 2) Ensure Caddy is installed
if ! command -v caddy >/dev/null 2>&1; then
  fail "caddy not installed — install: apt install -y caddy"
fi

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
[[ -f "$CADDYFILE" ]] || fail "Missing $CADDYFILE"

say "[2/7] Validating Caddyfile..."
caddy validate --config "$CADDYFILE"

# 3) UI static perms (403 / broken file_server after sync)
NIGHTPAY_DIR="${NIGHTPAY_DIR:-/opt/nightpay}"
if [[ -d "$NIGHTPAY_DIR/ui/dist" ]]; then
  say "[3/7] Fixing static UI permissions for caddy user..."
  chmod o+rx "$NIGHTPAY_DIR" || true
  chmod -R o+rX "$NIGHTPAY_DIR/ui/dist" || true
else
  warn "[3/7] $NIGHTPAY_DIR/ui/dist missing — run: cd $NIGHTPAY_DIR/ui && npm run build"
fi

# 4) Re-issue certs if ACME state is corrupt (safe: Caddy re-fetches on reload)
say "[4/7] Clearing stale ACME cert cache for nightpay.dev (if any)..."
find /var/lib/caddy/.local/share/caddy/certificates -name '*nightpay*' -delete 2>/dev/null || true

# 5) Restart Caddy cleanly
say "[5/7] Restarting Caddy..."
systemctl enable caddy 2>/dev/null || true
systemctl restart caddy
sleep 3
systemctl is-active --quiet caddy || {
  journalctl -u caddy -n 80 --no-pager >&2 || true
  fail "caddy.service failed to start"
}

# 6) Verify listeners
say "[6/7] Checking ports 80/443..."
ss -ltnp | grep -E ':(80|443)\b' || fail "Nothing listening on 80/443 after Caddy restart"

# 7) Local + public smoke
say "[7/7] Smoke tests..."
curl -fsS --max-time 10 -o /dev/null -w 'localhost:80 -> %{http_code}\n' http://127.0.0.1/ || warn "localhost:80 failed"
curl -fsS --max-time 15 -o /dev/null -w 'https://nightpay.dev -> %{http_code}\n' https://nightpay.dev/ || warn "public HTTPS still failing — check Hetzner Cloud firewall (TCP 80+443) and DNS"

if [[ -x "$NIGHTPAY_DIR/bin/caddy-ensure.sh" ]]; then
  bash "$NIGHTPAY_DIR/bin/caddy-ensure.sh"
fi

ok "Recovery complete. Verify in browser: https://nightpay.dev/"
